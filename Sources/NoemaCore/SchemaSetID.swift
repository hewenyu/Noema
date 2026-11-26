import Darwin
import Foundation

/// A Rime schema set Noema can run: the built-in minimal pinyin or one of the three
/// downloadable packs. Each set has its own isolated Rime `user_data_dir` at
/// `NoemaPaths.schemaSetUserDataDir(_:)`, so their LevelDB userdbs never mix.
public enum SchemaSetID: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case builtin
    case wanxiang
    case rimeIce = "rime-ice"
    case mint

    public var id: String { rawValue }

    /// The stable directory name under `sets/`, `schemas/`, and `snapshots/`.
    public var directoryName: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtin: "内置拼音"
        case .wanxiang: "万象"
        case .rimeIce: "雾凇"
        case .mint: "薄荷"
        }
    }

    /// The schema a set opens when no other is requested.
    public var defaultSchemaID: String {
        switch self {
        case .builtin: "noema_pinyin"
        case .wanxiang: "wanxiang"
        case .rimeIce: "rime_ice"
        case .mint: "rime_mint"
        }
    }
}

/// Where a requested schema-set switch stands; the IME reports every change to the agent
/// (`SchemaSetSwitchStatus` in NoemaIPC), and `SchemaSetSwitcher` emits it.
public enum SchemaSwitchPhase: String, Codable, Sendable, Hashable {
    /// The target set's `build/` is being prepared off the IME's main actor.
    case compiling
    /// The user is composing: the switch waits for the next idle boundary.
    case pendingIdle
    /// The IME now runs the target set.
    case ready
    /// The switch did not happen; the IME keeps the set it ran before.
    case failed
}

/// The set and schema the input method boots into, persisted as `active-schema-set.json`.
public struct ActiveSchemaSetRecord: Codable, Sendable, Hashable {
    public var schemaSetID: SchemaSetID
    public var schemaID: String
    public var updatedAt: Date

    public init(schemaSetID: SchemaSetID, schemaID: String, updatedAt: Date = Date()) {
        self.schemaSetID = schemaSetID
        self.schemaID = schemaID
        self.updatedAt = updatedAt
    }

    public static let fileName = "active-schema-set.json"
    static let maximumSize = 64 << 10

    /// The record at `url`, or nil when it is missing, not a regular file (a symlink is
    /// refused), oversized, or not a valid record with a plain schema ID.
    public static func load(from url: URL) -> ActiveSchemaSetRecord? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumSize,
              let data = try? handle.readToEnd(),
              let record = try? JSONDecoder.noema.decode(ActiveSchemaSetRecord.self, from: data),
              FileSafety.isPlainName(record.schemaID)
        else { return nil }
        return record
    }

    /// Writes the record atomically: a `0600` temporary file, `fsync`, then `rename(2)`.
    public func save(to url: URL) throws {
        try FileSafety.writeAtomically(try JSONEncoder.noema.encode(self), to: url)
    }
}

/// Small file helpers shared by the learning store, the schema-set workspace, and the agent.
public enum FileSafety {
    /// Non-empty and free of `/`, `..`, and NUL: safe to join into one directory.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..") && !name.utf8.contains(0)
    }

    public enum WriteError: Error, Equatable, Sendable {
        case failed(String, errno: Int32)
    }

    /// Writes `data` to `url` through a `0600` `O_EXCL | O_NOFOLLOW` temporary file in the
    /// same directory, `fsync`s it, renames it over `url`, and `fsync`s the directory, so a
    /// crash leaves either the old or the new file, never a torn one.
    public static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(url.lastPathComponent).tmp.\(getpid()).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw WriteError.failed(temporary.path, errno: errno) }
        var ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        ok = ok && fsync(descriptor) == 0
        ok = close(descriptor) == 0 && ok
        guard ok, rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw WriteError.failed(url.path, errno: code)
        }
        syncDirectory(directory)
    }

    public static func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    /// `lstat` file type, or nil when the path does not exist or cannot be read.
    public static func fileType(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    public static func isRealDirectory(_ url: URL) -> Bool { fileType(url) == S_IFDIR }
    public static func isRegularFile(_ url: URL) -> Bool { fileType(url) == S_IFREG }
}

extension JSONEncoder {
    /// Sorted keys, ISO 8601 dates: stable, diffable files.
    public static var noema: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var noema: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
