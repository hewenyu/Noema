import Darwin
import Foundation
import NoemaCore

/// `noema-cli install`: copy a built `NoemaIME.app` into an Input Methods directory.
///
/// Everything runs under a per-destination `flock`. Leftovers of an interrupted install are
/// recovered first: a missing target comes back from its newest valid `.old.*` backup,
/// then stale `.old.*` and `.install-staging.*` entries go. The bundle is copied into a
/// staging directory inside `--dest` and every check runs on that copy, so what was
/// checked is exactly what is installed. An upgrade swaps it in with one
/// `renamex_np(RENAME_SWAP)`, so the target never disappears; only a file system without
/// it gets two `rename(2)` calls, rolled back if the second fails. The swap, its cleanup,
/// and the pending-reload ledger run with `SIGINT`/`SIGTERM`/`SIGHUP` held back until they
/// finish. An existing target that is not a Noema bundle is never touched. Processes of the
/// replaced bundle go to the `PendingReloadStore` before the swap, and those started during
/// it (found in the replaced bundle) before that bundle is deleted, so a later
/// `noema-cli reload` stops whatever `--no-reload`, a reload timeout (exit 1), or a
/// `SIGKILL` left running.
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

        // 1. Lock the destination, then recover what an interrupted install left behind.
        // Staging happens under the lock too, so every other staging directory is stale.
        let lock = try IMEProcesses.lockDirectory(canonicalDest)
        defer { close(lock) }
        let target = "\(canonicalDest)/\(NoemaPaths.imeBundleName)"
        let tag = "\(getpid()).\(UUID().uuidString)"
        let stagingName = "\(stagingPrefix)\(tag)"
        try recoverInterruptedInstalls(in: canonicalDest, keepingStaging: stagingName)

        // 2. Stage a private copy inside dest (same file system, so the swap is a rename).
        let staging = "\(canonicalDest)/\(stagingName)"
        guard mkdir(staging, 0o700) == 0 else {
            throw CLIError("cannot create staging directory \(staging): \(String(cString: strerror(errno)))")
        }
        // Kept only when the replaced bundle in it still has processes nobody recorded.
        var keepStaging = false
        defer { if !keepStaging { try? fileManager.removeItem(atPath: staging) } }
        let staged = "\(staging)/\(NoemaPaths.imeBundleName)"
        let ditto = runTool("/usr/bin/ditto", [bundlePath, staged])
        guard ditto.status == 0 else { throw CLIError("ditto failed: \(ditto.stderr.trimmed)") }

        // 3. Validate the staged copy, never the source.
        try validateBundle(staged)
        try validateSignature(staged, allowAdhoc: options.allowAdhoc)

        // 4. Swap.
        let executable = "\(target)/Contents/MacOS/\(NoemaPaths.imeExecutableName)"
        try ensureReplaceable(target)
        // Before the swap: once renamed away, an old process's executable no longer has
        // the target path. Earlier `--no-reload` installs or timed-out reloads left theirs
        // in the pending-reload ledger. The ledger is written before the swap (a write-ahead
        // log), so a SIGKILL right after it cannot lose them.
        let pending = PendingReloadStore.load(canonicalBundle: target)
        let before = IMEProcesses.running(canonicalExecutable: executable)
        let hadTarget = FileKind.of(target) != .missing
        try PendingReloadStore.save(pending + before, canonicalBundle: target)
        let replacedProcesses = try withTerminationSignalsBlocked { () throws(CLIError) -> [ProcessIdentity] in
            let old = "\(canonicalDest)/\(oldPrefix)\(tag)"
            var movedAside = false
            if hadTarget {
                // One kernel operation: the target is never missing, even on SIGKILL, and
                // the previous bundle lands at `staged`, deleted with `staging` below.
                if renamex_np(staged, target, UInt32(RENAME_SWAP)) != 0 {
                    let swapErrno = errno
                    guard swapErrno == ENOTSUP || swapErrno == EINVAL else {
                        throw CLIError("install swap failed, previous bundle kept: \(String(cString: strerror(swapErrno)))")
                    }
                    // No RENAME_SWAP on this file system: two renames, rolled back on failure.
                    if rename(target, old) != 0 {
                        let asideErrno = errno
                        throw CLIError("cannot move the installed bundle aside: \(String(cString: strerror(asideErrno)))")
                    }
                    movedAside = true
                    if rename(staged, target) != 0 {
                        let installErrno = errno
                        let reason = String(cString: strerror(installErrno))
                        if rename(old, target) != 0 {
                            throw CLIError("install failed (\(reason)) and the previous bundle stays at \(old)")
                        }
                        throw CLIError("install failed, previous bundle restored: \(reason)")
                    }
                }
            } else if rename(staged, target) != 0 {
                let installErrno = errno
                throw CLIError("install failed: \(String(cString: strerror(installErrno)))")
            }
            syncDirectory(canonicalDest)
            // A process started from the target after `before` was taken now runs from the
            // replaced bundle: find it there and record it before that bundle is deleted.
            var replaced = pending + before
            if hadTarget {
                let replacedBundle = movedAside ? old : staged
                let raw = "\(replacedBundle)/Contents/MacOS/\(NoemaPaths.imeExecutableName)"
                let duringSwap = IMEProcesses.running(canonicalExecutable: IMEProcesses.canonicalPath(raw) ?? raw)
                if !duringSwap.isEmpty {
                    replaced += duringSwap
                    do throws(CLIError) {
                        try PendingReloadStore.save(replaced, canonicalBundle: target)
                    } catch {
                        // Keep the replaced bundle: a later install or reload finds them in it.
                        keepStaging = true
                        throw CLIError("""
                            installed \(target), but cannot record the processes of the replaced bundle \
                            \(replacedBundle) (\(error.message)); retry with noema-cli reload --bundle \(target)
                            """)
                    }
                }
            }
            if movedAside { try? fileManager.removeItem(atPath: old) }
            try? fileManager.removeItem(atPath: staging)
            syncDirectory(canonicalDest)
            print("installed \(target)")
            fflush(stdout)
            return replaced
        }

        // 5. Register and reload.
        if options.register {
            let status = IMEProcesses.register(bundle: URL(filePath: target, directoryHint: .isDirectory))
            if status == noErr {
                print("registered with Text Input Sources (enable Noema in System Settings > Keyboard > Input Sources)")
            } else {
                fputs("noema-cli install: TISRegisterInputSource returned \(status)\n", stderr)
            }
        }
        guard options.reload else { return }
        let after = IMEProcesses.running(canonicalExecutable: executable)
        let result = IMEProcesses.terminate(replacedProcesses + after)
        guard result.remaining.isEmpty else {
            do {
                try PendingReloadStore.save(result.remaining, canonicalBundle: target)
            } catch {
                fputs("noema-cli install: warning: \(error.message)\n", stderr)
            }
            throw CLIError("""
                installed \(target), but reload failed: signalled \(result.signalled), stopped \(result.stopped), \
                \(result.remaining.count) process(es) did not exit within 3 s (retry with noema-cli reload --bundle \(target))
                """)
        }
        PendingReloadStore.clear(canonicalBundle: target)
        print("reloaded: stopped \(result.stopped) NoemaIME process(es); macOS relaunches it on next use")
    }

    /// The installed bundle may be replaced only when it is a real directory holding a
    /// regular `Contents/Info.plist` with Noema's bundle identifier.
    static func ensureReplaceable(_ target: String) throws(CLIError) {
        switch FileKind.of(target) {
        case .missing: return
        case .directory: break
        default: throw CLIError("\(target) is not a directory; refusing to replace it")
        }
        guard hasNoemaInfoPlist(target) else {
            throw CLIError("\(target) is not a Noema input method (CFBundleIdentifier is not \(NoemaPaths.imeBundleID)); refusing to replace it")
        }
    }

    /// A regular `Contents/Info.plist` with Noema's bundle identifier.
    static func hasNoemaInfoPlist(_ app: String) -> Bool {
        let info = "\(app)/Contents/Info.plist"
        guard FileKind.of(info) == .regular, let plist = readPlist(info) else { return false }
        return plist["CFBundleIdentifier"] as? String == NoemaPaths.imeBundleID
    }

    static let oldPrefix = ".\(NoemaPaths.imeBundleName).old."
    static let stagingPrefix = ".\(NoemaPaths.imeBundleName).install-staging."

    /// Undoes what a killed install left in `canonicalDest` (called under its lock). If the
    /// target is missing, the newest `.old.*` backup that is a Noema bundle is renamed back;
    /// if that fails every backup stays. Processes still running from the remaining
    /// leftover bundles go to the `PendingReloadStore` (if that fails, every leftover stays);
    /// then every `.old.*` and `.install-staging.*` entry except `keepingStaging` is removed.
    static func recoverInterruptedInstalls(in canonicalDest: String, keepingStaging: String) throws(CLIError) {
        let target = "\(canonicalDest)/\(NoemaPaths.imeBundleName)"
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: canonicalDest)
        } catch {
            throw CLIError("cannot list \(canonicalDest): \(error.localizedDescription)")
        }
        let leftovers = entries
            .filter { ($0.hasPrefix(oldPrefix) || $0.hasPrefix(stagingPrefix)) && $0 != keepingStaging }
            .sorted()
        guard !leftovers.isEmpty else { return }
        try withTerminationSignalsBlocked { () throws(CLIError) in
            if FileKind.of(target) == .missing {
                var newest: (path: String, mtime: timespec)?
                for name in leftovers where name.hasPrefix(oldPrefix) {
                    let path = "\(canonicalDest)/\(name)"
                    var info = stat()
                    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, hasNoemaInfoPlist(path) else { continue }
                    let mtime = info.st_mtimespec
                    // Names are sorted, so on an equal mtime the later name wins.
                    if let current = newest?.mtime, (mtime.tv_sec, mtime.tv_nsec) < (current.tv_sec, current.tv_nsec) { continue }
                    newest = (path, mtime)
                }
                if let backup = newest?.path {
                    if rename(backup, target) != 0 {
                        let recoverErrno = errno
                        throw CLIError("""
                            cannot restore \(target) from the interrupted install's backup \(backup): \
                            \(String(cString: strerror(recoverErrno)))
                            """)
                    }
                    syncDirectory(canonicalDest)
                    fputs("noema-cli install: recovered \(target) from an interrupted install\n", stderr)
                }
            }
            // Their bundles are about to go: record what still runs from them first (a
            // SIGKILL right after the swap can leave a replaced bundle's processes here).
            let stranded = IMEProcesses.runningInLeftoverBundles(in: canonicalDest, excluding: keepingStaging)
            if !stranded.isEmpty {
                let pending = PendingReloadStore.load(canonicalBundle: target)
                do throws(CLIError) {
                    try PendingReloadStore.save(pending + stranded, canonicalBundle: target)
                } catch {
                    throw CLIError("""
                        cannot record the processes still running from an interrupted install's bundles, \
                        leftovers kept: \(error.message)
                        """)
                }
            }
            for name in leftovers {
                let path = "\(canonicalDest)/\(name)"
                guard FileKind.of(path) != .missing else { continue }
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    fputs("noema-cli install: warning: cannot remove leftover \(path): \(error.localizedDescription)\n", stderr)
                }
            }
            syncDirectory(canonicalDest)
        }
    }

    /// Runs `body` with `SIGINT`, `SIGTERM`, and `SIGHUP` blocked, so one that arrives
    /// mid-way stays pending until `body` has finished and is delivered then. Blocking the
    /// calling thread is enough: Dispatch worker threads (the only others here) block them.
    static func withTerminationSignalsBlocked<T>(_ body: () throws(CLIError) -> T) throws(CLIError) -> T {
        var mask = sigset_t()
        sigemptyset(&mask)
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] { sigaddset(&mask, signalNumber) }
        var previousMask = sigset_t()
        sigprocmask(SIG_BLOCK, &mask, &previousMask)
        defer { sigprocmask(SIG_SETMASK, &previousMask, nil) }
        return try body()
    }

    static func validateBundle(_ app: String) throws(CLIError) {
        let contents = "\(app)/Contents"
        let info = "\(contents)/Info.plist"
        guard FileKind.of(info) == .regular, let plist = readPlist(info) else {
            throw CLIError("bundle has no regular Contents/Info.plist")
        }
        let expected = [
            "CFBundleIdentifier": NoemaPaths.imeBundleID,
            "CFBundleExecutable": NoemaPaths.imeExecutableName,
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
        // The bundle and every piece of nested code it ships: an ad-hoc nested binary under
        // a certificate-signed bundle is still an ad-hoc install.
        let contents = "\(app)/Contents"
        let signed = [
            (app, "the bundle"),
            ("\(contents)/MacOS/\(NoemaPaths.imeExecutableName)", "Contents/MacOS/\(NoemaPaths.imeExecutableName)"),
            ("\(contents)/MacOS/noema-rime-deployer", "Contents/MacOS/noema-rime-deployer"),
            ("\(contents)/Frameworks/librime.1.dylib", "Contents/Frameworks/librime.1.dylib"),
        ]
        var isAdhoc = false
        for (path, name) in signed {
            let details = runTool("/usr/bin/codesign", ["-dvv", path])
            guard details.status == 0 else {
                throw CLIError("cannot read the code signature of \(name): \(details.stderr.trimmed)")
            }
            let lines = details.stderr.split(separator: "\n")
            let adhoc = lines.contains("Signature=adhoc")
            if !allowAdhoc && (adhoc || !lines.contains(where: { $0.hasPrefix("Authority=") })) {
                throw CLIError("""
                    \(name) is ad-hoc signed or has no signing authority. Sign the bundle with a \
                    certificate (scripts/build/bundle.sh --sign <SHA-1>), or pass --allow-adhoc to \
                    install an ad-hoc build for local development
                    """)
            }
            isAdhoc = isAdhoc || adhoc
        }
        if isAdhoc {
            fputs("noema-cli install: warning: installing an ad-hoc signed bundle (local development only)\n", stderr)
        }
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
