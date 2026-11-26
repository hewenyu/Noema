import Darwin
import Foundation

/// One `v3` snippet: the text it commits and lowercase ASCII keywords a query filters by.
public struct Snippet: Codable, Sendable, Hashable {
    public var text: String
    public var keywords: [String]

    public init(text: String, keywords: [String] = []) {
        self.text = text
        self.keywords = keywords
    }

    private enum CodingKeys: String, CodingKey { case text, keywords }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
    }
}

/// The snippet list: built-in defaults, or the user's `snippets.json` when it is a valid
/// regular file. Reading never follows a symlink (`O_NOFOLLOW`), never blocks on a FIFO
/// (`O_NONBLOCK`), and refuses files over `maxFileSize`; anything unreadable or malformed
/// falls back to `defaults`. Writing goes to a `0600` temporary file in the same directory,
/// `fsync`, then `rename(2)` over the target, so a reader sees the old or the new list,
/// never a torn one; a symlink at the target is refused, not replaced.
///
/// File format: `{"version": 1, "snippets": [{"text": "…", "keywords": ["…"]}]}`.
public struct SnippetStore: Sendable, Hashable {
    public static let maxFileSize = 1 << 20
    public static let currentVersion = 1
    public static let fileName = "snippets.json"

    public enum Failure: Error, Sendable, Hashable {
        case symlink
        case notRegular
        case tooLarge
        case io(Int32)
    }

    /// The user's file; nil keeps only the defaults.
    public let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    private struct File: Codable {
        var version: Int
        var snippets: [Snippet]
    }

    public static let defaults: [Snippet] = [
        Snippet(text: "好的，收到！", keywords: ["haode", "shoudao", "ok", "hd"]),
        Snippet(text: "谢谢！", keywords: ["xiexie", "thanks", "xx"]),
        Snippet(text: "稍等，我马上看一下。", keywords: ["shaodeng", "wait", "sd"]),
        Snippet(text: "没问题。", keywords: ["meiwenti", "noproblem", "mwt"]),
        Snippet(text: "辛苦了！", keywords: ["xinkule", "xkl"]),
        Snippet(text: "我晚点回复你。", keywords: ["wandian", "huifu", "later", "wd"]),
        Snippet(text: "收到，正在处理。", keywords: ["chuli", "processing", "zzcl"]),
        Snippet(text: "请查收附件。", keywords: ["fujian", "attachment", "qcs"]),
        Snippet(text: "祝好！", keywords: ["zhuhao", "regards", "zh"]),
        Snippet(text: "抱歉，刚才在忙。", keywords: ["baoqian", "sorry", "bq"]),
        Snippet(text: "周末愉快！", keywords: ["zhoumo", "weekend", "zmyk"]),
        Snippet(text: "生日快乐！", keywords: ["shengri", "birthday", "srkl"]),
    ]

    /// The user's snippets when the file holds a valid list, else `defaults`.
    public func load() -> [Snippet] {
        guard let fileURL, let data = try? Self.readRegularFile(fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == Self.currentVersion
        else { return Self.defaults }
        let snippets = file.snippets.filter { !$0.text.isEmpty }
        return snippets.isEmpty ? Self.defaults : snippets
    }

    /// The texts of `snippets` whose keywords or text contain `query` (case-insensitive);
    /// all of them for an empty query.
    public static func matching(_ snippets: [Snippet], query: String) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return snippets.map(\.text) }
        return snippets.filter { snippet in
            snippet.keywords.contains { $0.lowercased().contains(needle) } || snippet.text.lowercased().contains(needle)
        }.map(\.text)
    }

    /// Atomically replaces the user's file with `snippets`.
    public func save(_ snippets: [Snippet]) throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: Self.currentVersion, snippets: snippets))
        guard data.count <= Self.maxFileSize else { throw Failure.tooLarge }
        var info = stat()
        if lstat(fileURL.path, &info) == 0 {
            if info.st_mode & S_IFMT == S_IFLNK { throw Failure.symlink }
            if info.st_mode & S_IFMT != S_IFREG { throw Failure.notRegular }
        }
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.io(errno) }
        var written = 0
        let failure: Int32? = data.withUnsafeBytes { buffer -> Int32? in
            while written < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + written, buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                written += count
            }
            return fsync(descriptor) == 0 ? nil : errno
        }
        close(descriptor)
        if let failure {
            unlink(temporary.path)
            throw Failure.io(failure)
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw Failure.io(code)
        }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    /// The contents of a regular file of at most `maxFileSize` bytes, opened
    /// `O_NOFOLLOW | O_NONBLOCK`.
    static func readRegularFile(_ url: URL) throws(Failure) -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw errno == ELOOP ? .symlink : .io(errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .io(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegular }
        guard info.st_size <= Self.maxFileSize else { throw .tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw .io(errno)
            }
            if count == 0 { return data }
            guard data.count + count <= Self.maxFileSize else { throw .tooLarge }
            data.append(buffer, count: count)
        }
    }
}
