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
        case .uninitialized, .ready, .unavailable:
            // shutdown() ran while booting: never publish an engine.
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

    /// Finalizes librime and releases the user-data lock. While booting, cleans the boot up
    /// before returning, synchronously on this main-actor stack
    /// (`DeployCancellation.cancelAndFinishCleanup`): the deployer is stopped (SIGTERM, SIGKILL
    /// after `deployerGrace`), its staging directory removed, the boot sentinel disarmed, and
    /// the lock and the claim released — also when called inside a `DispatchQueue.main` block
    /// (AppKit `terminate(_:)`, a signal source), where no main-actor continuation could run
    /// before the process exits. Idempotent.
    func shutdown(deployerGrace: Duration = .milliseconds(500)) {
        switch state {
        case .unavailable:
            return
        case .uninitialized:
            state = .unavailable("shut down")
            log.info("RimeEngine shut down")
        case .booting(let task, let cancellation):
            cancellation.cancelAndFinishCleanup(deployerGrace: deployerGrace)
            task.cancel()
            state = .unavailable("shut down")
            log.info("RimeEngine boot cancelled and cleaned up")
        case .ready(let engine):
            engine.shutdown()
            state = .unavailable("shut down")
            log.info("RimeEngine shut down")
        }
    }
}
