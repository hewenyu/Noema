import Darwin
import Foundation
import NoemaCore

/// Crash-loop sentinel and single-writer lock for a Rime `user_data_dir`.
///
/// - **Lock** `<user_data_dir>/.noema-rime.lock`: a non-blocking exclusive `flock(2)`.
///   Only the holder may open Rime's user data (LevelDB userdbs). The kernel drops the lock
///   when the holder exits, even on a crash, so the lock is never stale.
/// - **Sentinel** `<user_data_dir>/.noema-boot-guard`: JSON
///   `{"consecutiveFailures": n, "lastAttemptEpoch": t}`. `arm()` refuses to boot once `n`
///   reaches the threshold and otherwise writes `n + 1` before the engine loads; `disarm()`
///   removes it after a successful load. A crash in between leaves the count raised.
///
/// Not thread-safe; the owning engine serializes calls.
public final class BootGuard {
    public static let lockFileName = ".noema-rime.lock"
    public static let sentinelFileName = ".noema-boot-guard"
    /// Sentinels larger than this are treated as corrupted rather than read.
    static let maximumSentinelSize = 4096

    public enum LockOutcome: Sendable, Hashable {
        case acquired
        /// Another open file description holds the lock (another process, or another
        /// engine in this one).
        case locked
        /// The lock file could not be opened or locked; the reason says why.
        case failed(SafeModeReason)
    }

    public enum Decision: Sendable, Hashable {
        /// Boot may proceed; this attempt is number `attempt` since the last success.
        case proceed(attempt: Int)
        /// The lock is held elsewhere; nothing was read or written.
        case locked
        case enterSafeMode(SafeModeReason)
    }

    /// The sentinel's on-disk record.
    public struct Record: Sendable, Hashable, Codable {
        public var consecutiveFailures: Int
        public var lastAttemptEpoch: Double

        public init(consecutiveFailures: Int, lastAttemptEpoch: Double) {
            self.consecutiveFailures = consecutiveFailures
            self.lastAttemptEpoch = lastAttemptEpoch
        }
    }

    public let userDataDir: URL
    public let threshold: Int
    private let now: @Sendable () -> TimeInterval
    private var lockDescriptor: Int32 = -1

    public var lockURL: URL { userDataDir.appending(path: Self.lockFileName) }
    public var sentinelURL: URL { userDataDir.appending(path: Self.sentinelFileName) }
    public var holdsLock: Bool { lockDescriptor >= 0 }

    public init(
        userDataDir: URL,
        threshold: Int = 2,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.userDataDir = userDataDir
        self.threshold = max(threshold, 1)
        self.now = now
    }

    deinit {
        releaseLock()
    }

    /// Takes the lock (if not held) and arms the sentinel.
    public func begin() -> Decision {
        switch acquireLock() {
        case .acquired: return arm()
        case .locked: return .locked
        case .failed(let reason): return .enterSafeMode(reason)
        }
    }

    /// Non-blocking exclusive `flock` on the lock file. Idempotent while held.
    public func acquireLock() -> LockOutcome {
        if holdsLock { return .acquired }
        let (descriptor, openErrno) = lockURL.withUnsafeFileSystemRepresentation { path in
            Self.openCapturingErrno(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            // A symlink (ELOOP) or a directory (EISDIR) squatting on the lock path is the
            // same corruption fstat reports for any other non-regular file.
            let squatted = openErrno == ELOOP || openErrno == EISDIR
            return .failed(squatted ? .bootGuardCorrupted : .userDataDirUnwritable)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return .failed(.bootGuardCorrupted)
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK ? .locked : .failed(.userDataDirUnwritable)
        }
        lockDescriptor = descriptor
        return .acquired
    }

    /// Drops the lock. Idempotent.
    public func releaseLock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    /// Reads the sentinel, refuses a crash loop, and records this attempt durably.
    /// Requires the lock; without it, returns `.locked` and touches nothing.
    public func arm() -> Decision {
        guard holdsLock else { return .locked }
        let record: Record
        switch readRecord() {
        case .success(let value): record = value ?? Record(consecutiveFailures: 0, lastAttemptEpoch: 0)
        case .failure: return .enterSafeMode(.bootGuardCorrupted)
        }
        if record.consecutiveFailures >= threshold { return .enterSafeMode(.bootCrashLoop) }
        let next = Record(consecutiveFailures: record.consecutiveFailures + 1, lastAttemptEpoch: now())
        guard write(next) else { return .enterSafeMode(.userDataDirUnwritable) }
        return .proceed(attempt: next.consecutiveFailures)
    }

    /// Marks the boot successful by removing the sentinel. Requires the lock; without
    /// it, returns false and leaves the holder's sentinel alone.
    @discardableResult
    public func disarm() -> Bool {
        guard holdsLock else { return false }
        return removeSentinel()
    }

    /// Recovery: removes the sentinel whatever it is (a regular file, a symlink, an empty
    /// directory), so the next `arm()` starts from zero. Requires the lock; without it,
    /// returns false and leaves the holder's sentinel alone.
    @discardableResult
    public func clear() -> Bool {
        guard holdsLock else { return false }
        return removeSentinel()
    }

    struct CorruptedSentinel: Error {}

    /// `open(2)` on a file-system path, with `errno` captured right after the call and
    /// inside the path's lifetime, so nothing in between can clobber it. A URL with no
    /// file-system representation (`path == nil`) reports `EINVAL`, never a stale errno.
    static func openCapturingErrno(_ path: UnsafePointer<CChar>?, _ flags: Int32, _ mode: mode_t = 0) -> (descriptor: Int32, error: Int32) {
        guard let path else { return (-1, EINVAL) }
        let descriptor = Darwin.open(path, flags, mode)
        return (descriptor, descriptor < 0 ? errno : 0)
    }

    /// `nil` when there is no sentinel; failure when it is unreadable, not a regular file
    /// (including a symlink), oversized, or not a valid record.
    func readRecord() -> Result<Record?, CorruptedSentinel> {
        let (descriptor, openErrno) = sentinelURL.withUnsafeFileSystemRepresentation { path in
            Self.openCapturingErrno(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        if descriptor < 0 {
            return openErrno == ENOENT ? .success(nil) : .failure(CorruptedSentinel())
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size <= off_t(Self.maximumSentinelSize)
        else { return .failure(CorruptedSentinel()) }
        var bytes = [UInt8](repeating: 0, count: Self.maximumSentinelSize + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                read(descriptor, buffer.baseAddress! + total, buffer.count - total)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(CorruptedSentinel())
            }
            if count == 0 { break }
            total += count
        }
        guard total <= Self.maximumSentinelSize,
              let record = try? JSONDecoder().decode(Record.self, from: Data(bytes[0..<total])),
              record.consecutiveFailures >= 0, record.lastAttemptEpoch.isFinite
        else { return .failure(CorruptedSentinel()) }
        return .success(record)
    }

    /// Writes `record` to a temporary file beside the sentinel, fsyncs it, and renames
    /// it over the sentinel, so a crash leaves either the old or the new record.
    func write(_ record: Record) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let temporary = userDataDir.appending(path: "\(Self.sentinelFileName).tmp.\(getpid())")
        let written = temporary.withUnsafeFileSystemRepresentation { tempPath -> Bool in
            guard let tempPath else { return false }
            unlink(tempPath)
            let descriptor = open(tempPath, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return false }
            var ok = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    // A zero-byte write makes no progress; retrying could spin forever.
                    if count == 0 { return false }
                    offset += count
                }
                return true
            }
            ok = ok && fsync(descriptor) == 0
            ok = close(descriptor) == 0 && ok
            if ok {
                ok = sentinelURL.withUnsafeFileSystemRepresentation { finalPath in
                    guard let finalPath else { return false }
                    return rename(tempPath, finalPath) == 0
                }
            }
            if !ok { unlink(tempPath) }
            return ok
        }
        if written { syncDirectory() }
        return written
    }

    private func syncDirectory() {
        userDataDir.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            fsync(descriptor)
            close(descriptor)
        }
    }

    /// Removes the sentinel and, when something was removed, fsyncs the directory so the
    /// removal survives a crash.
    private func removeSentinel() -> Bool {
        enum Removal { case removed, absent, failed }
        let removal = sentinelURL.withUnsafeFileSystemRepresentation { path -> Removal in
            guard let path else { return .failed }
            if unlink(path) == 0 { return .removed }
            let code = errno
            if code == ENOENT { return .absent }
            if code == EPERM || code == EISDIR { return rmdir(path) == 0 ? .removed : .failed }
            return .failed
        }
        if removal == .removed { syncDirectory() }
        return removal != .failed
    }
}
