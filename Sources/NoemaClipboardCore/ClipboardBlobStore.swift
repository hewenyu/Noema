import Darwin
import Foundation
import NoemaCore

/// Sealed image blobs on disk: `<digest>.enc` (the PNG) and `<digest>.thumb.enc` (the
/// thumbnail), both AES-GCM ciphertext, so no PNG header ever reaches the disk.
///
/// The directory must be a real directory (never a symlink) and is kept `0700`; files are
/// `0600`, written through `O_CREAT | O_EXCL | O_NOFOLLOW` temporaries that are `fsync`ed,
/// renamed into place, and followed by a directory `fsync`; reads use `O_NOFOLLOW` and
/// require a regular file. A digest must be exactly 64 lowercase hex characters before it
/// becomes part of a path.
public struct ClipboardBlobStore: Sendable {
    public let directory: URL
    /// The largest sealed blob `read` accepts.
    public let maxBlobBytes: Int

    public init(directory: URL, maxBlobBytes: Int = (25 << 20) + 4_096) throws(ClipboardError) {
        self.directory = directory
        self.maxBlobBytes = maxBlobBytes
        try Self.ensurePrivateDirectory(directory)
    }

    /// Creates `url` `0700` when missing; otherwise it must be a real directory owned by
    /// this user, and is reset to `0700`.
    public static func ensurePrivateDirectory(_ url: URL) throws(ClipboardError) {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw .blobIO(url.path, errno: errno) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw .blobIO(url.path, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw .notPrivateDirectory(url.path) }
        if info.st_mode & 0o777 != 0o700, chmod(url.path, 0o700) != 0 { throw .blobIO(url.path, errno: errno) }
    }

    public static func isValidDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    public func url(digest: String, thumbnail: Bool) throws(ClipboardError) -> URL {
        guard Self.isValidDigest(digest) else { throw .invalidDigest(digest) }
        return directory.appending(path: thumbnail ? "\(digest).thumb.enc" : "\(digest).enc")
    }

    public func write(_ sealed: Data, digest: String, thumbnail: Bool) throws(ClipboardError) {
        let target = try url(digest: digest, thumbnail: thumbnail)
        do {
            try FileSafety.writeAtomically(sealed, to: target, mode: 0o600)
        } catch let FileSafety.WriteError.failed(path, code) {
            throw .blobIO(path, errno: code)
        } catch {
            throw .blobIO(target.path, errno: EIO)
        }
    }

    public func exists(digest: String, thumbnail: Bool) -> Bool {
        guard let target = try? url(digest: digest, thumbnail: thumbnail) else { return false }
        return FileSafety.isRegularFile(target)
    }

    public func read(digest: String, thumbnail: Bool) throws(ClipboardError) -> Data {
        let target = try url(digest: digest, thumbnail: thumbnail)
        let descriptor = open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw errno == ENOENT ? .notFound(digest) : errno == ELOOP ? .notRegularFile(target.path) : .blobIO(target.path, errno: errno)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile(target.path) }
        let size = Int(info.st_size)
        guard size <= maxBlobBytes else { throw .imageTooLarge(size) }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < size {
                let count = Darwin.read(descriptor, buffer.baseAddress! + offset, size - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard ok else { throw .blobIO(target.path, errno: EIO) }
        return data
    }

    /// Unlinks both files of `digest`; a missing file is not an error.
    public func remove(digest: String) {
        for thumbnail in [false, true] {
            if let target = try? url(digest: digest, thumbnail: thumbnail) { unlink(target.path) }
        }
    }

    /// Removes every blob whose digest is not in `keeping`, unknown regular files, and
    /// leftover temporaries. Symlinks and directories inside are unlinked too (never
    /// followed). Returns how many entries were removed.
    @discardableResult
    public func removeOrphans(keeping: Set<String>) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names {
            let digest: String
            if name.hasSuffix(".thumb.enc") {
                digest = String(name.dropLast(".thumb.enc".count))
            } else if name.hasSuffix(".enc") {
                digest = String(name.dropLast(".enc".count))
            } else {
                digest = ""
            }
            if Self.isValidDigest(digest), keeping.contains(digest) { continue }
            let path = directory.appending(path: name).path
            if unlink(path) == 0 || rmdir(path) == 0 { removed += 1 }
        }
        if removed > 0 { FileSafety.syncDirectory(directory) }
        return removed
    }
}
