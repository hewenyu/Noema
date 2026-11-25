import Carbon.HIToolbox
import CryptoKit
import Darwin
import Foundation
import NoemaCore

/// A running process identified by pid plus start time, so a recycled pid is never
/// mistaken for the process that was found.
struct ProcessIdentity: Hashable, Codable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

/// Finds and stops this user's `NoemaIME` processes by canonical executable path.
enum IMEProcesses {
    /// The canonical path of `path`, resolving every symlink; nil when it does not exist.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `pbi_uid`, start time, and zombie state of `pid`, or nil when it is gone or unreadable.
    static func bsdInfo(_ pid: pid_t) -> (uid: uid_t, identity: ProcessIdentity, isZombie: Bool)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let identity = ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        return (info.pbi_uid, identity, info.pbi_status == UInt32(SZOMB))
    }

    /// Every pid on the system, retrying with a larger buffer (up to four times) while a
    /// full buffer means the list may have been truncated; the last list is best effort.
    static func allPIDs() -> [pid_t] {
        var capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var pids: [pid_t] = []
        for _ in 0..<4 {
            capacity += max(64, capacity / 4)
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = Int(buffer.withUnsafeMutableBufferPointer { pointer in
                proc_listallpids(pointer.baseAddress, Int32(pointer.count * MemoryLayout<pid_t>.size))
            })
            guard count > 0 else { return pids }
            pids = Array(buffer.prefix(min(count, capacity)))
            if count < capacity { break }
        }
        return pids
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Processes of the current user, other than this one, whose canonical executable path
    /// is `canonicalExecutable`. The pid's identity is read before and after its path, so
    /// a pid recycled in between is skipped rather than attributed the other's path.
    static func running(canonicalExecutable: String) -> [ProcessIdentity] {
        let me = getpid()
        let uid = getuid()
        var found: [ProcessIdentity] = []
        for pid in allPIDs() where pid > 0 && pid != me {
            guard let before = bsdInfo(pid), before.uid == uid, !before.isZombie,
                  let path = executablePath(pid),
                  (canonicalPath(path) ?? path) == canonicalExecutable,
                  let after = bsdInfo(pid), after.uid == uid, !after.isZombie,
                  after.identity == before.identity
            else { continue }
            found.append(before.identity)
        }
        return found
    }

    /// Processes running from a bundle an interrupted install left in `canonicalDest`:
    /// `.NoemaIME.app.old.*` or `.NoemaIME.app.install-staging.*/NoemaIME.app`, except the
    /// staging directory `excluding`. Only a regular executable reached without symlinks counts.
    static func runningInLeftoverBundles(in canonicalDest: String, excluding: String? = nil) -> [ProcessIdentity] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: canonicalDest) else { return [] }
        var found: [ProcessIdentity] = []
        for name in entries.sorted() where name != excluding {
            let bundle: String
            if name.hasPrefix(InstallCommand.oldPrefix) {
                bundle = "\(canonicalDest)/\(name)"
            } else if name.hasPrefix(InstallCommand.stagingPrefix) {
                bundle = "\(canonicalDest)/\(name)/\(NoemaPaths.imeBundleName)"
            } else {
                continue
            }
            let executable = "\(bundle)/Contents/MacOS/\(NoemaPaths.imeExecutableName)"
            guard FileKind.of(bundle) == .directory, FileKind.of(executable) == .regular,
                  canonicalPath(executable) == executable
            else { continue }
            found += running(canonicalExecutable: executable)
        }
        return found
    }

    /// True while `identity` (same pid and start time) is still running; an exited but
    /// unreaped zombie counts as gone.
    static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let info = bsdInfo(identity.pid) else { return false }
        return info.identity == identity && !info.isZombie
    }

    struct TerminateResult {
        /// Processes sent SIGTERM.
        let signalled: Int
        /// Signalled processes that exited within the timeout.
        let stopped: Int
        /// Signalled processes still running at the timeout.
        let remaining: [ProcessIdentity]
    }

    /// Sends SIGTERM to each process that is still the same process (pid and start time),
    /// still ours, and not a zombie, then waits up to `timeout` for all of them to exit.
    static func terminate(_ identities: [ProcessIdentity], timeout: Duration = .seconds(3)) -> TerminateResult {
        let uid = getuid()
        var signalled: [ProcessIdentity] = []
        for identity in Set(identities) {
            guard let info = bsdInfo(identity.pid), info.uid == uid, info.identity == identity, !info.isZombie
            else { continue }
            if kill(identity.pid, SIGTERM) == 0 { signalled.append(identity) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var remaining = signalled.filter(isAlive)
        while !remaining.isEmpty, clock.now < deadline {
            usleep(50_000)
            remaining = remaining.filter(isAlive)
        }
        return TerminateResult(signalled: signalled.count, stopped: signalled.count - remaining.count, remaining: remaining)
    }

    /// Lowercase hex SHA-256 of `text`, naming per-path files in the temporary directory.
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Blocks until this process holds the exclusive install lock for `canonicalDirectory`
    /// (an Input Methods directory). `install` and `reload` both take it, so the swap, the
    /// pending-reload ledger, and the termination never interleave. Returns the descriptor.
    static func lockDirectory(_ canonicalDirectory: String) throws(CLIError) -> Int32 {
        // The per-user temporary directory, never the shared /tmp.
        let path = FileManager.default.temporaryDirectory
            .appending(path: "noema-ime-install-\(digest(canonicalDirectory)).lock", directoryHint: .notDirectory).fileSystemPath
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CLIError("cannot open install lock \(path): \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw CLIError("cannot lock \(path): \(String(cString: strerror(errno)))")
        }
        return descriptor
    }

    /// Registers the bundle with Text Input Sources so it appears in System Settings.
    static func register(bundle: URL) -> OSStatus {
        TISRegisterInputSource(bundle as CFURL)
    }
}

/// Processes of a replaced bundle that still have to be stopped: what `install --no-reload`
/// saw running before the swap, or what a `--reload` or `reload` could not stop in time.
/// Once a bundle is renamed away its processes no longer run from the target path, so a
/// later `reload` finds them only here.
///
/// One JSON file per user and canonical target bundle in the per-user temporary
/// directory, read and written only under `IMEProcesses.lockDirectory` of the bundle's
/// parent. Reads refuse a symlink, a non-regular file, another owner, more than 64 KiB, or
/// a payload for another uid or bundle; writes go through an fsynced `0600` sibling and
/// `rename(2)`. Every identity is re-checked (pid, start time, uid) before any signal.
enum PendingReloadStore {
    struct Payload: Codable {
        let uid: uid_t
        let canonicalBundle: String
        let processes: [ProcessIdentity]
    }

    static let maximumSize = 64 * 1024

    static func path(canonicalBundle: String) -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "noema-ime-pending-reload-\(IMEProcesses.digest(canonicalBundle)).json", directoryHint: .notDirectory)
            .fileSystemPath
    }

    /// The recorded processes that are still alive; empty when there is no valid ledger.
    static func load(canonicalBundle: String) -> [ProcessIdentity] {
        let descriptor = open(path(canonicalBundle: canonicalBundle), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size <= off_t(maximumSize)
        else { return [] }
        var bytes = [UInt8](repeating: 0, count: maximumSize + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + total, $0.count - total) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            total += count
        }
        guard total <= maximumSize,
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(bytes[0..<total])),
              payload.uid == getuid(), payload.canonicalBundle == canonicalBundle
        else { return [] }
        return payload.processes.filter(IMEProcesses.isAlive)
    }

    /// Records `processes` (deduplicated); an empty list removes the ledger.
    static func save(_ processes: [ProcessIdentity], canonicalBundle: String) throws(CLIError) {
        let unique = Array(Set(processes)).sorted { $0.pid < $1.pid }
        guard !unique.isEmpty else { return clear(canonicalBundle: canonicalBundle) }
        let final = path(canonicalBundle: canonicalBundle)
        guard let data = try? JSONEncoder().encode(Payload(uid: getuid(), canonicalBundle: canonicalBundle, processes: unique)),
              data.count <= maximumSize
        else { throw CLIError("cannot encode the pending-reload ledger") }
        let temporary = "\(final).tmp.\(getpid())"
        unlink(temporary)
        let descriptor = open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CLIError("cannot write the pending-reload ledger \(temporary): \(String(cString: strerror(errno)))")
        }
        var ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        ok = ok && fsync(descriptor) == 0
        ok = close(descriptor) == 0 && ok
        guard ok, rename(temporary, final) == 0 else {
            unlink(temporary)
            throw CLIError("cannot write the pending-reload ledger \(final)")
        }
        InstallCommand.syncDirectory(FileManager.default.temporaryDirectory.fileSystemPath)
    }

    static func clear(canonicalBundle: String) {
        if unlink(path(canonicalBundle: canonicalBundle)) == 0 {
            InstallCommand.syncDirectory(FileManager.default.temporaryDirectory.fileSystemPath)
        }
    }
}

/// Command-line errors: a message for stderr and an exit status.
struct CLIError: Error {
    let message: String
    let status: Int32

    init(_ message: String, status: Int32 = 1) {
        self.message = message
        self.status = status
    }
}

/// Reads `--name value` and `--flag` options; anything unknown is a usage error.
struct OptionParser {
    private var arguments: [String]
    let command: String

    init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }

    /// Consumes every listed option, returning values for `valued` and presence for `flags`.
    mutating func parse(valued: Set<String>, flags: Set<String>) throws(CLIError) -> (values: [String: String], flags: Set<String>) {
        var values: [String: String] = [:]
        var present: Set<String> = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valued.contains(argument) {
                guard index + 1 < arguments.count else { throw CLIError("\(command): \(argument) needs a value", status: 2) }
                values[argument] = arguments[index + 1]
                index += 2
            } else if flags.contains(argument) {
                present.insert(argument)
                index += 1
            } else {
                throw CLIError("\(command): unknown argument \(argument)", status: 2)
            }
        }
        return (values, present)
    }
}

/// Absolute file URL for a path given on the command line (relative to the current directory).
func absoluteURL(_ path: String, isDirectory: Bool = true) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    let base = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    return URL(filePath: expanded, directoryHint: isDirectory ? .isDirectory : .notDirectory, relativeTo: base)
        .standardizedFileURL
}

extension URL {
    /// The file-system path with no trailing slash: `lstat("link/")` would follow a
    /// symlink, so every no-follow check uses this form.
    var fileSystemPath: String {
        var path = standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
