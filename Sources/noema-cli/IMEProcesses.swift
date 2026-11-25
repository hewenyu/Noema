import Carbon.HIToolbox
import Darwin
import Foundation
import NoemaCore

/// A running process identified by pid plus start time, so a recycled pid is never
/// mistaken for the process that was found.
struct ProcessIdentity: Hashable {
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
    /// is `canonicalExecutable`.
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

    /// True while `identity` (same pid and start time) is still running; an exited but
    /// unreaped zombie counts as gone.
    static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let info = bsdInfo(identity.pid) else { return false }
        return info.identity == identity && !info.isZombie
    }

    /// Sends SIGTERM to each process that is still the same process and still ours, then
    /// waits up to `timeout` for all of them to exit. Returns (signalled, still running).
    static func terminate(_ identities: [ProcessIdentity], timeout: Duration = .seconds(3)) -> (signalled: Int, remaining: Int) {
        let uid = getuid()
        var signalled: [ProcessIdentity] = []
        for identity in Set(identities) {
            guard let info = bsdInfo(identity.pid), info.uid == uid, info.identity == identity else { continue }
            if kill(identity.pid, SIGTERM) == 0 { signalled.append(identity) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var remaining = signalled.filter(isAlive)
        while !remaining.isEmpty, clock.now < deadline {
            usleep(50_000)
            remaining = remaining.filter(isAlive)
        }
        return (signalled.count, remaining.count)
    }

    /// Registers the bundle with Text Input Sources so it appears in System Settings.
    static func register(bundle: URL) -> OSStatus {
        TISRegisterInputSource(bundle as CFURL)
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
