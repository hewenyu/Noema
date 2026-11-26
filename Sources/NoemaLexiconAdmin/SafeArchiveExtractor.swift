import Compression
import CryptoKit
import Darwin
import Foundation
import NoemaCore

/// Extracts a downloaded ZIP of schema sources without trusting it.
///
/// 1. Opens the archive once (`O_NOFOLLOW`, regular file) and checks its SHA-256 against the
///    lockfile **before** reading a single header; every later read uses the same descriptor.
/// 2. Validates the whole central directory in pure Swift: no ZIP64, no encryption, only
///    stored or deflated entries; names relative, UTF-8, free of NUL, `\`, `.`/`..`
///    components, and case- or normalization-insensitive duplicates; Unix modes only regular
///    files or directories (symlinks, hard links, FIFOs, devices refused); at most
///    `maxEntries` entries, `maxTotalUncompressedBytes` in total, and `maxRatio`:1 per entry.
/// 3. Inflates each entry (local header must agree with the central one) into a fresh `0700`
///    directory beside the destination, never writing past an entry's declared size, and
///    checks its CRC-32.
/// 4. Walks the result with `lstat` (regular files and real directories only, size cap),
///    then `rename(2)`s it into place (`renamex_np(RENAME_SWAP)` over an existing one).
public enum SafeArchiveExtractor {
    public struct Limits: Sendable, Hashable {
        public var maxEntries: Int
        public var maxTotalUncompressedBytes: Int64
        public var maxRatio: Int64
        public var maxArchiveBytes: Int64

        public init(maxEntries: Int = 5000, maxTotalUncompressedBytes: Int64 = 512 << 20, maxRatio: Int64 = 100,
                    maxArchiveBytes: Int64 = 1 << 30) {
            self.maxEntries = maxEntries
            self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
            self.maxRatio = maxRatio
            self.maxArchiveBytes = maxArchiveBytes
        }

        public static let `default` = Limits()
    }

    public struct Entry: Sendable, Hashable {
        /// The entry's path after `stripComponents`, `/`-separated, without a trailing `/`.
        public var path: String
        public var isDirectory: Bool
        public var method: UInt16
        public var crc32: UInt32
        public var compressedSize: Int64
        public var uncompressedSize: Int64
        var localHeaderOffset: Int64
        var rawName: [UInt8]
    }

    public struct Report: Sendable, Hashable {
        public var destination: URL
        public var files: Int
        public var directories: Int
        public var totalBytes: Int64
    }

    public enum Failure: Error, Sendable, Hashable {
        case notRegularFile(String)
        case io(String)
        case sha256Mismatch(expected: String, actual: String)
        case notAZip(String)
        case unsafeEntry(String, reason: String)
        case unsupported(String, reason: String)
        case tooManyEntries(Int)
        case tooLarge(Int64)
        case ratioExceeded(String)
        case corrupt(String, reason: String)
    }

    // MARK: Public entry points

    /// Verifies, validates, extracts, and installs `archive` at `destination`.
    @discardableResult
    public static func extract(
        archive: URL, expectedSHA256: String, into destination: URL, stripComponents: Int = 0, limits: Limits = .default
    ) throws(Failure) -> Report {
        let file = try ArchiveFile(archive, limits: limits)
        defer { file.close() }
        let actual = try file.sha256()
        guard actual == expectedSHA256.lowercased() else { throw .sha256Mismatch(expected: expectedSHA256, actual: actual) }
        let entries = try centralDirectory(file, stripComponents: stripComponents, limits: limits)
        return try install(file, entries: entries, into: destination, limits: limits)
    }

    /// The validated central directory of `archive` after checking its SHA-256.
    public static func inspect(
        archive: URL, expectedSHA256: String, stripComponents: Int = 0, limits: Limits = .default
    ) throws(Failure) -> [Entry] {
        let file = try ArchiveFile(archive, limits: limits)
        defer { file.close() }
        let actual = try file.sha256()
        guard actual == expectedSHA256.lowercased() else { throw .sha256Mismatch(expected: expectedSHA256, actual: actual) }
        return try centralDirectory(file, stripComponents: stripComponents, limits: limits)
    }

    // MARK: Central directory

    static func centralDirectory(_ file: ArchiveFile, stripComponents: Int, limits: Limits) throws(Failure) -> [Entry] {
        let size = file.size
        guard size >= 22 else { throw .notAZip("too short") }
        let tailLength = Int(min(size, 22 + 0xFFFF))
        let tail = try file.read(at: size - Int64(tailLength), count: tailLength)
        guard let eocd = (0...(tailLength - 22)).reversed().first(where: {
            tail.u32($0) == 0x0605_4B50 && $0 + 22 + Int(tail.u16($0 + 20)) == tailLength
        }) else {
            throw .notAZip("no end of central directory record")
        }
        if eocd >= 20, tail.u32(eocd - 20) == 0x0706_4B50 { throw .unsupported("archive", reason: "ZIP64") }
        let diskNumber = tail.u16(eocd + 4), cdDisk = tail.u16(eocd + 6)
        let entriesOnDisk = Int(tail.u16(eocd + 8)), totalEntries = Int(tail.u16(eocd + 10))
        let cdSize = Int64(tail.u32(eocd + 12)), cdOffset = Int64(tail.u32(eocd + 16))
        guard diskNumber == 0, cdDisk == 0, entriesOnDisk == totalEntries else {
            throw .unsupported("archive", reason: "multi-disk")
        }
        guard totalEntries != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else {
            throw .unsupported("archive", reason: "ZIP64")
        }
        guard totalEntries <= limits.maxEntries else { throw .tooManyEntries(totalEntries) }
        let eocdOffset = size - Int64(tailLength) + Int64(eocd)
        guard cdOffset + cdSize <= eocdOffset else { throw .notAZip("central directory out of bounds") }
        let directory = try file.read(at: cdOffset, count: Int(cdSize))

        var entries: [Entry] = []
        var seen: Set<String> = []
        var total: Int64 = 0
        var cursor = 0
        for _ in 0..<totalEntries {
            guard cursor + 46 <= directory.count, directory.u32(cursor) == 0x0201_4B50 else {
                throw .notAZip("bad central directory header")
            }
            let madeBy = directory.u16(cursor + 4)
            let flags = directory.u16(cursor + 8)
            let method = directory.u16(cursor + 10)
            let crc = directory.u32(cursor + 16)
            let compressed = Int64(directory.u32(cursor + 20))
            let uncompressed = Int64(directory.u32(cursor + 24))
            let nameLength = Int(directory.u16(cursor + 28))
            let extraLength = Int(directory.u16(cursor + 30))
            let commentLength = Int(directory.u16(cursor + 32))
            let external = directory.u32(cursor + 38)
            let localOffset = Int64(directory.u32(cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength + commentLength <= directory.count else {
                throw .notAZip("central directory entry out of bounds")
            }
            let rawName = Array(directory[nameStart..<(nameStart + nameLength)])
            cursor = nameStart + nameLength + extraLength + commentLength
            guard let name = String(validating: rawName, as: UTF8.self) else {
                throw .unsafeEntry(String(decoding: rawName, as: UTF8.self), reason: "name is not UTF-8")
            }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw .unsupported(name, reason: "ZIP64")
            }
            guard flags & 0x0041 == 0 else { throw .unsupported(name, reason: "encrypted") }
            guard method == 0 || method == 8 else { throw .unsupported(name, reason: "compression method \(method)") }

            // File type: Unix (3) and macOS (19) hosts carry st_mode in the high half of the external attributes.
            let host = madeBy >> 8
            let mode = mode_t(external >> 16)
            var isDirectory = name.hasSuffix("/")
            if host == 3 || host == 19, mode != 0 {
                switch mode & S_IFMT {
                case S_IFREG: guard !isDirectory else { throw .unsafeEntry(name, reason: "file named like a directory") }
                case S_IFDIR: isDirectory = true
                case S_IFLNK: throw .unsafeEntry(name, reason: "symbolic link")
                default: throw .unsafeEntry(name, reason: "special file (mode \(String(mode, radix: 8)))")
                }
            } else if external & 0x10 != 0 {
                isDirectory = true
            }
            let path = try safePath(name, isDirectory: isDirectory)
            if isDirectory, compressed != 0 || uncompressed != 0 { throw .unsafeEntry(name, reason: "directory with data") }
            if !isDirectory {
                if uncompressed > 0, compressed == 0 { throw .ratioExceeded(name) }
                let (maxAllowed, overflow) = compressed.multipliedReportingOverflow(by: limits.maxRatio)
                if !overflow, uncompressed > maxAllowed { throw .ratioExceeded(name) }
                if method == 0, compressed != uncompressed { throw .corrupt(name, reason: "stored sizes differ") }
            }
            total += uncompressed
            guard total <= limits.maxTotalUncompressedBytes else { throw .tooLarge(total) }
            guard localOffset + 30 <= cdOffset, localOffset + 30 + compressed <= cdOffset else {
                throw .corrupt(name, reason: "data out of bounds")
            }

            let components = path.split(separator: "/").map(String.init)
            guard components.count > stripComponents else {
                if isDirectory { continue }
                throw .unsafeEntry(name, reason: "file above the stripped root")
            }
            let stripped = components.dropFirst(stripComponents).joined(separator: "/")
            let key = stripped.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else { throw .unsafeEntry(name, reason: "duplicate entry") }
            entries.append(Entry(
                path: stripped, isDirectory: isDirectory, method: method, crc32: crc, compressedSize: compressed,
                uncompressedSize: uncompressed, localHeaderOffset: localOffset, rawName: rawName))
        }
        return entries
    }

    /// `name` without its trailing `/` when every component is a plain, non-dot name and the
    /// path is relative.
    static func safePath(_ name: String, isDirectory: Bool) throws(Failure) -> String {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.utf8.contains(0) else {
            throw .unsafeEntry(name, reason: "absolute path, backslash, or NUL")
        }
        var trimmed = Substring(name)
        if trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { throw .unsafeEntry(name, reason: "empty, dot, or control-character component") }
        }
        if let first = components.first, first.count == 2, first.hasSuffix(":") {
            throw .unsafeEntry(name, reason: "drive letter")
        }
        return String(trimmed)
    }

    // MARK: Extraction

    static func install(_ file: ArchiveFile, entries: [Entry], into destination: URL, limits: Limits) throws(Failure) -> Report {
        let parent = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw .io("creating \(parent.path): \(error)")
        }
        // A symlinked parent (`schemas/` -> elsewhere) or destination would redirect the install.
        guard FileSafety.isRealDirectory(parent) else { throw .notRegularFile(parent.path) }
        if let type = FileSafety.fileType(destination), type != S_IFDIR { throw .notRegularFile(destination.path) }
        let temporary = parent.appending(path: ".\(destination.lastPathComponent).extract.\(getpid()).\(UUID().uuidString)")
        guard mkdir(temporary.path, 0o700) == 0 else { throw .io("creating \(temporary.path): errno \(errno)") }
        var installed = false
        defer { if !installed { try? FileManager.default.removeItem(at: temporary) } }

        for entry in entries {
            let target = temporary.appending(path: entry.path)
            try makeDirectories(entry.isDirectory ? entry.path : parentPath(entry.path), under: temporary)
            if entry.isDirectory { continue }
            try extractEntry(entry, from: file, to: target)
        }
        let (files, directories, bytes) = try walk(temporary, limits: limits)

        var old: URL?
        if FileSafety.fileType(destination) != nil {
            if renamex_np(temporary.path, destination.path, UInt32(RENAME_SWAP)) == 0 {
                old = temporary
            } else if errno == ENOTSUP || errno == EINVAL {
                let aside = parent.appending(path: ".\(destination.lastPathComponent).old.\(getpid()).\(UUID().uuidString)")
                guard rename(destination.path, aside.path) == 0 else { throw .io("moving \(destination.path) aside: errno \(errno)") }
                guard rename(temporary.path, destination.path) == 0 else {
                    let code = errno
                    _ = rename(aside.path, destination.path)
                    throw .io("installing \(destination.path): errno \(code)")
                }
                old = aside
            } else {
                throw .io("swapping \(destination.path): errno \(errno)")
            }
        } else if rename(temporary.path, destination.path) != 0 {
            throw .io("installing \(destination.path): errno \(errno)")
        }
        installed = true
        FileSafety.syncDirectory(parent)
        if let old { try? FileManager.default.removeItem(at: old) }
        return Report(destination: destination, files: files, directories: directories, totalBytes: bytes)
    }

    static func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Creates each directory of `relative` under `root`; an existing component must be a
    /// real directory.
    static func makeDirectories(_ relative: String, under root: URL) throws(Failure) {
        guard !relative.isEmpty else { return }
        var current = root
        for component in relative.split(separator: "/") {
            current = current.appending(path: String(component), directoryHint: .isDirectory)
            switch FileSafety.fileType(current) {
            case S_IFDIR?: continue
            case nil:
                guard mkdir(current.path, 0o755) == 0 else { throw .io("creating \(current.path): errno \(errno)") }
            default:
                throw .unsafeEntry(relative, reason: "path crosses a non-directory")
            }
        }
    }

    static func extractEntry(_ entry: Entry, from file: ArchiveFile, to target: URL) throws(Failure) {
        let header = try file.read(at: entry.localHeaderOffset, count: 30)
        guard header.u32(0) == 0x0403_4B50 else { throw .corrupt(entry.path, reason: "bad local header") }
        let localMethod = header.u16(8)
        let nameLength = Int(header.u16(26)), extraLength = Int(header.u16(28))
        let localName = try file.read(at: entry.localHeaderOffset + 30, count: nameLength)
        guard localMethod == entry.method, Array(localName) == entry.rawName else {
            throw .corrupt(entry.path, reason: "local header disagrees with the central directory")
        }
        let dataStart = entry.localHeaderOffset + 30 + Int64(nameLength) + Int64(extraLength)
        guard dataStart + entry.compressedSize <= file.size else { throw .corrupt(entry.path, reason: "data out of bounds") }

        let descriptor = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw .io("creating \(target.path): errno \(errno)") }
        defer { close(descriptor) }
        var crc = CRC32()
        var written: Int64 = 0
        func emit(_ chunk: Data) throws(Failure) {
            guard written + Int64(chunk.count) <= entry.uncompressedSize else {
                throw .corrupt(entry.path, reason: "inflates past its declared size")
            }
            crc.update(chunk)
            try writeAll(descriptor, chunk, path: target.path)
            written += Int64(chunk.count)
        }

        var offset = dataStart
        let end = dataStart + entry.compressedSize
        let chunkSize = 1 << 16
        if entry.method == 0 {
            while offset < end {
                let count = Int(min(Int64(chunkSize), end - offset))
                try emit(try file.read(at: offset, count: count))
                offset += Int64(count)
            }
        } else {
            var readFailure: Failure?
            do {
                let filter = try InputFilter<Data>(.decompress, using: .zlib, bufferCapacity: chunkSize) { requested in
                    guard offset < end else { return nil }
                    let count = Int(min(Int64(requested), end - offset))
                    do throws(Failure) {
                        let data = try file.read(at: offset, count: count)
                        offset += Int64(count)
                        return data
                    } catch {
                        readFailure = error
                        return nil
                    }
                }
                while let chunk = try filter.readData(ofLength: chunkSize), !chunk.isEmpty {
                    try emit(chunk)
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                throw readFailure ?? .corrupt(entry.path, reason: "inflate failed: \(error)")
            }
            if let readFailure { throw readFailure }
        }
        guard written == entry.uncompressedSize else { throw .corrupt(entry.path, reason: "size mismatch") }
        guard crc.value == entry.crc32 else { throw .corrupt(entry.path, reason: "CRC-32 mismatch") }
        guard fsync(descriptor) == 0 else { throw .io("fsync \(target.path): errno \(errno)") }
    }

    static func writeAll(_ descriptor: Int32, _ data: Data, path: String) throws(Failure) {
        let ok = data.withUnsafeBytes { buffer -> Bool in
            var done = 0
            while done < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + done, buffer.count - done)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                done += count
            }
            return true
        }
        guard ok else { throw .io("writing \(path): errno \(errno)") }
    }

    /// Counts what `root` holds; anything but regular files and real directories fails.
    static func walk(_ root: URL, limits: Limits) throws(Failure) -> (files: Int, directories: Int, bytes: Int64) {
        var files = 0, directories = 0
        var bytes: Int64 = 0
        var pending = [root]
        while let directory = pending.popLast() {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                throw .io("listing \(directory.path)")
            }
            for name in names {
                let url = directory.appending(path: name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw .io("lstat \(url.path): errno \(errno)") }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    directories += 1
                    pending.append(url)
                case S_IFREG:
                    files += 1
                    bytes += Int64(info.st_size)
                    guard info.st_nlink == 1 else { throw .unsafeEntry(name, reason: "hard link") }
                    guard bytes <= limits.maxTotalUncompressedBytes else { throw .tooLarge(bytes) }
                default:
                    throw .unsafeEntry(name, reason: "not a regular file or directory after extraction")
                }
            }
        }
        return (files, directories, bytes)
    }
}

// MARK: - Archive file access

/// The archive, opened once; the hash and every header come from this descriptor.
final class ArchiveFile {
    let descriptor: Int32
    let size: Int64
    let path: String

    init(_ url: URL, limits: SafeArchiveExtractor.Limits) throws(SafeArchiveExtractor.Failure) {
        path = url.path
        descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? .notRegularFile(url.path) : .io("opening \(url.path): errno \(errno)")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw .notRegularFile(url.path)
        }
        guard Int64(info.st_size) <= limits.maxArchiveBytes else {
            Darwin.close(descriptor)
            throw .tooLarge(Int64(info.st_size))
        }
        size = Int64(info.st_size)
    }

    func close() { Darwin.close(descriptor) }

    func sha256() throws(SafeArchiveExtractor.Failure) -> String {
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < size {
            let chunk = try read(at: offset, count: Int(min(1 << 20, size - offset)))
            hasher.update(data: chunk)
            offset += Int64(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Exactly `count` bytes at `offset`.
    func read(at offset: Int64, count: Int) throws(SafeArchiveExtractor.Failure) -> Data {
        guard count >= 0, offset >= 0, offset + Int64(count) <= size else {
            throw .corrupt(path, reason: "read out of bounds")
        }
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            var done = 0
            while done < count {
                let n = pread(descriptor, buffer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                done += n
            }
            return true
        }
        guard ok else { throw .io("reading \(path)") }
        return data
    }
}

struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var crc = state
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer { crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        state = crc
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}
