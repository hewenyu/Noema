import Dispatch
import Foundation
import NoemaAgentCore
import NoemaCore
@testable import NoemaIPC
import notify
import os
import Testing
import XPC

/// The endpoint the client dials, swapped when the "agent" restarts.
final class EndpointBox: Sendable {
    private let endpoint = OSAllocatedUnfairLock<XPCEndpoint?>(initialState: nil)
    func set(_ value: XPCEndpoint?) { endpoint.withLock { $0 = value } }
    func get() -> XPCEndpoint? { endpoint.withLock { $0 } }
}

/// Real libxpc end to end: an anonymous `XPCListener` serving the real
/// `AgentServiceCoordinator`, and `XPCClientTransport` + `IPCConnectionManager` dialing its
/// endpoint, with peer requirements and per-message `SecCodeCreateWithXPCMessage` checks
/// on both sides. No launchd registration is needed.
final class XPCRig {
    let serverPolicy: PeerIdentityPolicy
    let clientPolicy: PeerIdentityPolicy
    private(set) var server: XPCListenerServerTransport
    private(set) var agent: AgentServiceCoordinator
    let endpoint = EndpointBox()
    let queue = DispatchQueue(label: "dev.noema.tests.ipc")
    let manager: IPCConnectionManager
    let recorder = StateRecorder()

    init(
        reconnect: IPCReconnectPolicy = .init(
            baseDelay: .milliseconds(20), maxDelay: .milliseconds(200), jitterFraction: 0, circuitBreakerThreshold: 3,
            circuitCooldown: .seconds(60), handshakeTimeout: .seconds(2), heartbeatInterval: nil),
        readyNotificationName: String? = nil,
        serverPolicy: PeerIdentityPolicy? = nil,
        clientPolicy: PeerIdentityPolicy? = nil
    ) throws {
        let policy = try PeerIdentityPolicy.selfTest()
        self.serverPolicy = serverPolicy ?? policy
        self.clientPolicy = clientPolicy ?? policy
        (server, agent) = try Self.makeAgent(policy: self.serverPolicy)
        endpoint.set(server.endpoint)
        let box = endpoint
        let transport = XPCClientTransport(policy: self.clientPolicy, queue: queue) { box.get().map { .endpoint($0) } }
        manager = IPCConnectionManager(
            transport: transport, client: .init(bundleID: "dev.noema.tests.ime", version: "1.0.0"), policy: reconnect,
            clock: SystemIPCClock(), jitter: FixedJitter(fraction: 0), readyNotificationName: readyNotificationName, queue: queue)
        recorder.attach(to: manager)
    }

    static func makeAgent(policy: PeerIdentityPolicy) throws -> (XPCListenerServerTransport, AgentServiceCoordinator) {
        let server = XPCListenerServerTransport(mode: .anonymous, policy: policy)
        let agent = AgentServiceCoordinator(transport: server, agentVersion: "1.0.0-test")
        try #require(agent.start() == .listening)
        try #require(server.endpoint != nil)
        return (server, agent)
    }

    /// A fresh listener at a new endpoint, like a restarted agent.
    func restartAgent() throws {
        agent.stop()
        (server, agent) = try Self.makeAgent(policy: serverPolicy)
        endpoint.set(server.endpoint)
    }

    func shutdown() {
        manager.stop()
        agent.stop()
    }
}

@Suite(.serialized) struct XPCTransportTests {
    @Test func realRoundTripWithPeerVerificationAndServerPush() throws {
        let rig = try XPCRig(reconnect: .init(
            baseDelay: .milliseconds(20), circuitBreakerThreshold: 3, handshakeTimeout: .seconds(2),
            heartbeatInterval: .milliseconds(100)))
        defer { rig.shutdown() }
        rig.manager.start()
        #expect(waitUntil { rig.manager.state == .healthy }, "state: \(rig.manager.state)")

        // The agent verified this very process from the message's audit token.
        let me = try #require(SelfCodeIdentity.current())
        let snapshot = rig.agent.snapshot
        #expect(snapshot.lastPeerIdentity == me)
        #expect(snapshot.connectedPeers == 1)
        #expect(snapshot.lastHello?.sessionEpoch == rig.manager.sessionEpoch)

        // Server push (settingsSnapshot), verified by the client as well.
        let updated = AgentSettingsSnapshot(inlinePreeditDisabledBundleIDs: ["com.example.terminal"], panelBackdropPreference: "visualEffect", aiSuggestionsEnabled: true)
        rig.agent.updateSettings(updated)
        #expect(waitUntil { rig.manager.agentSettings == updated })

        // Fire-and-forget composition metadata.
        rig.manager.sendFireAndForget(.compositionStateChanged(
            CompositionSnapshot(sessionEpoch: UUID(), generationID: 42, isComposing: true, candidateCount: 5, isASCIIMode: false)))
        #expect(waitUntil { rig.agent.snapshot.lastComposition?.generationID == 42 })
        #expect(rig.agent.snapshot.lastComposition?.sessionEpoch == rig.manager.sessionEpoch)

        // An AI suggestion for the current composition reaches the handler; a stale one does not.
        for generation: UInt64 in [41, 42] {
            rig.agent.pushSuggestion(AISuggestionMessage(
                sessionEpoch: rig.manager.sessionEpoch, generationID: generation, suggestion: "g\(generation)", provider: "test"))
        }
        #expect(waitUntil {
            rig.recorder.received.contains { if case .aiSuggestion(let s) = $0 { s.generationID == 42 } else { false } }
        })
        #expect(!rig.recorder.received.contains { if case .aiSuggestion(let s) = $0 { s.generationID == 41 } else { false } })

        // Heartbeats keep flowing over request/reply.
        #expect(waitUntil { rig.recorder.received.filter { if case .heartbeatAck = $0 { true } else { false } }.count >= 2 })
        #expect(rig.manager.state == .healthy)
    }

    /// Cancelling the listener (the agent dying) drives the client through degraded,
    /// reconnecting, and an open circuit; a fresh listener plus the ready notification
    /// recovers it.
    @Test func serverCancelDegradesAndAReadySignalRecovers() throws {
        let name = "dev.noema.tests.ready.\(UUID().uuidString)"
        let rig = try XPCRig(readyNotificationName: name)
        defer { rig.shutdown() }
        rig.manager.start()
        #expect(waitUntil { rig.manager.state == .healthy })

        rig.agent.stop()
        #expect(waitUntil { if case .circuitOpen = rig.manager.state { true } else { false } }, "state: \(rig.manager.state)")
        let shape = rig.recorder.shape
        #expect(shape.prefix(4) == ["connecting(1)", "healthy", "degraded(directASCII)", "reconnecting(1)"], "\(shape)")
        #expect(shape.last == "circuitOpen(3)", "\(shape)")
        // A dead endpoint makes libxpc both throw and call the cancellation handler.
        #expect(rig.manager.statistics.ignoredStaleCallbacks >= 1)

        try rig.restartAgent()
        #expect(notify_post(name) == UInt32(NOTIFY_STATUS_OK))
        #expect(waitUntil { rig.manager.state == .healthy }, "state: \(rig.manager.state)")
        #expect(rig.agent.snapshot.connectedPeers == 1)
    }

    /// Layer 1 on the client: libxpc checks the agent's identity when its reply arrives, so
    /// an agent with another signing identifier gets the (metadata-only) hello but the
    /// client accepts nothing from it and never becomes healthy.
    @Test func clientRefusesAnAgentWithTheWrongIdentity() throws {
        var wrong = try PeerIdentityPolicy.selfTest()
        wrong.expectedSigningIdentifiers = ["dev.noema.not-the-agent"]
        let rig = try XPCRig(clientPolicy: wrong)
        defer { rig.shutdown() }
        rig.manager.start()
        #expect(waitUntil { rig.recorder.shape.contains("degraded(peerRejected)") }, "\(rig.recorder.shape)")
        #expect(!rig.recorder.shape.contains("healthy"))
        #expect(rig.recorder.received.isEmpty, "nothing from the impostor reached the handler")
        #expect(rig.manager.agentSettings == nil)
    }

    /// Layer 1 on the server: accepted peer sessions carry the requirement too.
    @Test func serverRefusesAClientWithTheWrongIdentity() throws {
        var wrong = try PeerIdentityPolicy.selfTest()
        wrong.expectedSigningIdentifiers = ["dev.noema.not-the-ime"]
        let rig = try XPCRig(serverPolicy: wrong)
        defer { rig.shutdown() }
        rig.manager.start()
        #expect(waitUntil { rig.recorder.shape.contains("reconnecting(1)") }, "\(rig.recorder.shape)")
        #expect(!rig.recorder.shape.contains("healthy"))
        #expect(rig.agent.snapshot.lastHello == nil)
    }

    /// Strict mode end to end: a certificate pin (no Team ID) accepted per message.
    @Test func strictCertificatePinRoundTrips() throws {
        guard let strict = try PeerIdentityPolicy.selfStrictByCertificate() else { return }
        let rig = try XPCRig(serverPolicy: strict, clientPolicy: strict)
        defer { rig.shutdown() }
        rig.manager.start()
        #expect(waitUntil { rig.manager.state == .healthy }, "\(rig.recorder.shape)")
        #expect(rig.agent.snapshot.lastPeerIdentity?.isAdHoc == false)
    }

    /// Layer 2 on the server: a peer that passes libxpc's requirement (the signing
    /// identifier) but not the pinned leaf certificate is rejected per message.
    @Test func serverRejectsPerMessageWhenOnlyLayerTwoFails() throws {
        guard let pinnedWrong = try PeerIdentityPolicy.selfStrictByCertificate(sha1: String(repeating: "0", count: 40)) else {
            // An ad-hoc test runner has no certificate to mis-pin; layer 1 covers it above.
            return
        }
        let rig = try XPCRig(serverPolicy: pinnedWrong)
        defer { rig.shutdown() }
        rig.manager.start()
        #expect(waitUntil { rig.agent.snapshot.rejectedPeers >= 1 })
        #expect(rig.agent.snapshot.lastHello == nil)
        #expect(waitUntil { rig.recorder.shape.contains("reconnecting(1)") })
    }

    /// `ManagedXPCSession` cancels exactly once, explicitly or on release; a bare
    /// `XPCSession` released while active traps the process.
    @Test func droppingManagedSessionsNeverTraps() throws {
        let policy = try PeerIdentityPolicy.selfTest()
        let server = XPCListenerServerTransport(mode: .anonymous, policy: policy)
        try server.start(IPCServerHandlers(onFrame: { frame, _, _ in frame }))
        defer { server.stop() }
        let endpoint = try #require(server.endpoint)
        let queue = DispatchQueue(label: "dev.noema.tests.managed")
        let requirement = try #require(policy.xpcPeerRequirement)
        func inactive() throws -> XPCSession { try XPCSession(endpoint: endpoint, targetQueue: queue, options: .inactive) }
        do {
            let active = try ManagedXPCSession(activating: try inactive(), requirement: requirement)
            try active.send(try XPCFraming.message(carrying: Data("{}".utf8)))
        }
        do {
            _ = try ManagedXPCSession(activating: try inactive(), requirement: nil)
        }
        // A failed activation (a dead endpoint) throws and leaves nothing to trap on release.
        let dead = XPCListener(targetQueue: queue, options: .inactive) { $0.reject(reason: "test") }
        try dead.activate()
        let deadEndpoint = dead.endpoint
        dead.cancel()
        usleep(200_000)
        #expect(throws: (any Error).self) {
            _ = try ManagedXPCSession(activating: try XPCSession(endpoint: deadEndpoint, targetQueue: queue, options: .inactive), requirement: nil)
        }
        let twice = try ManagedXPCSession(activating: try inactive(), requirement: requirement)
        #expect(twice.cancel(reason: "first") && !twice.cancel(reason: "second") && twice.isCancelled)
        #expect(throws: IPCError.cancelled) { try twice.send(try XPCFraming.message(carrying: Data("{}".utf8))) }
        queue.sync {}
        // Reaching here means no session trapped on release.
    }

    /// An unpinned strict policy (what a process without a valid self signature resolves
    /// to) never creates a listener: the agent reports `.failed`, never `.listening`.
    @Test func unpinnedStrictPolicyRefusesToStartTheServer() throws {
        let identifier = try #require(SelfCodeIdentity.current()?.signingIdentifier)
        let unpinned = PeerIdentityPolicy.resolved(
            requested: .allowAdHocForTesting(signingIdentifiers: [identifier]), selfIdentity: nil)
        #expect(unpinned.isUnpinnedStrict)
        let server = XPCListenerServerTransport(mode: .anonymous, policy: unpinned)
        #expect(throws: XPCListenerServerTransport.StartError.unpinnedStrictPolicy) {
            try server.start(IPCServerHandlers(onFrame: { frame, _, _ in frame }))
        }
        #expect(server.endpoint == nil)
        let mach = XPCListenerServerTransport(machService: "dev.noema.tests.unpinned.\(UUID().uuidString)", policy: unpinned)
        let agent = AgentServiceCoordinator(transport: mach, agentVersion: "1.0.0-test")
        guard case .failed = agent.start() else {
            Issue.record("expected .failed, got \(agent.snapshot.listenerState)")
            return
        }
    }

    /// An unpinned strict client opens no session: not one frame (no `ime.hello`) reaches
    /// a listening agent, and the manager degrades as `peerRejected`.
    @Test func unpinnedStrictPolicyRefusesToOpenAClientSession() throws {
        let identifier = try #require(SelfCodeIdentity.current()?.signingIdentifier)
        let unpinned = PeerIdentityPolicy.resolved(
            requested: .allowAdHocForTesting(signingIdentifiers: [identifier]), selfIdentity: nil)
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        let server = XPCListenerServerTransport(mode: .anonymous, policy: try .selfTest())
        try server.start(IPCServerHandlers(
            onFrame: { frame, _, _ in events.withLock { $0.append("frame") }; return frame },
            onEvent: { event in events.withLock { $0.append("\(event)") } }))
        defer { server.stop() }
        let endpoint = try #require(server.endpoint)
        let queue = DispatchQueue(label: "dev.noema.tests.unpinned-client")
        let client = XPCClientTransport(policy: unpinned, queue: queue) { .endpoint(endpoint) }
        #expect(throws: IPCError.peerRejected(PeerVerificationError.unpinnedStrictPolicy.description)) {
            try client.connect(attemptID: 1) { _, _ in }
        }
        #expect(throws: IPCError.connectionUnavailable(.agentUnavailable)) { try client.send(Data("{}".utf8), expectingReply: false) }

        let manager = IPCConnectionManager(
            transport: client, client: .init(bundleID: "dev.noema.tests.ime", version: "1.0.0"),
            policy: .init(baseDelay: .seconds(5), circuitBreakerThreshold: 3), readyNotificationName: nil, queue: queue)
        let recorder = StateRecorder()
        recorder.attach(to: manager)
        defer { manager.stop() }
        manager.start()
        #expect(waitUntil { recorder.shape.contains("degraded(peerRejected)") }, "\(recorder.shape)")
        usleep(200_000)
        #expect(events.withLock { $0 }.isEmpty, "the agent saw \(events.withLock { $0 })")
        #expect(manager.statistics.framesSent == 0)
    }

    /// `stop()` racing incoming sessions: once it returns, no peer is tracked and no
    /// `peerConnected` is reported, however many clients were mid-accept.
    @Test func stopRacingIncomingSessionsLeavesNoPeer() throws {
        let policy = try PeerIdentityPolicy.selfTest()
        for round in 0..<10 {
            let afterStop = OSAllocatedUnfairLock(initialState: (stopped: false, lateConnects: 0))
            let server = XPCListenerServerTransport(mode: .anonymous, policy: policy)
            try server.start(IPCServerHandlers(
                onFrame: { frame, _, _ in frame },
                onEvent: { event in
                    if case .peerConnected = event { afterStop.withLock { if $0.stopped { $0.lateConnects += 1 } } }
                }))
            let endpoint = try #require(server.endpoint)
            let queue = DispatchQueue(label: "dev.noema.tests.race.\(round)")
            let frame = try XPCFraming.message(carrying: Data("{}".utf8))
            let clients = try (0..<8).map { _ in
                let session = try ManagedXPCSession(
                    activating: try XPCSession(endpoint: endpoint, targetQueue: queue, options: .inactive), requirement: nil)
                try? session.send(frame)
                return session
            }
            usleep(UInt32(round % 3) * 1_000)
            server.stop()
            afterStop.withLock { $0.stopped = true }
            #expect(server.connectedPeers.isEmpty, "round \(round)")
            usleep(50_000)
            #expect(server.connectedPeers.isEmpty && afterStop.withLock { $0.lateConnects } == 0, "round \(round)")
            clients.forEach { $0.cancel(reason: "done") }
            queue.sync {}
        }
    }

    /// A Mach service this process was not launched for cannot be checked in: EPERM.
    @Test func machServiceCheckInOutsideLaunchdIsStandby() throws {
        let server = XPCListenerServerTransport(machService: "dev.noema.tests.checkin.\(UUID().uuidString)", policy: try .selfTest())
        let agent = AgentServiceCoordinator(transport: server, agentVersion: "1.0.0-test")
        #expect(agent.start() == .standbyNotLaunchdManaged)
        #expect(agent.snapshot.listenerState == .standbyNotLaunchdManaged)
        agent.stop()
    }

    /// The IME's real Mach client against an agent that is not running: lookup fails, the
    /// manager degrades and backs off; nothing blocks the caller.
    @Test func machClientWithoutAnAgentDegrades() throws {
        let queue = DispatchQueue(label: "dev.noema.tests.mach-client")
        let transport = XPCClientTransport(machService: "dev.noema.tests.absent.\(UUID().uuidString)", policy: try .selfTest(), queue: queue)
        let manager = IPCConnectionManager(
            transport: transport, client: .init(bundleID: "dev.noema.tests.ime", version: "1.0.0"),
            policy: .init(baseDelay: .seconds(5), circuitBreakerThreshold: 3), readyNotificationName: nil, queue: queue)
        let recorder = StateRecorder()
        recorder.attach(to: manager)
        defer { manager.stop() }
        manager.start()
        #expect(waitUntil { recorder.shape.contains("reconnecting(1)") }, "\(recorder.shape)")
        #expect(recorder.shape.contains("degraded(agentUnavailable)") || recorder.shape.contains("degraded(directASCII)"))
        #expect(manager.consecutiveFailures == 1, "the lookup failure's double callback counts once")
        manager.sendFireAndForget(.openSettingsRequested(section: nil))
        #expect(manager.statistics.droppedWhileUnhealthy == 1)
    }
}
