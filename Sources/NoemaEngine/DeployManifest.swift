import CryptoKit
import Darwin
import Foundation

/// What a deployment consumed and produced, written by `noema-rime-deployer` to
/// `build/.noema-deploy-manifest.json` and checked by `RimeEngine` before it trusts a build.
///
/// - `inputs`: every regular file under `sharedDataDir` (recursively, as `shared/<path>`) and
///   every top-level `*.custom.yaml` in `userDataDir` (as `user/<name>`), sorted by path. A
///   symlink in `sharedDataDir` must resolve to a regular file; a `*.custom.yaml` must be a
///   regular file itself; anything else fails the snapshot instead of being skipped. Any
///   added, changed, deleted, or renamed input changes this list, so `deployIfNeeded`
///   redeploys exactly when `inputs` differs from a fresh `DeployManifest.inputs(...)`.
/// - `outputs`: every regular file under `build/` except the manifest itself, sorted by path;
///   `build/` holds nothing else (no extra files, no symlinks).
/// - `requiredDictionaries`: the compiled schema's dictionaries (`translator/dictionary`,
///   `reverse_lookup/dictionary`, and `<tag>/dictionary` of each tagged script or table
///   translator); each needs non-empty `<dict>.table.bin` and `<dict>.prism.bin` among `outputs`.
public struct DeployManifest: Codable, Equatable, Sendable {
    public struct ManifestEntry: Codable, Hashable, Sendable {
        /// `/`-separated, relative, without `.` or `..` components.
        public var relativePath: String
        public var size: UInt64
        /// Lowercase hex SHA-256 of the file contents.
        public var sha256: String

        public init(relativePath: String, size: UInt64, sha256: String) {
            self.relativePath = relativePath
            self.size = size
            self.sha256 = sha256
        }
    }

    public static let currentVersion = 1
    public static let fileName = ".noema-deploy-manifest.json"

    public var version: Int
    public var schemaID: String
    public var inputs: [ManifestEntry]
    public var outputs: [ManifestEntry]
    public var requiredDictionaries: [String]

    public init(
        version: Int = DeployManifest.currentVersion,
        schemaID: String,
        inputs: [ManifestEntry],
        outputs: [ManifestEntry],
        requiredDictionaries: [String]
    ) {
        self.version = version
        self.schemaID = schemaID
        self.inputs = inputs
        self.outputs = outputs
        self.requiredDictionaries = requiredDictionaries
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A path could not be read, listed, or hashed.
        case unreadable(String)
        /// A path that must be a regular file or a real directory is something else.
        case notRegular(String)
        /// A file is larger than the caller allows.
        case tooLarge(String)
    }

    /// Default size cap of `readRegularFile`: manifests and `*.custom.yaml` patches.
    public static let maxReadSize = 16 << 20

    // MARK: Required outputs

    /// Outputs a usable build of `schemaID` must contain.
    public static func requiredOutputPaths(schemaID: String, dictionaries: [String]) -> [String] {
        ["default.yaml", "\(schemaID).schema.yaml"]
            + dictionaries.flatMap { ["\($0).table.bin", "\($0).prism.bin"] }
    }

    // MARK: Inputs

    /// The current deploy inputs on disk. A symlink under `sharedDataDir` to a regular file
    /// is hashed through to its target; a symlink to anything else (a directory, a FIFO, a
    /// dangling link) fails, since librime would follow it where this walk cannot. Throws
    /// when anything is unreadable, so a doubtful input set is never mistaken for an
    /// unchanged one.
    public static func inputs(sharedDataDir: URL, userDataDir: URL) throws(Failure) -> [ManifestEntry] {
        var entries: [ManifestEntry] = []
        for relative in try regularFiles(under: sharedDataDir, followingFileSymlinks: true) {
            let (size, digest) = try hashFile(sharedDataDir.appending(path: relative))
            entries.append(ManifestEntry(relativePath: "shared/\(relative)", size: size, sha256: digest))
        }
        for name in try userCustomPatchNames(in: userDataDir) {
            let (size, digest) = try hashFile(userDataDir.appending(path: name), followSymlink: false)
            entries.append(ManifestEntry(relativePath: "user/\(name)", size: size, sha256: digest))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    /// Top-level `*.custom.yaml` names in `userDataDir`. Each must be a regular file itself
    /// (`lstat`): a symlink, directory, FIFO, or socket by that name fails with `.notRegular`,
    /// so a link never pulls a file from outside `userDataDir` into a deployment.
    public static func userCustomPatchNames(in userDataDir: URL) throws(Failure) -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: userDataDir.path)
        } catch {
            throw .unreadable(userDataDir.path)
        }
        var patches: [String] = []
        for name in names.sorted() where name.hasSuffix(".custom.yaml") {
            let path = userDataDir.appending(path: name).path
            var info = stat()
            guard lstat(path, &info) == 0 else { throw .unreadable(path) }
            guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegular(path) }
            patches.append(name)
        }
        return patches
    }

    // MARK: Outputs

    /// Every regular file under `buildDir` except the manifest, hashed. A symlink or any
    /// other non-regular, non-directory entry fails: a build never points outside itself.
    public static func outputs(buildDir: URL) throws(Failure) -> [ManifestEntry] {
        var entries: [ManifestEntry] = []
        for relative in try regularFiles(under: buildDir, followingFileSymlinks: false) where relative != fileName {
            let (size, digest) = try hashFile(buildDir.appending(path: relative), followSymlink: false)
            entries.append(ManifestEntry(relativePath: relative, size: size, sha256: digest))
        }
        return entries
    }

    // MARK: Validation

    /// The manifest in `buildDir` when the build is complete and intact: the manifest is a
    /// regular file of at most `maxReadSize` bytes, decodes with `version == 1` and
    /// `schemaID`, lists `default.yaml`, the schema, and both compiled files of every required
    /// dictionary, each non-empty, and equals a fresh `outputs(buildDir:)` exactly, so every
    /// listed file is still a regular file with the recorded size and SHA-256 and `build/`
    /// holds no unlisted file and no symlink. Nil otherwise.
    public static func validated(buildDir: URL, schemaID: String) -> DeployManifest? {
        guard isRealDirectory(buildDir.path),
              let data = try? readRegularFile(buildDir.appending(path: fileName)),
              let manifest = try? JSONDecoder().decode(DeployManifest.self, from: data),
              manifest.version == currentVersion, manifest.schemaID == schemaID,
              isSafeName(schemaID), manifest.requiredDictionaries.allSatisfy(isSafeName)
        else { return nil }
        let sizes = Dictionary(manifest.outputs.map { ($0.relativePath, $0.size) }, uniquingKeysWith: { _, _ in 0 })
        guard requiredOutputPaths(schemaID: schemaID, dictionaries: manifest.requiredDictionaries)
                .allSatisfy({ (sizes[$0] ?? 0) > 0 }),
              let actual = try? outputs(buildDir: buildDir), actual == manifest.outputs
        else { return nil }
        return manifest
    }

    // MARK: Encoding

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: File helpers

    /// SHA-256 and size of a regular file, read in 1 MiB chunks. With `followSymlink`
    /// false a symlink fails instead of being read through.
    public static func hashFile(_ url: URL, followSymlink: Bool = true) throws(Failure) -> (UInt64, String) {
        let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | (followSymlink ? 0 : O_NOFOLLOW)
        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else { throw .unreadable(url.path) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(url.path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegular(url.path) }
        var hasher = SHA256()
        var size: UInt64 = 0
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let count = read(descriptor, buffer.baseAddress, chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable(url.path)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            size += UInt64(count)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Contents of a regular file of at most `maxSize` bytes. A symlink or any other kind of
    /// entry fails with `.notRegular` (opened `O_NOFOLLOW | O_NONBLOCK`, so a FIFO never
    /// blocks); a larger file, or one that grows past `maxSize` while read, fails with `.tooLarge`.
    public static func readRegularFile(_ url: URL, maxSize: Int = maxReadSize) throws(Failure) -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? .notRegular(url.path) : .unreadable(url.path)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(url.path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegular(url.path) }
        guard info.st_size <= maxSize else { throw .tooLarge(url.path) }
        var data = Data()
        let chunk = 1 << 16
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let count = read(descriptor, buffer.baseAddress, chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable(url.path)
            }
            if count == 0 { return data }
            guard data.count + count <= maxSize else { throw .tooLarge(url.path) }
            data.append(contentsOf: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
        }
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether `name` (a schema ID or dictionary name) can be joined into a file name inside
    /// one directory: non-empty, and free of `/`, `..`, and NUL.
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..") && !name.utf8.contains(0)
    }

    /// Relative paths of the regular files under `root`, sorted. Directories are walked
    /// with `lstat`, so a symlinked directory is never descended. A symlink to a regular
    /// file counts when `followingFileSymlinks`; a symlink to anything else (a directory, a
    /// FIFO, a socket, a device, nothing) and any other entry kind fail with `.notRegular`.
    static func regularFiles(under root: URL, followingFileSymlinks: Bool) throws(Failure) -> [String] {
        guard isRealDirectory(root.path) else { throw .notRegular(root.path) }
        var result: [String] = []
        var pending: [String] = [""]
        while let relative = pending.popLast() {
            let directory = relative.isEmpty ? root : root.appending(path: relative)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                throw .unreadable(directory.path)
            }
            for name in names {
                let child = relative.isEmpty ? name : "\(relative)/\(name)"
                let path = root.appending(path: child).path
                var info = stat()
                guard lstat(path, &info) == 0 else { throw .unreadable(path) }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    pending.append(child)
                case S_IFREG:
                    result.append(child)
                case S_IFLNK where followingFileSymlinks:
                    var target = stat()
                    guard stat(path, &target) == 0 else {
                        // Dangling or looping: there is no regular file to hash.
                        if [ENOENT, ELOOP, ENOTDIR].contains(errno) { throw .notRegular(path) }
                        throw .unreadable(path)
                    }
                    // librime would follow a linked directory, but this walk cannot bound
                    // a cycle, so its contents could never be inputs: refuse it outright.
                    guard target.st_mode & S_IFMT == S_IFREG else { throw .notRegular(path) }
                    result.append(child)
                default:
                    throw .notRegular(path)
                }
            }
        }
        return result.sorted()
    }
}
