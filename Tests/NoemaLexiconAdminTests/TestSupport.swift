import Compression
import CryptoKit
import Darwin
import Foundation

final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "noema-lexicon-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Builds ZIP archives byte by byte, including hostile ones a real zip tool would refuse to
/// write (`../` names, symlink and FIFO modes, lying sizes).
struct ZipBuilder {
    struct Item {
        var name: String
        var data: Data
        /// Unix `st_mode` stored in the external attributes; 0 stores none (DOS host).
        var mode: UInt32 = 0o100644
        var deflate = false
        /// Overrides the uncompressed size written to the headers.
        var declaredSize: UInt32?
        /// Overrides "version made by" (host in the high byte); default Unix (0x0314) or DOS.
        var madeBy: UInt16?
    }

    var items: [Item] = []
    /// The end-of-central-directory comment.
    var comment = Data()
    /// The comment length the EOCD declares; defaults to `comment.count`.
    var declaredCommentLength: UInt16?

    mutating func file(_ name: String, _ text: String, deflate: Bool = false) {
        items.append(Item(name: name, data: Data(text.utf8), deflate: deflate))
    }

    mutating func directory(_ name: String) {
        items.append(Item(name: name.hasSuffix("/") ? name : name + "/", data: Data(), mode: 0o040755))
    }

    mutating func symlink(_ name: String, to target: String) {
        items.append(Item(name: name, data: Data(target.utf8), mode: 0o120777))
    }

    func build() throws -> Data {
        var archive = Data()
        var central = Data()
        for item in items {
            let payload = item.deflate ? try Self.deflate(item.data) : item.data
            let crc = Self.crc32(item.data)
            let offset = UInt32(archive.count)
            let name = Data(item.name.utf8)
            let size = item.declaredSize ?? UInt32(item.data.count)
            let method: UInt16 = item.deflate ? 8 : 0
            archive.le32(0x0403_4B50); archive.le16(20); archive.le16(0x0800); archive.le16(method)
            archive.le16(0); archive.le16(0); archive.le32(crc); archive.le32(UInt32(payload.count)); archive.le32(size)
            archive.le16(UInt16(name.count)); archive.le16(0)
            archive.append(name); archive.append(payload)

            central.le32(0x0201_4B50); central.le16(item.madeBy ?? (item.mode == 0 ? 20 : 0x0314)); central.le16(20); central.le16(0x0800)
            central.le16(method); central.le16(0); central.le16(0); central.le32(crc); central.le32(UInt32(payload.count))
            central.le32(size); central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0)
            central.le16(0); central.le32(item.mode << 16); central.le32(offset)
            central.append(name)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.le32(0x0605_4B50); archive.le16(0); archive.le16(0)
        archive.le16(UInt16(items.count)); archive.le16(UInt16(items.count))
        archive.le32(UInt32(central.count)); archive.le32(centralOffset)
        archive.le16(declaredCommentLength ?? UInt16(comment.count)); archive.append(comment)
        return archive
    }

    static func deflate(_ data: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk { output.append(chunk) }
        }
        try filter.write(data)
        try filter.finalize()
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func le16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func le32(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}

/// A minimal HTTP/1.1 server on `127.0.0.1:<ephemeral>`: one response per connection,
/// served from a fixed route table on a background thread.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    let port: UInt16
    private let listener: Int32
    private let routes: [String: Response]
    private let lock = NSLock()
    private var stopped = false
    private var recorded: [String] = []
    /// Every request path served so far, read under the lock.
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(routes: [String: Response]) throws {
        self.routes = routes
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socket, 16) == 0 else {
            close(socket)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        listener = socket
        port = UInt16(bigEndian: address.sin_port)
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    deinit { stop() }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        if !wasStopped {
            shutdown(listener, SHUT_RDWR)
            close(listener)
        }
    }

    private func serve() {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            handle(connection)
            close(connection)
        }
    }

    private func handle(_ connection: Int32) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains("\r\n\r\n".data(using: .utf8)!) {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(contentsOf: buffer[0..<count])
        }
        let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first ?? ""
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        lock.lock()
        recorded.append(path)
        lock.unlock()
        let response = routes[path] ?? Response(status: 404, body: Data("not found".utf8))
        var head = "HTTP/1.1 \(response.status) X\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var output = Data(head.utf8)
        output.append(response.body)
        output.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = write(connection, raw.baseAddress! + done, raw.count - done)
                guard count > 0 else { return }
                done += count
            }
        }
    }
}
