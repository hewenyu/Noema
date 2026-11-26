import Foundation
import NoemaCore

/// `vendor/dictionaries.lock.json`: every external schema set and language model Noema can
/// install, pinned by URL, release, size, license, and SHA-256. Nothing it lists is ever
/// committed to the repository; a download that does not hash to `sha256` is never used.
public struct DictionaryLockfile: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// A ZIP of Rime schema and dictionary sources, extracted to `schemas/<set>/`.
        case schemaSet
        /// An octagram `.gram` language model, stored as `models/<fileName>`.
        case gram
    }

    public enum ArchiveFormat: String, Codable, Sendable, Hashable {
        case zip
        /// The download is the file itself.
        case raw
    }

    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var kind: Kind
        public var schemaSetID: SchemaSetID?
        public var displayName: String
        public var upstream: String
        /// Release tag or commit the URL is pinned to.
        public var release: String
        public var publishedAt: String?
        public var url: String
        /// Lowercase hex SHA-256 of the download.
        public var sha256: String
        /// Exact byte size of the download.
        public var size: Int64
        public var license: String
        public var archive: ArchiveFormat
        /// Leading path components to drop from every ZIP entry (a GitHub source archive's root).
        public var stripComponents: Int?
        public var defaultSchemaID: String?
        public var optionalGramID: String?
        /// For `.raw`: the installed file name.
        public var fileName: String?
    }

    public enum ValidationError: Error, Sendable, Hashable {
        case unsupportedVersion(Int)
        case duplicateID(String)
        case invalidID(String)
        case invalidSHA256(id: String)
        case invalidURL(id: String, String)
        case invalidSize(id: String)
        case missingField(id: String, String)
        case unknownReference(id: String, String)
        case malformed(String)
    }

    public static let currentVersion = 1
    /// A lockfile larger than this is refused unread.
    public static let maximumSize = 1 << 20

    public var version: Int
    public var entries: [Entry]

    public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    public func entry(for set: SchemaSetID) -> Entry? {
        entries.first { $0.kind == .schemaSet && $0.schemaSetID == set }
    }

    /// Parses and validates `data`. `allowLoopbackHTTP` admits `http://127.0.0.1[:port]/`
    /// URLs (tests); every other URL must be `https://` with a host.
    public static func parse(_ data: Data, allowLoopbackHTTP: Bool = false) throws(ValidationError) -> DictionaryLockfile {
        guard data.count <= maximumSize else { throw .malformed("larger than \(maximumSize) bytes") }
        let lockfile: DictionaryLockfile
        do {
            lockfile = try JSONDecoder().decode(DictionaryLockfile.self, from: data)
        } catch {
            throw .malformed(String(describing: error))
        }
        try lockfile.validate(allowLoopbackHTTP: allowLoopbackHTTP)
        return lockfile
    }

    public static func load(from url: URL, allowLoopbackHTTP: Bool = false) throws(ValidationError) -> DictionaryLockfile {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw .malformed("cannot open \(url.path): errno \(errno)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumSize,
              let data = try? handle.readToEnd()
        else { throw .malformed("\(url.path) is not a regular file of at most \(maximumSize) bytes") }
        return try parse(data, allowLoopbackHTTP: allowLoopbackHTTP)
    }

    public func validate(allowLoopbackHTTP: Bool = false) throws(ValidationError) {
        guard version == Self.currentVersion else { throw .unsupportedVersion(version) }
        var seen: Set<String> = []
        var seenSets: Set<SchemaSetID> = []
        for entry in entries {
            guard Self.isValidID(entry.id) else { throw .invalidID(entry.id) }
            guard seen.insert(entry.id).inserted else { throw .duplicateID(entry.id) }
            guard Self.isValidSHA256(entry.sha256) else { throw .invalidSHA256(id: entry.id) }
            guard Self.isAllowedURL(entry.url, allowLoopbackHTTP: allowLoopbackHTTP) else {
                throw .invalidURL(id: entry.id, entry.url)
            }
            guard entry.size > 0 else { throw .invalidSize(id: entry.id) }
            for (name, value) in [("displayName", entry.displayName), ("license", entry.license), ("release", entry.release)]
            where value.trimmingCharacters(in: .whitespaces).isEmpty {
                throw .missingField(id: entry.id, name)
            }
            switch entry.kind {
            case .schemaSet:
                guard let set = entry.schemaSetID, set != .builtin else { throw .missingField(id: entry.id, "schemaSetID") }
                guard seenSets.insert(set).inserted else { throw .duplicateID("schemaSetID \(set.rawValue)") }
                guard entry.archive == .zip else { throw .missingField(id: entry.id, "archive: zip") }
                guard let schema = entry.defaultSchemaID, FileSafety.isPlainName(schema) else {
                    throw .missingField(id: entry.id, "defaultSchemaID")
                }
                guard (0...4).contains(entry.stripComponents ?? 0) else { throw .missingField(id: entry.id, "stripComponents") }
            case .gram:
                guard entry.archive == .raw, let name = entry.fileName, FileSafety.isPlainName(name), name.hasSuffix(".gram")
                else { throw .missingField(id: entry.id, "fileName (*.gram)") }
            }
        }
        for entry in entries {
            if let gram = entry.optionalGramID, self.entry(gram)?.kind != .gram {
                throw .unknownReference(id: entry.id, gram)
            }
        }
    }

    /// Lowercase or uppercase ASCII letters, digits, `-`, `_`, `.`; 1–64 characters.
    static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && !id.hasPrefix(".") && id.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2D || byte == 0x5F || byte == 0x2E
        }
    }

    /// Exactly 64 lowercase hex digits, and not a placeholder (one repeated digit).
    public static func isValidSHA256(_ digest: String) -> Bool {
        let bytes = Array(digest.utf8)
        guard bytes.count == 64,
              bytes.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { return false }
        return Set(bytes).count > 1
    }

    /// `https://<host>/...`, or with `allowLoopbackHTTP` `http://127.0.0.1[:port]/...`. No
    /// user info, no fragment.
    public static func isAllowedURL(_ string: String, allowLoopbackHTTP: Bool) -> Bool {
        guard let components = URLComponents(string: string), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil
        else { return false }
        switch components.scheme {
        case "https": return true
        case "http": return allowLoopbackHTTP && host == "127.0.0.1"
        default: return false
        }
    }
}
