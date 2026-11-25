import CryptoKit
import Darwin
import Foundation
import NoemaCore

/// `noema-cli install`: copy a built `NoemaIME.app` into an Input Methods directory.
///
/// The bundle is copied into a staging directory inside `--dest` first and every check
/// runs on that copy, so what was checked is exactly what is installed. The swap is two
/// `rename(2)` calls under a per-destination `flock`, rolled back if the second fails; an
/// existing target that is not a Noema bundle is never touched.
enum InstallCommand {
    static let usage = """
        usage: noema-cli install [--bundle <path>] [--dest <dir>] [--allow-adhoc]
                                 [--register | --no-register] [--reload | --no-reload]

          --bundle <path>  bundle to install (default dist/NoemaIME.app)
          --dest <dir>     Input Methods directory (default ~/Library/Input Methods)
          --allow-adhoc    accept an ad-hoc signature (local development only)
          --register       register with Text Input Sources even for a custom --dest
          --no-register    skip registration
          --reload         stop running NoemaIME processes of the target even for a custom --dest
          --no-reload      leave running NoemaIME processes alone

        Registration and reload default to on for ~/Library/Input Methods and to off for
        any other --dest, so a staging install never changes system input sources.
        """

    struct Options {
        var bundle: URL
        var dest: URL
        var allowAdhoc = false
        var register: Bool
        var reload: Bool
    }

    static func run(_ arguments: [String]) -> Int32 {
        if arguments == ["-h"] || arguments == ["--help"] {
            print(usage)
            return 0
        }
        do {
            let options = try parse(arguments)
            try install(options)
            return 0
        } catch {
            fputs("noema-cli install: \(error.message)\n", stderr)
            if error.status == 2 { fputs(usage + "\n", stderr) }
            return error.status
        }
    }

    static func parse(_ arguments: [String]) throws(CLIError) -> Options {
        var parser = OptionParser(command: "install", arguments: arguments)
        let (values, flags) = try parser.parse(
            valued: ["--bundle", "--dest"],
            flags: ["--allow-adhoc", "--register", "--no-register", "--reload", "--no-reload"])
        if flags.contains("--register") && flags.contains("--no-register") {
            throw CLIError("--register and --no-register conflict", status: 2)
        }
        if flags.contains("--reload") && flags.contains("--no-reload") {
            throw CLIError("--reload and --no-reload conflict", status: 2)
        }
        for key in ["--bundle", "--dest"] {
            if let value = values[key], value.isEmpty || value.split(separator: "/").contains("..") {
                throw CLIError("\(key) must be non-empty and contain no .. component: \(value)", status: 2)
            }
        }
        let defaultDest = NoemaPaths.inputMethodsDir()
        let dest = values["--dest"].map { absoluteURL($0) } ?? defaultDest
        let isDefaultDest = dest.fileSystemPath == defaultDest.fileSystemPath
        return Options(
            bundle: absoluteURL(values["--bundle"] ?? "dist/\(NoemaPaths.imeBundleName)"),
            dest: dest,
            allowAdhoc: flags.contains("--allow-adhoc"),
            register: flags.contains("--register") || (isDefaultDest && !flags.contains("--no-register")),
            reload: flags.contains("--reload") || (isDefaultDest && !flags.contains("--no-reload"))
        )
    }

    // MARK: - Install

    static func install(_ options: Options) throws(CLIError) {
        let fileManager = FileManager.default
        let destPath = options.dest.fileSystemPath
        guard destPath != "/" else { throw CLIError("refusing to install into /") }
        switch FileKind.of(destPath) {
        case .missing:
            do {
                try fileManager.createDirectory(at: options.dest, withIntermediateDirectories: true)
            } catch {
                throw CLIError("cannot create \(destPath): \(error.localizedDescription)")
            }
        case .directory: break
        case .symlink: throw CLIError("--dest is a symlink, refusing: \(destPath)")
        default: throw CLIError("--dest exists and is not a directory: \(destPath)")
        }
        guard let canonicalDest = IMEProcesses.canonicalPath(destPath) else {
            throw CLIError("cannot resolve --dest \(destPath)")
        }

        let bundlePath = options.bundle.fileSystemPath
        switch FileKind.of(bundlePath) {
        case .directory: break
        case .missing: throw CLIError("bundle not found: \(bundlePath) (build it with scripts/build/bundle.sh)")
        case .symlink: throw CLIError("bundle is a symlink, refusing: \(bundlePath)")
        default: throw CLIError("bundle is not a directory: \(bundlePath)")
        }

        // 1. Stage a private copy inside dest (same file system, so the swap is a rename).
        let tag = "\(getpid()).\(UUID().uuidString)"
        let staging = "\(canonicalDest)/.\(NoemaPaths.imeBundleName).install-staging.\(tag)"
        guard mkdir(staging, 0o700) == 0 else {
            throw CLIError("cannot create staging directory \(staging): \(String(cString: strerror(errno)))")
        }
        defer { try? fileManager.removeItem(atPath: staging) }
        let staged = "\(staging)/\(NoemaPaths.imeBundleName)"
        let ditto = runTool("/usr/bin/ditto", [bundlePath, staged])
        guard ditto.status == 0 else { throw CLIError("ditto failed: \(ditto.stderr.trimmed)") }

        // 2. Validate the staged copy, never the source.
        try validateBundle(staged)
        try validateSignature(staged, allowAdhoc: options.allowAdhoc)

        // 3. Swap under the per-destination lock.
        let target = "\(canonicalDest)/\(NoemaPaths.imeBundleName)"
        let executable = "\(target)/Contents/MacOS/\(NoemaPaths.imeExecutableName)"
        let lock = try lockDestination(canonicalDest)
        defer { close(lock) }
        try ensureReplaceable(target)
        // Before the swap: once renamed away, an old process's executable no longer has
        // the target path.
        let before = IMEProcesses.running(canonicalExecutable: executable)
        let old = "\(canonicalDest)/.\(NoemaPaths.imeBundleName).old.\(tag)"
        let hadTarget = FileKind.of(target) != .missing
        if hadTarget, rename(target, old) != 0 {
            throw CLIError("cannot move the installed bundle aside: \(String(cString: strerror(errno)))")
        }
        if rename(staged, target) != 0 {
            let reason = String(cString: strerror(errno))
            if hadTarget, rename(old, target) != 0 {
                throw CLIError("install failed (\(reason)) and the previous bundle stays at \(old)")
            }
            throw CLIError("install failed, previous bundle restored: \(reason)")
        }
        syncDirectory(canonicalDest)
        if hadTarget { try? fileManager.removeItem(atPath: old) }
        print("installed \(target)")

        // 4. Register and reload.
        if options.register {
            let status = IMEProcesses.register(bundle: URL(filePath: target, directoryHint: .isDirectory))
            if status == noErr {
                print("registered with Text Input Sources (enable Noema in System Settings > Keyboard > Input Sources)")
            } else {
                fputs("noema-cli install: TISRegisterInputSource returned \(status)\n", stderr)
            }
        }
        if options.reload {
            let after = IMEProcesses.running(canonicalExecutable: executable)
            let (signalled, remaining) = IMEProcesses.terminate(before + after)
            print("reloaded: stopped \(signalled) NoemaIME process(es); macOS relaunches it on next use")
            if remaining > 0 { fputs("noema-cli install: \(remaining) process(es) did not exit within 3 s\n", stderr) }
        }
    }

    /// The installed bundle may be replaced only when it is a real directory holding a
    /// regular `Contents/Info.plist` with Noema's bundle identifier.
    static func ensureReplaceable(_ target: String) throws(CLIError) {
        switch FileKind.of(target) {
        case .missing: return
        case .directory: break
        default: throw CLIError("\(target) is not a directory; refusing to replace it")
        }
        let info = "\(target)/Contents/Info.plist"
        guard FileKind.of(info) == .regular, let plist = readPlist(info),
              plist["CFBundleIdentifier"] as? String == NoemaPaths.imeBundleID
        else {
            throw CLIError("\(target) is not a Noema input method (CFBundleIdentifier is not \(NoemaPaths.imeBundleID)); refusing to replace it")
        }
    }

    static func validateBundle(_ app: String) throws(CLIError) {
        let contents = "\(app)/Contents"
        let info = "\(contents)/Info.plist"
        guard FileKind.of(info) == .regular, let plist = readPlist(info) else {
            throw CLIError("bundle has no regular Contents/Info.plist")
        }
        let expected = [
            "CFBundleIdentifier": NoemaPaths.imeBundleID,
            "InputMethodServerControllerClass": NoemaPaths.imeControllerClassName,
            "InputMethodConnectionName": NoemaPaths.imeConnectionName,
        ]
        for (key, value) in expected.sorted(by: { $0.key < $1.key }) where plist[key] as? String != value {
            throw CLIError("Info.plist \(key) is \(String(describing: plist[key] ?? "missing")), expected \(value)")
        }
        for name in [NoemaPaths.imeExecutableName, "noema-rime-deployer"] {
            let path = "\(contents)/MacOS/\(name)"
            guard FileKind.of(path) == .regular, access(path, X_OK) == 0 else {
                throw CLIError("bundle lacks an executable regular file Contents/MacOS/\(name)")
            }
        }
        guard FileKind.of("\(contents)/Frameworks/librime.1.dylib") == .regular else {
            throw CLIError("bundle lacks a regular Contents/Frameworks/librime.1.dylib")
        }
        let rimeDefault = "\(contents)/Resources/\(NoemaPaths.rimeDefaultDirectoryName)"
        guard FileKind.of(rimeDefault) == .directory else {
            throw CLIError("bundle lacks the directory Contents/Resources/rime-default")
        }
        for file in ["default.yaml", "noema_pinyin.schema.yaml", "noema_pinyin.dict.yaml"] {
            guard FileKind.of("\(rimeDefault)/\(file)") == .regular else {
                throw CLIError("bundle lacks a regular Contents/Resources/rime-default/\(file)")
            }
        }
    }

    static func validateSignature(_ app: String, allowAdhoc: Bool) throws(CLIError) {
        let verify = runTool("/usr/bin/codesign", ["--verify", "--strict", "--deep", app])
        guard verify.status == 0 else {
            throw CLIError("code signature is invalid: \(verify.stderr.trimmed)")
        }
        let details = runTool("/usr/bin/codesign", ["-dvv", app])
        guard details.status == 0 else { throw CLIError("cannot read the code signature: \(details.stderr.trimmed)") }
        let isAdhoc = details.stderr.split(separator: "\n").contains("Signature=adhoc")
        if isAdhoc && !allowAdhoc {
            throw CLIError("""
                the bundle is ad-hoc signed. Sign it with a certificate \
                (scripts/build/bundle.sh --sign <SHA-1>), or pass --allow-adhoc to install \
                an ad-hoc build for local development
                """)
        }
        if isAdhoc {
            fputs("noema-cli install: warning: installing an ad-hoc signed bundle (local development only)\n", stderr)
        }
    }

    /// Blocks until this process holds the exclusive install lock for `canonicalDest`.
    static func lockDestination(_ canonicalDest: String) throws(CLIError) -> Int32 {
        let digest = SHA256.hash(data: Data(canonicalDest.utf8)).map { String(format: "%02x", $0) }.joined()
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        let path = "\(tmp.hasSuffix("/") ? String(tmp.dropLast()) : tmp)/noema-ime-install-\(digest).lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CLIError("cannot open install lock \(path): \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw CLIError("cannot lock \(path): \(String(cString: strerror(errno)))")
        }
        return descriptor
    }

    static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func syncDirectory(_ path: String) {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}

/// What `lstat(2)` finds at a path; symlinks are never followed.
enum FileKind: Equatable {
    case missing, regular, directory, symlink, other, unreadable

    static func of(_ path: String) -> FileKind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regular
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }
}

/// Runs a system tool to completion, capturing stdout and stderr.
func runTool(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        return (127, "", "cannot run \(executable): \(error.localizedDescription)")
    }
    // Drain stderr concurrently so neither pipe fills up and blocks the tool.
    nonisolated(unsafe) var errorData = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        errorData = errors.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    drained.wait()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: outputData, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
