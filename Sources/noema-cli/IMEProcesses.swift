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

    /// `pbi_uid` and start time of `pid`, or nil when it is gone or unreadable.
    static func bsdInfo(_ pid: pid_t) -> (uid: uid_t, identity: ProcessIdentity)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (info.pbi_uid, ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec))
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Processes of the current user, other than this one, whose canonical executable path
    /// is `canonicalExecutable`.
    static func running(canonicalExecutable: String) -> [ProcessIdentity] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        let me = getpid()
        let uid = getuid()
        var found: [ProcessIdentity] = []
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != me {
            guard let path = executablePath(pid),
                  (canonicalPath(path) ?? path) == canonicalExecutable,
                  let info = bsdInfo(pid), info.uid == uid
            else { continue }
            found.append(info.identity)
        }
        return found
    }

    /// True while `identity` (same pid and start time) is still alive.
    static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let info = bsdInfo(identity.pid) else { return false }
        return info.identity == identity
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
