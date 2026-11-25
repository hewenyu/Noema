import Darwin
import Foundation
import NoemaCore

/// `noema-cli reload`: stop this user's running `NoemaIME` from one bundle, so macOS
/// relaunches the installed build on next use.
enum ReloadCommand {
    static let usage = """
        usage: noema-cli reload [--bundle <path>] [--register]

          --bundle <path>  installed bundle (default ~/Library/Input Methods/NoemaIME.app)
          --register       register the bundle with Text Input Sources first
                           (always done for the default bundle when it exists)

        Sends SIGTERM to this user's NoemaIME processes whose executable is
        <bundle>/Contents/MacOS/NoemaIME, and to those of a replaced copy that an
        earlier install left running, and waits up to 3 s for them to exit; exits 1
        if any is still running.
        """

    static func run(_ arguments: [String]) -> Int32 {
        if arguments == ["-h"] || arguments == ["--help"] {
            print(usage)
            return 0
        }
        var parser = OptionParser(command: "reload", arguments: arguments)
        let values: [String: String]
        let flags: Set<String>
        do {
            (values, flags) = try parser.parse(valued: ["--bundle"], flags: ["--register"])
        } catch {
            fputs("noema-cli reload: \(error.message)\n\(usage)\n", stderr)
            return error.status
        }
        let defaultBundle = NoemaPaths.installedIMEBundleURL()
        let bundle = values["--bundle"].map { absoluteURL($0) } ?? defaultBundle
        let bundlePath = bundle.fileSystemPath
        let isDefault = bundle.fileSystemPath == defaultBundle.fileSystemPath

        if flags.contains("--register") || (isDefault && FileKind.of(bundlePath) == .directory) {
            let status = IMEProcesses.register(bundle: bundle)
            if status == noErr {
                print("registered \(bundlePath)")
            } else {
                fputs("noema-cli reload: TISRegisterInputSource returned \(status)\n", stderr)
            }
        }

        // The same lock and ledger key as `install`: the canonical bundle and its parent.
        let canonicalBundle = IMEProcesses.canonicalPath(bundlePath) ?? bundlePath
        let parent = URL(filePath: canonicalBundle).deletingLastPathComponent().fileSystemPath
        let lock: Int32
        do {
            lock = try IMEProcesses.lockDirectory(IMEProcesses.canonicalPath(parent) ?? parent)
        } catch {
            fputs("noema-cli reload: \(error.message)\n", stderr)
            return error.status
        }
        defer { close(lock) }
        let executable = "\(canonicalBundle)/Contents/MacOS/\(NoemaPaths.imeExecutableName)"
        let canonical = IMEProcesses.canonicalPath(executable) ?? executable
        let pending = PendingReloadStore.load(canonicalBundle: canonicalBundle)
        let running = IMEProcesses.running(canonicalExecutable: canonical)
        let result = IMEProcesses.terminate(pending + running)
        guard result.remaining.isEmpty else {
            do {
                try PendingReloadStore.save(result.remaining, canonicalBundle: canonicalBundle)
            } catch {
                fputs("noema-cli reload: warning: \(error.message)\n", stderr)
            }
            print("reload: signalled \(result.signalled), stopped \(result.stopped) NoemaIME process(es)")
            fputs("noema-cli reload: \(result.remaining.count) process(es) did not exit within 3 s\n", stderr)
            return 1
        }
        PendingReloadStore.clear(canonicalBundle: canonicalBundle)
        print("reload: stopped \(result.stopped) NoemaIME process(es)")
        return 0
    }
}
