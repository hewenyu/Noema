import CryptoKit
import Darwin
import Foundation
import NoemaCore

/// Downloads one lockfile entry: streamed by `URLSession` into a `0600` temporary file while
/// a live SHA-256 runs, cancelled the moment it exceeds the expected size (or
/// `maximumBytes`), and handed on only when size and digest match the lockfile. Redirects
/// must stay on HTTPS (or loopback HTTP when the lockfile allowed it).
///
/// Runs in the agent or `noema-cli`, never in `NoemaIME` (zero networking there).
public final class DictionaryDownloader: Sendable {
    public enum Failure: Error, Sendable, Hashable {
        case disallowedURL(String)
        case http(status: Int)
        case tooLarge(Int64)
        case sizeMismatch(expected: Int64, actual: Int64)
        case sha256Mismatch(expected: String, actual: String)
        case transport(String)
        case io(String)
    }

    public struct Download: Sendable, Hashable {
        /// The verified file; the caller moves or deletes it.
        public var file: URL
        public var size: Int64
        public var sha256: String
    }

    public let allowLoopbackHTTP: Bool
    public let timeout: TimeInterval

    public init(allowLoopbackHTTP: Bool = false, timeout: TimeInterval = 120) {
        self.allowLoopbackHTTP = allowLoopbackHTTP
        self.timeout = timeout
    }

    /// Downloads `entry` into a fresh `0600` file inside `directory` (created `0700`).
    public func download(_ entry: DictionaryLockfile.Entry, into directory: URL) async throws(Failure) -> Download {
        try await download(url: entry.url, expectedSHA256: entry.sha256, expectedSize: entry.size, into: directory)
    }

    public func download(
        url string: String, expectedSHA256: String, expectedSize: Int64, maximumBytes: Int64? = nil, into directory: URL
    ) async throws(Failure) -> Download {
        guard DictionaryLockfile.isAllowedURL(string, allowLoopbackHTTP: allowLoopbackHTTP), let url = URL(string: string) else {
            throw .disallowedURL(string)
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .io("creating \(directory.path): \(error)")
        }
        let file = directory.appending(path: ".download.\(getpid()).\(UUID().uuidString)")
        let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .io("creating \(file.path): errno \(errno)") }

        let limit = min(maximumBytes ?? expectedSize, expectedSize)
        let sink = DownloadSink(descriptor: descriptor, limit: limit, allowLoopbackHTTP: allowLoopbackHTTP)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: sink, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        let outcome: Result<(Int64, String), Failure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                sink.start(session: session, url: url, continuation: continuation)
            }
        } onCancel: {
            sink.cancel()
        }
        let closed = close(descriptor) == 0
        switch outcome {
        case .failure(let failure):
            unlink(file.path)
            throw failure
        case .success(let (size, digest)):
            guard closed else {
                unlink(file.path)
                throw .io("closing \(file.path)")
            }
            guard size == expectedSize else {
                unlink(file.path)
                throw .sizeMismatch(expected: expectedSize, actual: size)
            }
            guard digest == expectedSHA256.lowercased() else {
                unlink(file.path)
                throw .sha256Mismatch(expected: expectedSHA256, actual: digest)
            }
            return Download(file: file, size: size, sha256: digest)
        }
    }
}

/// The session delegate: writes each chunk, hashes it, and enforces the byte limit.
private final class DownloadSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let descriptor: Int32
    private let limit: Int64
    private let allowLoopbackHTTP: Bool
    private let lock = NSLock()
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var failure: DictionaryDownloader.Failure?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Result<(Int64, String), DictionaryDownloader.Failure>, Never>?
    private var cancelled = false

    init(descriptor: Int32, limit: Int64, allowLoopbackHTTP: Bool) {
        self.descriptor = descriptor
        self.limit = limit
        self.allowLoopbackHTTP = allowLoopbackHTTP
    }

    func start(
        session: URLSession, url: URL,
        continuation: CheckedContinuation<Result<(Int64, String), DictionaryDownloader.Failure>, Never>
    ) {
        let task = session.dataTask(with: URLRequest(url: url))
        lock.lock()
        self.continuation = continuation
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            finish(.failure(.transport("cancelled")))
            return
        }
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        failure = failure ?? .transport("cancelled")
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func fail(_ error: DictionaryDownloader.Failure, task: URLSessionTask) {
        lock.lock()
        failure = failure ?? error
        lock.unlock()
        task.cancel()
    }

    private func finish(_ result: Result<(Int64, String), DictionaryDownloader.Failure>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            fail(.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0), task: dataTask)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > limit {
            fail(.tooLarge(response.expectedContentLength), task: dataTask)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let total = received + Int64(data.count)
        guard failure == nil, total <= limit else {
            if failure == nil { failure = .tooLarge(total) }
            lock.unlock()
            dataTask.cancel()
            return
        }
        received = total
        hasher.update(data: data)
        lock.unlock()
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
        if !ok { fail(.io("writing the download: errno \(errno)"), task: dataTask) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url?.absoluteString,
              DictionaryLockfile.isAllowedURL(url, allowLoopbackHTTP: allowLoopbackHTTP)
        else {
            fail(.disallowedURL(request.url?.absoluteString ?? "<none>"), task: task)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let failure = self.failure
        let received = self.received
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        lock.unlock()
        if let failure {
            finish(.failure(failure))
        } else if let error {
            finish(.failure(.transport(error.localizedDescription)))
        } else if fsync(descriptor) != 0 {
            finish(.failure(.io("fsync the download: errno \(errno)")))
        } else {
            finish(.success((received, digest)))
        }
    }
}
