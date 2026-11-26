import Foundation
import NoemaCore
import NoemaIPC
import Observation
import os

/// Whether the agent is serving IPC.
public enum AgentListenerState: Sendable, Hashable {
    case idle
    /// Checked in to `NoemaPaths.agentMachServiceName` (or an anonymous listener in tests).
    case listening
    /// Started directly, not by launchd: the Mach service check-in was refused (EPERM).
    /// The agent stays up so Settings can register the LaunchAgent.
    case standbyNotLaunchdManaged
    case failed(String)
}

/// What the agent knows about its IME peers; metadata only.
public struct AgentServiceSnapshot: Sendable, Hashable {
    public var listenerState: AgentListenerState = .idle
    public var connectedPeers = 0
    public var lastPeerIdentity: PeerIdentity?
    public var lastHello: IMEHello?
    /// The IME's live engine mode: `hello`'s, then each `engineModeChanged` on that epoch.
    public var lastEngineMode: String?
    public var lastComposition: CompositionSnapshot?
    public var framesHandled = 0
    public var malformedFrames = 0
    public var rejectedPeers = 0
    /// Composition updates older than one already seen from the same peer.
    public var staleCompositionDrops = 0
    public var settings: AgentSettingsSnapshot = .defaults
    /// The latest progress the IME reported on a schema-set switch, on its current epoch.
    public var lastSchemaSwitchStatus: SchemaSetSwitchStatus?
    /// The switch `requestSchemaSetSwitch` sent last, and how many peers it reached.
    public var lastSchemaSwitchRequest: SchemaSetSwitchRequest?
    public var lastSchemaSwitchRecipients = 0

    public init() {}
}

/// The agent side of the IME connection. Owns an `IPCServerTransport`, answers `hello`
/// with `helloAck` and `heartbeat` with `heartbeatAck` (echoing the IME's epoch and
/// generation), records composition metadata and schema-switch progress, forwards
/// `openSettingsRequested`, and pushes settings, suggestions, and schema-set switches.
public final class AgentServiceCoordinator: @unchecked Sendable {
    private struct Peer {
        var epoch: UUID?
        var compositionWatermark: UInt64?
    }

    private struct State {
        var snapshot = AgentServiceSnapshot()
        var peers: [IPCPeerID: Peer] = [:]
        var sequence: UInt64 = 0
        var settingsRevision: UInt64 = 0
        var schemaSwitchGeneration: UInt64 = 0
    }

    public let agentVersion: String
    private let transport: any IPCServerTransport
    private let onOpenSettings: @Sendable (SettingsSectionID?) -> Void
    private let onChange: @Sendable (AgentServiceSnapshot) -> Void
    private let state: OSAllocatedUnfairLock<State>
    private let log = NoemaLog.agent("service")

    public init(
        transport: any IPCServerTransport,
        agentVersion: String,
        settings: AgentSettingsSnapshot = .defaults,
        onOpenSettings: @escaping @Sendable (SettingsSectionID?) -> Void = { _ in },
        onChange: @escaping @Sendable (AgentServiceSnapshot) -> Void = { _ in }
    ) {
        self.transport = transport
        self.agentVersion = agentVersion
        self.onOpenSettings = onOpenSettings
        self.onChange = onChange
        var initial = State()
        initial.snapshot.settings = settings
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    public var snapshot: AgentServiceSnapshot { state.withLock { $0.snapshot } }

    /// Starts the transport; a refused Mach check-in is standby, not failure.
    @discardableResult
    public func start() -> AgentListenerState {
        let handlers = IPCServerHandlers(
            onFrame: { [weak self] frame, peer, identity in self?.handle(frame, from: peer, identity: identity) },
            onEvent: { [weak self] event in self?.handle(event) })
        let listenerState: AgentListenerState
        do {
            try transport.start(handlers)
            listenerState = .listening
        } catch XPCListenerServerTransport.StartError.checkInFailed(_, permissionDenied: true) {
            listenerState = .standbyNotLaunchdManaged
        } catch {
            listenerState = .failed("\(error)")
        }
        log.info("listener state: \(String(describing: listenerState), privacy: .public)")
        update { $0.snapshot.listenerState = listenerState }
        return listenerState
    }

    public func stop() {
        transport.stop()
        update { state in
            state.peers = [:]
            state.snapshot.connectedPeers = 0
            if state.snapshot.listenerState == .listening { state.snapshot.listenerState = .idle }
        }
    }

    /// Replaces the settings, bumps the monotonic settings revision, and pushes a
    /// `settingsSnapshot` carrying it to every peer that said hello.
    public func updateSettings(_ settings: AgentSettingsSnapshot) {
        let pushes = update { state -> [(IPCPeerID, Data)] in
            state.snapshot.settings = settings
            state.settingsRevision += 1
            let revision = state.settingsRevision
            return state.peers.sorted(by: { $0.key < $1.key }).compactMap { peer, info in
                guard let epoch = info.epoch else { return nil }
                state.sequence += 1
                let envelope = IPCEnvelope(
                    sequence: state.sequence, message: AgentToIME.settingsSnapshot(sessionEpoch: epoch, settings: settings, revision: revision),
                    generationID: revision)
                return (try? IPCWireCodec.encode(envelope)).map { (peer, $0) }
            }
        }
        for (peer, frame) in pushes { try? transport.push(frame, to: peer) }
    }

    /// Pushes a suggestion to every peer on `epoch` (the AI pipeline's entry point).
    public func pushSuggestion(_ suggestion: AISuggestionMessage) {
        let pushes = update { state -> [(IPCPeerID, Data)] in
            state.peers.sorted(by: { $0.key < $1.key }).compactMap { peer, info in
                guard info.epoch == suggestion.sessionEpoch else { return nil }
                state.sequence += 1
                let envelope = IPCEnvelope(
                    sequence: state.sequence, message: AgentToIME.aiSuggestion(suggestion), generationID: suggestion.generationID)
                return (try? IPCWireCodec.encode(envelope)).map { (peer, $0) }
            }
        }
        for (peer, frame) in pushes { try? transport.push(frame, to: peer) }
    }

    /// Asks every peer that said hello to run `schemaSetID` (and `schemaID`), under a fresh
    /// request ID and the next monotonic switch generation, so the IME's gate drops a stale
    /// or repeated request. Returns the request ID the IME's `schemaSwitchStatus` names.
    @discardableResult
    public func requestSchemaSetSwitch(schemaSetID: SchemaSetID, schemaID: String? = nil) -> UUID {
        let request = SchemaSetSwitchRequest(schemaSetID: schemaSetID, schemaID: schemaID)
        let pushes = update { state -> [(IPCPeerID, Data)] in
            state.schemaSwitchGeneration += 1
            let generation = state.schemaSwitchGeneration
            let frames = state.peers.sorted(by: { $0.key < $1.key }).compactMap { peer, info -> (IPCPeerID, Data)? in
                guard let epoch = info.epoch else { return nil }
                state.sequence += 1
                let envelope = IPCEnvelope(
                    sequence: state.sequence, message: AgentToIME.switchSchemaSet(sessionEpoch: epoch, request: request),
                    generationID: generation)
                return (try? IPCWireCodec.encode(envelope)).map { (peer, $0) }
            }
            state.snapshot.lastSchemaSwitchRequest = request
            state.snapshot.lastSchemaSwitchRecipients = frames.count
            return frames
        }
        for (peer, frame) in pushes { try? transport.push(frame, to: peer) }
        log.info("schema-set switch to \(schemaSetID.rawValue, privacy: .public) sent to \(pushes.count, privacy: .public) peer(s)")
        return request.requestID
    }

    // MARK: - Transport callbacks

    func handle(_ frame: Data, from peer: IPCPeerID, identity: PeerIdentity?) -> Data? {
        let envelope: IPCEnvelope<IMEToAgent>
        do {
            envelope = try IPCWireCodec.decode(IMEToAgent.self, from: frame)
        } catch {
            update { $0.snapshot.malformedFrames += 1 }
            return nil
        }
        guard envelope.isConsistent else {
            update { $0.snapshot.malformedFrames += 1 }
            return nil
        }
        var openSection: SettingsSectionID??
        let reply = update { state -> AgentToIME? in
            state.snapshot.framesHandled += 1
            if let identity { state.snapshot.lastPeerIdentity = identity }
            var info = state.peers[peer] ?? Peer()
            defer { state.peers[peer] = info }
            switch envelope.payload {
            case .hello(let hello):
                info.epoch = hello.sessionEpoch
                info.compositionWatermark = nil
                state.snapshot.lastHello = hello
                state.snapshot.lastEngineMode = hello.engineMode
                return .helloAck(AgentHelloAck(
                    agentVersion: agentVersion, sessionEpoch: hello.sessionEpoch, settings: state.snapshot.settings,
                    settingsRevision: state.settingsRevision))
            case .heartbeat(let epoch):
                guard epoch == info.epoch else { return nil }
                return .heartbeatAck(sessionEpoch: epoch)
            case .compositionStateChanged(let snapshot):
                guard snapshot.sessionEpoch == info.epoch else { return nil }
                if let watermark = info.compositionWatermark, snapshot.generationID <= watermark {
                    state.snapshot.staleCompositionDrops += 1
                    return nil
                }
                info.compositionWatermark = snapshot.generationID
                state.snapshot.lastComposition = snapshot
                return nil
            case .openSettingsRequested(let section):
                openSection = .some(section)
                return nil
            case .engineModeChanged(let epoch, let mode):
                guard epoch == info.epoch else { return nil }
                state.snapshot.lastEngineMode = mode
                if state.snapshot.lastHello?.sessionEpoch == epoch { state.snapshot.lastHello?.engineMode = mode }
                return nil
            case .schemaSwitchStatus(let epoch, let status):
                guard epoch == info.epoch else { return nil }
                state.snapshot.lastSchemaSwitchStatus = status
                return nil
            }
        }
        if let section = openSection { onOpenSettings(section) }
        guard let reply else { return nil }
        let sequence = update { state -> UInt64 in
            state.sequence += 1
            return state.sequence
        }
        // Replies echo the request's generation, so the IME's gate can order them.
        return try? IPCWireCodec.encode(IPCEnvelope(sequence: sequence, message: reply, generationID: envelope.generationID))
    }

    func handle(_ event: IPCServerEvent) {
        update { state in
            switch event {
            case .peerConnected(let peer):
                state.peers[peer] = state.peers[peer] ?? Peer()
            case .peerDisconnected(let peer):
                state.peers.removeValue(forKey: peer)
            case .peerRejected:
                state.snapshot.rejectedPeers += 1
            }
            state.snapshot.connectedPeers = state.peers.count
        }
    }

    @discardableResult
    private func update<T>(_ body: (inout State) -> T) -> T {
        let (result, snapshot) = state.withLockUnchecked { state -> (T, AgentServiceSnapshot) in
            let result = body(&state)
            return (result, state.snapshot)
        }
        onChange(snapshot)
        return result
    }
}

/// The Settings window's view model, on the main actor.
@MainActor
@Observable
public final class AgentStatusModel {
    public var service = AgentServiceSnapshot()
    public var launchAgentStatus: LaunchAgentStatus = .notRegistered
    public var selectedSection: SettingsSectionID? = .general
    public var lastLaunchAgentError: String?
    /// The "词库" section's model; the agent sets it once its IPC service exists.
    public var lexicon: LexiconController?
    public let agentVersion: String
    @ObservationIgnored private let launchAgent: any LaunchAgentControlling

    public init(agentVersion: String, launchAgent: any LaunchAgentControlling) {
        self.agentVersion = agentVersion
        self.launchAgent = launchAgent
        launchAgentStatus = launchAgent.status
    }

    public func apply(_ snapshot: AgentServiceSnapshot) {
        if service != snapshot { service = snapshot }
    }

    public func refreshLaunchAgentStatus() {
        launchAgentStatus = launchAgent.status
    }

    /// Whether the agent starts at login: registered and enabled, or awaiting approval.
    public var isLaunchAgentRequested: Bool {
        launchAgentStatus == .enabled || launchAgentStatus == .requiresApproval
    }

    /// Registers or unregisters the LaunchAgent; a failure is kept in `lastLaunchAgentError`.
    public func setLaunchAgentEnabled(_ enabled: Bool) {
        do {
            if enabled { try launchAgent.register() } else { try launchAgent.unregister() }
            lastLaunchAgentError = nil
        } catch {
            lastLaunchAgentError = error.localizedDescription
        }
        refreshLaunchAgentStatus()
    }

    public func openLoginItems() {
        launchAgent.openSystemSettingsLoginItems()
    }
}
