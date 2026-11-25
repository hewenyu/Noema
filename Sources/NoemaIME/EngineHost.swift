import Foundation
import NoemaCore
import NoemaEngine
import NoemaIMEShell

/// Owns the one `RimeEngine` of the input method process and the coordinator every
/// `NoemaInputController` shares. Until the engine is ready, and after `shutdown()`, the
/// coordinator sees no engine and passes every key through.
@MainActor
final class EngineHost {
    enum State {
        case uninitialized
        /// `RimeEngine.start` is running; any deployment runs off the main actor.
        case booting(Task<Void, Never>, DeployCancellation)
        /// `shutdown()` cancelled the boot; the task is still removing staging and
        /// disarming the boot sentinel. Every later `shutdown()` returns the same task.
        case shuttingDown(Task<Void, Never>)
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

    /// Starts the engine on the user's Rime data and returns at once: `RimeEngine.start`
    /// deploys off the main actor, so IMKit keys keep passing through and SIGTERM keeps
    /// being served meanwhile. Never throws or traps: a failure leaves the host
    /// `.unavailable` (keys pass through), and Safe Mode is logged by reason.
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
        let configuration = RimeEngineConfiguration(sharedDataDir: sharedDataDir, userDataDir: userDataDir, logDir: logDir)
        let cancellation = DeployCancellation()
        let task = Task { @MainActor [weak self] in
            let outcome: Result<RimeEngine, NoemaError>
            do throws(NoemaError) {
                outcome = .success(try await RimeEngine.start(configuration: configuration, cancellation: cancellation))
            } catch {
                outcome = .failure(error)
            }
            self?.finishBoot(outcome)
        }
        state = .booting(task, cancellation)
    }

    private func finishBoot(_ outcome: Result<RimeEngine, NoemaError>) {
        switch state {
        case .booting:
            break
        case .shuttingDown:
            // shutdown() ran while booting: never publish an engine.
            if case .success(let engine) = outcome { engine.shutdown() }
            state = .unavailable("shut down")
            return
        case .uninitialized, .ready, .unavailable:
            if case .success(let engine) = outcome { engine.shutdown() }
            return
        }
        switch outcome {
        case .success(let engine):
            state = .ready(engine)
            if let reason = engine.safeModeReason {
                log.error("RimeEngine is in Safe Mode: \(reason.rawValue, privacy: .public)")
            } else {
                log.info("RimeEngine ready")
            }
        case .failure(let error):
            state = .unavailable(String(describing: error))
            log.fault("RimeEngine unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Finalizes librime and releases the user-data lock; while booting, cancels the boot
    /// and stops a running `noema-rime-deployer` before returning (SIGTERM, SIGKILL after
    /// `deployerGrace`), so exiting right after leaves no orphan. Returns the cancelled
    /// boot task while it is still cleaning up — also to every later call, so SIGTERM during
    /// an AppKit `.terminateLater` awaits the same task — so the caller can await its
    /// staging/sentinel cleanup before exiting (`BootTerminationCoordinator`). Idempotent.
    @discardableResult
    func shutdown(deployerGrace: Duration = .milliseconds(500)) -> Task<Void, Never>? {
        switch state {
        case .unavailable:
            return nil
        case .shuttingDown(let task):
            return task
        case .uninitialized:
            state = .unavailable("shut down")
            log.info("RimeEngine shut down")
            return nil
        case .booting(let task, let cancellation):
            cancellation.cancelTerminatingDeployer(grace: deployerGrace)
            task.cancel()
            state = .shuttingDown(task)
            log.info("RimeEngine boot cancelled; awaiting cleanup")
            return task
        case .ready(let engine):
            engine.shutdown()
            state = .unavailable("shut down")
            log.info("RimeEngine shut down")
            return nil
        }
    }
}
