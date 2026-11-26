import Carbon.HIToolbox
import Foundation
import NoemaCore
import NoemaEngine
import NoemaIMEShell
import NoemaIPC
import NoemaUI

/// Owns the one `RimeEngine` of the input method process, the coordinator every
/// `NoemaInputController` shares, and the agent connection. Until the engine is ready, and
/// after `shutdown()`, the coordinator sees no engine and passes every key through.
///
/// The agent connection never affects typing: `RimeEngine` runs here on the main actor,
/// composition changes leave through `CompositionIPCReporter` (fire-and-forget, nothing
/// under secure input), and a dead or unreachable agent only moves `IPCConnectionManager`
/// through `degraded`, `reconnecting`, and `circuitOpen`.
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

    /// Created with `coordinator`, the first time IMKit calls a controller: never by
    /// `--version`, `--check-rime`, or a `shutdown()` before any client.
    private var candidatePanel: CandidatePanelController?

    private(set) lazy var coordinator: InputSessionCoordinator = {
        let panel = CandidatePanelController()
        let coordinator = InputSessionCoordinator(
            engineProvider: { [unowned self] in
                if case .ready(let engine) = self.state { return engine }
                return nil
            },
            candidatePresenter: panel,
            inlinePreeditDisabledBundleIDs: Self.inlinePreeditDisabledBundleIDs())
        panel.onSelectCandidate = { [weak coordinator] index, generation in
            coordinator?.selectCandidate(at: index, expectedGenerationID: generation)
        }
        panel.onChangePage = { [weak coordinator] backward, generation in
            coordinator?.changePage(backward: backward, expectedGenerationID: generation)
        }
        candidatePanel = panel
        coordinator.onCompositionChange = { [unowned self] state in self.reporter?.report(state) }
        return coordinator
    }()

    /// The agent connection, started by `startAgentConnection()` after launch.
    private(set) var ipc: IPCConnectionManager?
    private var reporter: CompositionIPCReporter?

    private init() {}

    /// Client bundle IDs that get no marked text (the panel draws the preedit), from
    /// `defaults write <imeBundleID> InlinePreeditDisabledBundleIDs -array <bundle-id>...`.
    static let inlinePreeditDisabledKey = "InlinePreeditDisabledBundleIDs"

    private static func inlinePreeditDisabledBundleIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: inlinePreeditDisabledKey) ?? [])
    }

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
            ipc?.setEngineMode(engine.safeModeReason == nil ? "rime" : "safeMode")
            if let reason = engine.safeModeReason {
                log.error("RimeEngine is in Safe Mode: \(reason.rawValue, privacy: .public)")
            } else {
                log.info("RimeEngine ready")
            }
        case .failure(let error):
            state = .unavailable(String(describing: error))
            ipc?.setEngineMode("unavailable")
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
        candidatePanel?.hide()
        stopAgentConnection()
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

    // MARK: - Agent connection

    /// Connects to `NoemaAgent` off the main actor and returns at once. Idempotent; a no-op
    /// after `shutdown()`.
    func startAgentConnection() {
        guard ipc == nil else { return }
        if case .unavailable("shut down") = state { return }
        let queue = DispatchQueue(label: "dev.noema.ipc.connection", qos: .utility)
        let policy = PeerIdentityPolicy.resolved(
            requested: .allowAdHocForTesting(signingIdentifiers: [NoemaPaths.agentBundleID]),
            selfIdentity: SelfCodeIdentity.current())
        let transport = XPCClientTransport(machService: NoemaPaths.agentMachServiceName, policy: policy, queue: queue)
        let manager = IPCConnectionManager(
            transport: transport,
            client: .init(bundleID: NoemaPaths.imeBundleID, version: Self.clientVersion()),
            queue: queue, isSecureInputEnabled: { IsSecureEventInputEnabled() })
        attachAgentConnection(manager, isSecureInputEnabled: { IsSecureEventInputEnabled() })
        manager.start()
    }

    /// Wires `manager` to the coordinator's composition changes. The seam tests use to
    /// attach a manager on a test transport.
    func attachAgentConnection(_ manager: IPCConnectionManager, isSecureInputEnabled: @escaping @MainActor () -> Bool) {
        ipc = manager
        reporter = CompositionIPCReporter(manager: manager, isSecureInputEnabled: isSecureInputEnabled)
        switch state {
        case .ready(let engine): manager.setEngineMode(engine.safeModeReason == nil ? "rime" : "safeMode")
        case .unavailable: manager.setEngineMode("unavailable")
        case .uninitialized, .booting: manager.setEngineMode("booting")
        }
    }

    /// Disconnects from the agent and cancels every XPC session before returning.
    func stopAgentConnection() {
        ipc?.stop()
        ipc = nil
        reporter = nil
    }

    private static func clientVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? NoemaVersion.current.description
    }
}
