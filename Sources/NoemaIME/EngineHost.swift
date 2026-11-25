import Foundation
import NoemaCore
import NoemaEngine
import NoemaIMEShell

/// Owns the one `RimeEngine` of the input method process and the coordinator every
/// `NoemaInputController` shares. Until `boot()` succeeds, and after `shutdown()`, the
/// coordinator sees no engine and passes every key through.
@MainActor
final class EngineHost {
    enum State {
        case uninitialized
        case ready(RimeEngine)
        case unavailable(String)
    }

    static let shared = EngineHost()

    private(set) var state: State = .uninitialized
    private let log = NoemaLog.ime("lifecycle")

    private(set) lazy var coordinator = InputSessionCoordinator(engineProvider: { [unowned self] in
        if case .ready(let engine) = self.state { return engine }
        return nil
    })

    private init() {}

    /// Starts the engine on the user's Rime data. Never throws or traps: a failure leaves
    /// the host `.unavailable` (keys pass through), and Safe Mode is logged by reason.
    /// Runs on the main actor; a needed deployment blocks it for up to the deploy timeout.
    func boot() {
        guard case .uninitialized = state else { return }
        let userDataDir = NoemaPaths.rimeUserDataDir()
        let logDir = NoemaPaths.logDir()
        do {
            try FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        } catch {
            // RimeEngine enters Safe Mode (userDataDirUnwritable) on the same failure.
            log.error("cannot create the Rime user or log directory")
        }
        guard let sharedDataDir = NoemaPaths.resolveSharedDataDir(bundle: .main) else {
            state = .unavailable("no bundled rime-default")
            log.fault("no bundled rime-default directory; every key passes through")
            return
        }
        do {
            let engine = try RimeEngine(configuration: RimeEngineConfiguration(
                sharedDataDir: sharedDataDir, userDataDir: userDataDir, logDir: logDir))
            state = .ready(engine)
            if let reason = engine.safeModeReason {
                log.error("RimeEngine is in Safe Mode: \(reason.rawValue, privacy: .public)")
            } else {
                log.info("RimeEngine ready")
            }
        } catch {
            state = .unavailable(String(describing: error))
            log.fault("RimeEngine unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Finalizes librime and releases the user-data lock. Idempotent.
    func shutdown() {
        if case .ready(let engine) = state { engine.shutdown() }
        if case .unavailable = state { return }
        state = .unavailable("shut down")
        log.info("RimeEngine shut down")
    }
}
