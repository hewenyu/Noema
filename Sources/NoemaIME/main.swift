// NoemaIME: the input method executable inside NoemaIME.app.
//
// A long option (`--version`, `--check-rime`, `--help`) is a headless probe answered
// before AppKit or IMKit is touched, so verify-bundle.sh can launch the binary; an unknown
// long option exits 2 at once. Anything else (no arguments, or the `-psn_*`/`-NS*`/`-Apple*`
// arguments launchd and Cocoa pass) starts the IMKit server: create the `IMKServer` first,
// then boot the Rime engine once the application has finished launching.
import AppKit
import Dispatch
import Foundation
import InputMethodKit
import NoemaCore
import NoemaEngine
import NoemaIMEShell

#if canImport(Darwin)
import Darwin
#endif

let usage = """
    usage: NoemaIME [option]

    Without an option, runs the input method server (launched by macOS).

    options:
      --version      print the NoemaIME version
      --check-rime   print the bundled librime version and required module status
      -h, --help     print this help
    """

/// The packaged CFBundleShortVersionString, or NoemaVersion.current when run unbundled.
func bundleVersion() -> String {
    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        return version
    }
    return NoemaVersion.current.description
}

func checkRime() -> Int32 {
    do {
        let info = try RimeRuntime.info()
        print("librime \(info.version)")
        for name in RimeRuntime.requiredModules {
            let ok = info.modules[name] ?? false
            print("  module \(name): \(ok ? "registered" : "MISSING")")
        }
        guard info.allModulesRegistered else {
            fputs("NoemaIME: required librime modules are missing\n", stderr)
            return 1
        }
        return 0
    } catch {
        fputs("NoemaIME: \(error)\n", stderr)
        return 1
    }
}

/// Boots the engine after launch and shuts it down on termination. `shutdown()` finishes a
/// cancelled boot's cleanup (deployer, staging, boot sentinel, lock) before it returns, so
/// AppKit termination (logout, `terminate(_:)`) mid-boot can answer `.terminateNow` and an
/// interrupted boot never counts toward `bootCrashLoop`.
@MainActor
final class InputMethodAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        EngineHost.shared.boot()
        // Off the hot path: connects on its own queue; typing never waits for the agent.
        EngineHost.shared.startAgentConnection()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        EngineHost.shared.shutdown()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Defense in depth: a no-op once applicationShouldTerminate has run.
        EngineHost.shared.shutdown()
    }
}

@MainActor
func runInputMethodServer() -> Never {
    let log = NoemaLog.ime("lifecycle")
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    // SIGTERM (`noema-cli reload`, logout) and SIGINT: release librime and the user-data
    // lock before exiting. The engine boots off the main actor, so this handler runs even
    // mid-deployment; shutdown() then stops the deployer subprocess before exit.
    var signalSources: [any DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            // Synchronous cleanup, bounded well under `noema-cli reload`'s 3 s wait.
            MainActor.assumeIsolated { EngineHost.shared.shutdown() }
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    let delegate = InputMethodAppDelegate()
    app.delegate = delegate

    // Registers the Objective-C class IMKit instantiates by name.
    _ = NoemaInputController.self
    guard let server = IMKServer(name: NoemaPaths.imeConnectionName, bundleIdentifier: NoemaPaths.imeBundleID) else {
        log.fault("IMKServer could not register its connection")
        exit(1)
    }
    log.info("IMKServer registered")

    app.run()
    // NSApplication.run returns only after stop(_:); keep everything alive until then.
    withExtendedLifetime((server, delegate, signalSources)) {}
    EngineHost.shared.shutdown()
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments {
case ["--version"]:
    print("NoemaIME \(bundleVersion())")
    exit(0)
case ["--check-rime"]:
    exit(checkRime())
case ["-h"], ["--help"]:
    print(usage)
    exit(0)
default:
    if arguments.contains(where: { $0.hasPrefix("--") }) {
        fputs(usage + "\n", stderr)
        exit(2)
    }
    runInputMethodServer()
}
