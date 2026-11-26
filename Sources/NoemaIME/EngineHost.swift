import Carbon.HIToolbox
import Foundation
import NoemaCore
import NoemaEngine
import NoemaIMEShell
import NoemaIPC
import NoemaLearning
import NoemaUI

/// Owns the one `RimeEngine` of the input method process, the coordinator every
/// `NoemaInputController` shares, and the agent connection. Until the engine is ready, and
/// after `shutdown()`, the coordinator sees no engine and passes every key through.
///
/// The agent connection never affects typing: `RimeEngine` runs here on the main actor,
/// composition changes leave through `CompositionIPCReporter` (fire-and-forget, nothing
/// under secure input), and a dead or unreachable agent only moves `IPCConnectionManager`
/// through `degraded`, `reconnecting`, and `circuitOpen`.
///
/// Learning: once the engine is ready (not Safe Mode, so this process holds the root lock),
/// `learning.sqlite` is opened read-write off the main actor and every Han commit is queued
/// to a `LearningStoreWriter` (never under secure input). Schema sets: the engine boots the
/// set in `active-schema-set.json` (built-in when absent or not installed), and the agent's
/// `switchSchemaSet` runs through `SchemaSetSwitcher`, which never interrupts a composition;
/// each phase goes back to the agent as `schemaSwitchStatus`.
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
            vModePresenter: panel,
            inlinePreeditDisabledBundleIDs: Self.inlinePreeditDisabledBundleIDs())
        panel.onSelectCandidate = { [weak coordinator] index, generation in
            coordinator?.selectCandidate(at: index, expectedGenerationID: generation)
        }
        panel.onChangePage = { [weak coordinator] backward, generation in
            coordinator?.changePage(backward: backward, expectedGenerationID: generation)
        }
        panel.onSelectVModeItem = { [weak coordinator] index, generation in
            coordinator?.selectVModeItem(at: index, expectedGenerationID: generation)
        }
        candidatePanel = panel
        coordinator.onCompositionChange = { [unowned self] state in
            self.reporter?.report(state)
            self.switcher?.compositionDidChange(state)
        }
        // A v-mode agent cell (`v2` … `v9`): fire-and-forget, nothing under secure input.
        coordinator.onQuickAction = { [unowned self] action in
            self.reporter?.requestQuickAction(action)
        }
        return coordinator
    }()

    /// The agent connection, started by `startAgentConnection()` after launch.
    private(set) var ipc: IPCConnectionManager?
    private var reporter: CompositionIPCReporter?

    /// The canonical learning store and its writer; nil until the engine is ready.
    private(set) var learningStore: LearningStore?
    private(set) var learningWriter: LearningStoreWriter?
    /// Runs agent-requested schema-set switches; nil until the engine is ready.
    private(set) var switcher: SchemaSetSwitcher?
    private var rootDir = NoemaPaths.rimeUserDataDir()
    private var builtinSharedDataDir: URL?
    private var luaFile: URL?
    private var logDir = NoemaPaths.logDir()
    /// Set once a boot of a non-built-in set fell back to the built-in one.
    private var triedBuiltinFallback = false
    /// The agent's emoji candidate setting, applied to every engine that becomes ready.
    private(set) var emojiCandidatesEnabled = AgentSettingsSnapshot.defaults.emojiCandidatesEnabled

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
    ///
    /// A non-built-in set from `active-schema-set.json` that fails to boot (an error,
    /// `engineInitFailed`, or `bootCrashLoop`) falls back once to the built-in set, recorded
    /// as active, so a broken external pack never strands the user in Safe Mode with no
    /// engine to switch from. A crash loop's sentinel is cleared for that one attempt; the
    /// built-in record keeps a crash of the built-in set itself from looping.
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
        rootDir = userDataDir
        builtinSharedDataDir = sharedDataDir
        self.logDir = logDir
        luaFile = NoemaPaths.resolveLearnedLua(bundle: .main)
        if luaFile == nil { log.error("no bundled noema_learned.lua; learned phrases reach Rime only through userdbs") }
        let configuration = RimeEngineConfiguration.activeSchemaSet(
            root: userDataDir, builtinSharedDataDir: sharedDataDir, logDir: logDir, luaFile: luaFile,
            openccDataDir: RimeEngineConfiguration.bundledOpenCCDataDir())
        if configuration.openccDataDir == nil { log.error("no bundled opencc data; standard OpenCC configs such as s2t.json may not load") }
        startBoot(configuration)
    }

    private func startBoot(_ configuration: RimeEngineConfiguration) {
        log.info("booting schema set \(configuration.schemaSetID?.rawValue ?? "-", privacy: .public)")
        let cancellation = DeployCancellation()
        let task = Task { @MainActor [weak self] in
            let outcome: Result<RimeEngine, NoemaError>
            do throws(NoemaError) {
                outcome = .success(try await RimeEngine.start(configuration: configuration, cancellation: cancellation))
            } catch {
                outcome = .failure(error)
            }
            self?.finishBoot(outcome, configuration: configuration)
        }
        state = .booting(task, cancellation)
    }

    private func finishBoot(_ outcome: Result<RimeEngine, NoemaError>, configuration: RimeEngineConfiguration) {
        switch state {
        case .booting:
            break
        case .uninitialized, .ready, .unavailable:
            // shutdown() ran while booting: never publish an engine.
            if case .success(let engine) = outcome { engine.shutdown() }
            return
        }
        if fallBackToBuiltin(after: outcome, configuration: configuration) { return }
        switch outcome {
        case .success(let engine):
            state = .ready(engine)
            ipc?.setEngineMode(engine.safeModeReason == nil ? "rime" : "safeMode")
            if let reason = engine.safeModeReason {
                log.error("RimeEngine is in Safe Mode: \(reason.rawValue, privacy: .public)")
            } else {
                log.info("RimeEngine ready")
                engine.setOption(Self.emojiOptionName, enabled: emojiCandidatesEnabled)
                attachLearning(to: engine)
            }
        case .failure(let error):
            state = .unavailable(String(describing: error))
            ipc?.setEngineMode("unavailable")
            log.fault("RimeEngine unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Starts the one fallback boot of the built-in set when `configuration` named another
    /// set and its boot failed in a way the built-in set may not share. Root-wide failures
    /// (the lock is held elsewhere, the directory is unwritable, the sentinel is corrupt)
    /// would fail the same way and are left alone.
    private func fallBackToBuiltin(after outcome: Result<RimeEngine, NoemaError>, configuration: RimeEngineConfiguration) -> Bool {
        guard !triedBuiltinFallback, let set = configuration.schemaSetID, set != .builtin,
              let builtinSharedDataDir
        else { return false }
        let clearSentinel: Bool
        switch outcome {
        case .failure: clearSentinel = false
        case .success(let engine):
            switch engine.safeModeReason {
            case .engineInitFailed?, .bootCrashLoop?: clearSentinel = true
            default: return false
            }
            engine.shutdown()
        }
        triedBuiltinFallback = true
        log.error("schema set \(set.rawValue, privacy: .public) failed to boot; falling back to the built-in set")
        var savedBuiltin = false
        do {
            try ActiveSchemaSetRecord(schemaSetID: .builtin, schemaID: SchemaSetID.builtin.defaultSchemaID)
                .save(to: NoemaPaths.activeSchemaSetURL(root: rootDir))
            savedBuiltin = true
        } catch {
            log.error("cannot record the built-in set as active: \(String(describing: error), privacy: .public)")
        }
        // Clear the sentinel only after `builtin` is persisted as active, so a failed save
        // cannot loop across processes while a prior interrupted boot + broken external pack
        // never strands the built-in fallback in `bootCrashLoop`.
        if clearSentinel && savedBuiltin {
            let guardian = BootGuard(userDataDir: rootDir, threshold: configuration.bootFailureThreshold)
            if guardian.acquireLock() == .acquired { guardian.clear() }
            guardian.releaseLock()
        }
        startBoot(RimeEngineConfiguration(
            sharedDataDir: builtinSharedDataDir, userDataDir: rootDir, logDir: logDir,
            schemaID: SchemaSetID.builtin.defaultSchemaID, deployerURL: configuration.deployerURL,
            schemaSetID: .builtin, luaFile: luaFile, openccDataDir: configuration.openccDataDir))
        return true
    }

    /// Finalizes librime and releases the user-data lock. While booting, cleans the boot up
    /// before returning, synchronously on this main-actor stack
    /// (`DeployCancellation.cancelAndFinishCleanup`): the deployer is stopped (SIGTERM, SIGKILL
    /// after `deployerGrace`), its staging directory removed, the boot sentinel disarmed, and
    /// the lock and the claim released — also when called inside a `DispatchQueue.main` block
    /// (AppKit `terminate(_:)`, a signal source), where no main-actor continuation could run
    /// before the process exits. Idempotent.
    func shutdown(deployerGrace: Duration = .milliseconds(500)) {
        candidatePanel?.hideAll()
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
            // A running switch first (its deployer and staging), then every queued commit,
            // and only then librime and the lock.
            switcher?.shutdown(deployerGrace: deployerGrace)
            learningWriter?.flush()
            engine.recordCommits(to: nil)
            engine.shutdown()
            learningStore?.close()
            state = .unavailable("shut down")
            log.info("RimeEngine shut down")
        }
        switcher = nil
        learningWriter = nil
        learningStore = nil
    }

    // MARK: - Learning and schema sets

    /// Builds the switcher at once, then opens `learning.sqlite` read-write off the main actor
    /// and, if the engine is still the ready one, records commits and exports the
    /// learned-phrase snapshot for `noema_learned.lua`.
    private func attachLearning(to engine: RimeEngine) {
        guard let builtinSharedDataDir else { return }
        let switcher = SchemaSetSwitcher(
            root: rootDir, builtinSharedDataDir: builtinSharedDataDir, luaFile: luaFile,
            engineProvider: { [weak self] in
                guard let self, case .ready(let engine) = self.state else { return nil }
                return engine
            })
        switcher.onEvent = { [weak self] event in
            self?.ipc?.reportSchemaSwitch(SchemaSetSwitchStatus(
                requestID: event.requestID, schemaSetID: event.schemaSetID, phase: event.phase, detail: event.detail))
        }
        self.switcher = switcher
        let storeURL = NoemaPaths.learningStoreURL(root: rootDir)
        let tsv = engine.configuration.rimeUserDataDir.appending(path: NoemaPaths.learnedTSVFileName)
        Task { @MainActor [weak self] in
            let store = await Task.detached(priority: .utility) { () -> LearningStore? in
                guard let store = try? LearningStore(url: storeURL) else { return nil }
                _ = try? LearnedSnapshotExporter.export(from: store, to: tsv)
                return store
            }.value
            guard let self, case .ready(let current) = self.state, current === engine, let store else {
                store?.close()
                return
            }
            let writer = LearningStoreWriter(store: store)
            self.learningStore = store
            self.learningWriter = writer
            switcher.learningStore = store
            switcher.learningWriter = writer
            engine.recordCommits(to: writer, isSecureInputEnabled: { IsSecureEventInputEnabled() })
            self.log.info("learning store attached")
        }
    }

    /// An agent's `switchSchemaSet`, on the main actor.
    func handleSchemaSwitchRequest(_ request: SchemaSetSwitchRequest) {
        let switchRequest = SchemaSetSwitcher.Request(
            requestID: request.requestID, schemaSetID: request.schemaSetID, schemaID: request.schemaID)
        guard let switcher else {
            ipc?.reportSchemaSwitch(SchemaSetSwitchStatus(
                requestID: request.requestID, schemaSetID: request.schemaSetID, phase: .failed,
                detail: "the engine is not ready"))
            return
        }
        switcher.request(switchRequest)
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
        // Called on the manager's queue for every message the gate admitted (epoch and
        // generation checked); a switch hops to the main queue, never blocking the manager's.
        // `DispatchQueue.main` keeps the requests in arrival order (one Task each would not).
        manager.setMessageHandler { [weak self, weak manager] message in
            switch message {
            case .switchSchemaSet(_, let request):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handleSchemaSwitchRequest(request) }
                }
            case .helloAck, .settingsSnapshot:
                // The settings the manager applied (a stale revision never reaches here, and
                // an ack overtaken by a newer snapshot keeps the newer settings).
                guard let settings = manager?.agentSettings else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.applyAgentSettings(settings) }
                }
            case .heartbeatAck, .aiSuggestion:
                break
            }
        }
        switch state {
        case .ready(let engine): manager.setEngineMode(engine.safeModeReason == nil ? "rime" : "safeMode")
        case .unavailable: manager.setEngineMode("unavailable")
        case .uninitialized, .booting: manager.setEngineMode("booting")
        }
    }

    /// The librime option behind `AgentSettingsSnapshot.emojiCandidatesEnabled`.
    static let emojiOptionName = "emoji_suggestion"

    /// Applies the agent's settings that the IME honors: emoji candidates, on the ready
    /// engine now and on every later one. When an option flip changes an active composition,
    /// refreshes the coordinator's presentation so the panel and `generationID` stay in sync
    /// with librime's candidate list.
    func applyAgentSettings(_ settings: AgentSettingsSnapshot) {
        emojiCandidatesEnabled = settings.emojiCandidatesEnabled
        if case .ready(let engine) = state {
            let before = engine.currentState
            let after = engine.setOption(Self.emojiOptionName, enabled: settings.emojiCandidatesEnabled)
            if candidatePanel != nil, after.generationID != before.generationID, before.isComposing || after.isComposing {
                coordinator.refreshPresentation()
            }
        }
    }

    /// Disconnects from the agent and cancels every XPC session before returning.
    func stopAgentConnection() {
        ipc?.setMessageHandler(nil)
        ipc?.stop()
        ipc = nil
        reporter = nil
    }

    private static func clientVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? NoemaVersion.current.description
    }
}
