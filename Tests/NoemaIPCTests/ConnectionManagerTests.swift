import Dispatch
import Foundation
import NoemaAgentCore
import NoemaCore
@testable import NoemaIPC
import notify
import Testing

/// `IPCConnectionManager` against the real `AgentServiceCoordinator` over the in-memory
/// transport, on a manual clock: every backoff, cooldown, timeout, and fault is exact.
final class InMemoryRig {
    static let policy = IPCReconnectPolicy(
        baseDelay: .milliseconds(100), maxDelay: .seconds(2), jitterFraction: 0.5, circuitBreakerThreshold: 4,
        circuitCooldown: .seconds(10), handshakeTimeout: .milliseconds(300), heartbeatInterval: nil, outboxCapacity: 32)

    let clock = ManualIPCClock()
    let server = InMemoryServerTransport()
    let agent: AgentServiceCoordinator
    let transport: InMemoryClientTransport
    let manager: IPCConnectionManager
    let recorder = StateRecorder()

    init(
        policy: IPCReconnectPolicy = InMemoryRig.policy, startAgent: Bool = true, readyNotificationName: String? = nil,
        agentOnChange: @escaping @Sendable (AgentServiceSnapshot) -> Void = { _ in }
    ) {
        agent = AgentServiceCoordinator(transport: server, agentVersion: "9.9.9", onChange: agentOnChange)
        if startAgent { agent.start() }
        transport = InMemoryClientTransport(server: server, clock: clock)
        manager = IPCConnectionManager(
            transport: transport, client: .init(bundleID: "dev.noema.tests.ime", version: "1.0.0"), policy: policy,
            clock: clock, jitter: FixedJitter(fraction: 1), readyNotificationName: readyNotificationName)
        recorder.attach(to: manager)
    }

    /// Lets every queued hop between transport and manager run.
    func settle() {
        for _ in 0..<12 { manager.sync {} }
    }

    func startHealthy() {
        manager.start()
        settle()
        #expect(manager.state == .healthy)
    }

    deinit { manager.stop() }
}

@Suite struct ConnectionManagerTests {
    @Test func handshakeReachesHealthyAndEchoesTheEpoch() throws {
        let rig = InMemoryRig()
        rig.startHealthy()
        #expect(rig.recorder.shape == ["connecting(1)", "healthy"])
        let hello = try #require(rig.agent.snapshot.lastHello)
        #expect(hello.clientBundleID == "dev.noema.tests.ime" && hello.sessionEpoch == rig.manager.sessionEpoch)
        #expect(rig.manager.agentSettings == .defaults)
        #expect(rig.agent.snapshot.connectedPeers == 1)
    }

    /// healthy -> degraded(directASCII) -> reconnecting with exponential backoff plus
    /// jitter -> circuitOpen -> (ready signal) -> healthy.
    @Test func degradationBackoffCircuitAndRecovery() throws {
        let rig = InMemoryRig()
        rig.startHealthy()
        rig.agent.stop()
        rig.settle()
        // 100 ms base, +50% jitter (jitterFraction 0.5, FixedJitter at its maximum): 150, 300, 600 ms; the 4th failure opens the circuit.
        #expect(rig.manager.state == .reconnecting(attempt: 1, nextRetryDelay: .milliseconds(150)))
        rig.clock.advance(by: .milliseconds(149))
        #expect(rig.transport.connectCalls == 1, "no retry before the backoff elapses")
        rig.clock.advance(by: .milliseconds(1))
        #expect(rig.manager.state == .reconnecting(attempt: 2, nextRetryDelay: .milliseconds(300)))
        rig.clock.advance(by: .milliseconds(300))
        #expect(rig.manager.state == .reconnecting(attempt: 3, nextRetryDelay: .milliseconds(600)))
        rig.clock.advance(by: .milliseconds(600))
        #expect(rig.manager.state == .circuitOpen(failures: 4, cooldownUntil: rig.clock.now + .seconds(10)))
        #expect(rig.recorder.shape == [
            "connecting(1)", "healthy",
            "degraded(directASCII)", "reconnecting(1)",
            "connecting(2)", "degraded(agentUnavailable)", "reconnecting(2)",
            "connecting(3)", "degraded(agentUnavailable)", "reconnecting(3)",
            "connecting(4)", "degraded(agentUnavailable)", "circuitOpen(4)",
        ])
        // While open, nothing is attempted.
        rig.clock.advance(by: .seconds(9))
        #expect(rig.transport.connectCalls == 4)

        // The agent comes back and announces itself: no need to wait out the cooldown.
        rig.agent.start()
        rig.manager.agentReadySignalReceived()
        rig.settle()
        #expect(rig.manager.state == .healthy && rig.manager.consecutiveFailures == 0)
        #expect(rig.transport.connectCalls == 5)
    }

    /// Without a ready signal the circuit half-opens after the cooldown: one probe.
    @Test func halfOpenProbeAfterCooldown() {
        let rig = InMemoryRig(startAgent: false)
        rig.manager.start()
        rig.settle()
        for delay in [150, 300, 600] { rig.clock.advance(by: .milliseconds(delay)) }
        guard case .circuitOpen(4, _) = rig.manager.state else {
            Issue.record("expected an open circuit, got \(rig.manager.state)")
            return
        }
        rig.clock.advance(by: .seconds(10))
        guard case .circuitOpen(5, _) = rig.manager.state else {
            Issue.record("a failed probe re-opens the circuit, got \(rig.manager.state)")
            return
        }
        rig.agent.start()
        rig.clock.advance(by: .seconds(10))
        rig.settle()
        #expect(rig.manager.state == .healthy)
        #expect(rig.transport.connectCalls == 6)
    }

    /// A connect that throws *and* reports a disconnect for the same attempt (libxpc on a
    /// Mach lookup failure) counts as one failure.
    @Test func doubleCallbackOfAThrownAttemptCountsOnce() {
        let rig = InMemoryRig()
        var faults = InMemoryFaults()
        faults.failingConnects = 1
        faults.reportsDisconnectOnConnectFailure = true
        rig.transport.faults = faults
        rig.manager.start()
        rig.settle()
        #expect(rig.manager.consecutiveFailures == 1)
        #expect(rig.manager.statistics.ignoredStaleCallbacks == 1)
        #expect(rig.recorder.shape == ["connecting(1)", "degraded(agentUnavailable)", "reconnecting(1)"])
        rig.clock.advance(by: .milliseconds(150))
        rig.settle()
        #expect(rig.manager.state == .healthy)
    }

    @Test func handshakeTimeoutDegrades() throws {
        let rig = InMemoryRig(startAgent: false)
        try rig.server.start(IPCServerHandlers(onFrame: { _, _, _ in nil }))
        rig.manager.start()
        rig.settle()
        #expect(rig.manager.state == .connecting(attempt: 1))
        rig.clock.advance(by: .milliseconds(299))
        #expect(rig.manager.state == .connecting(attempt: 1))
        rig.clock.advance(by: .milliseconds(1))
        #expect(rig.recorder.shape.suffix(2) == ["degraded(timeout)", "reconnecting(1)"])
        #expect(!rig.transport.isConnected, "a timed-out attempt is disconnected")
    }

    @Test func heartbeatsKeepItHealthyAndAMissingAckDegrades() {
        var policy = InMemoryRig.policy
        policy.heartbeatInterval = .seconds(1)
        let rig = InMemoryRig(policy: policy)
        rig.startHealthy()
        rig.clock.advance(by: .seconds(1))
        rig.settle()
        rig.clock.advance(by: .seconds(1))
        rig.settle()
        #expect(rig.manager.state == .healthy)
        let kinds = rig.server.receivedFrames.compactMap { try? IPCWireCodec.decode(IMEToAgent.self, from: $0).kind }
        #expect(kinds == [IMEToAgent.helloKind, IMEToAgent.heartbeatKind, IMEToAgent.heartbeatKind])

        var faults = InMemoryFaults()
        faults.holdsInbound = true
        rig.transport.faults = faults
        rig.clock.advance(by: .seconds(1))
        rig.settle()
        rig.clock.advance(by: .milliseconds(300))
        #expect(rig.recorder.shape.suffix(2) == ["degraded(timeout)", "reconnecting(1)"])
    }

    @Test func peerRejectionDegrades() {
        let rig = InMemoryRig()
        var faults = InMemoryFaults()
        faults.rejectsPeer = true
        rig.transport.faults = faults
        rig.manager.start()
        rig.settle()
        #expect(rig.recorder.shape == ["connecting(1)", "degraded(peerRejected)", "reconnecting(1)"])
    }

    @Test func inboundLatencyDelaysTheHandshake() {
        let rig = InMemoryRig()
        var faults = InMemoryFaults()
        faults.inboundLatency = .milliseconds(50)
        rig.transport.faults = faults
        rig.manager.start()
        rig.settle()
        #expect(rig.manager.state == .connecting(attempt: 1))
        rig.clock.advance(by: .milliseconds(50))
        rig.settle()
        #expect(rig.manager.state == .healthy)
    }

    /// Prior-epoch, stale, duplicate, out-of-order, and not-current AI suggestion packets
    /// are dropped and counted; only the newest of each kind reaches the handler.
    @Test func generationGateDropsStaleDuplicateAndForeignPackets() throws {
        let rig = InMemoryRig()
        rig.startHealthy()
        let epoch = rig.manager.sessionEpoch
        func settings(_ generation: UInt64, epoch: UUID? = nil, backdrop: String = "glass") throws -> Data {
            try agentFrame(
                .settingsSnapshot(sessionEpoch: epoch ?? rig.manager.sessionEpoch, settings: AgentSettingsSnapshot(panelBackdropPreference: backdrop)),
                generationID: generation)
        }
        rig.transport.injectInbound(try settings(5, backdrop: "five"))
        rig.transport.injectInbound(try settings(5, backdrop: "dup"))
        rig.transport.injectInbound(try settings(3, backdrop: "stale"))
        rig.transport.injectInbound(try settings(9, epoch: UUID(), backdrop: "foreign"))
        rig.settle()
        #expect(rig.manager.agentSettings?.panelBackdropPreference == "five")

        var faults = InMemoryFaults()
        faults.duplicatesInbound = true
        rig.transport.faults = faults
        rig.transport.injectInbound(try settings(6, backdrop: "six"))
        faults.duplicatesInbound = false
        faults.holdsInbound = true
        rig.transport.faults = faults
        rig.transport.injectInbound(try settings(7, backdrop: "seven"))
        rig.transport.injectInbound(try settings(8, backdrop: "eight"))
        rig.transport.releaseHeld(reversed: true)
        rig.settle()
        #expect(rig.manager.agentSettings?.panelBackdropPreference == "eight", "the late 7 must not win")

        // AI suggestions: only for the composition the IME shows now.
        rig.transport.faults = InMemoryFaults()
        rig.manager.sendFireAndForget(.compositionStateChanged(
            CompositionSnapshot(sessionEpoch: epoch, generationID: 20, isComposing: true, candidateCount: 3, isASCIIMode: false)))
        func suggestion(_ generation: UInt64) throws -> Data {
            try agentFrame(.aiSuggestion(AISuggestionMessage(sessionEpoch: epoch, generationID: generation, suggestion: "s\(generation)", provider: "p")), generationID: generation)
        }
        rig.transport.injectInbound(try suggestion(19))
        rig.transport.injectInbound(try suggestion(20))
        rig.transport.injectInbound(try suggestion(20))
        rig.settle()
        let suggestions = rig.recorder.received.compactMap { if case .aiSuggestion(let s) = $0 { s.suggestion } else { nil } }
        #expect(suggestions == ["s20"])
        let settingsSeen = rig.recorder.received.compactMap { if case .settingsSnapshot(_, let s, _) = $0 { s.panelBackdropPreference } else { nil } }
        #expect(settingsSeen == ["five", "six", "eight"])
        #expect(rig.manager.statistics.gateDrops == [.duplicate: 3, .stale: 2, .epochMismatch: 1, .notCurrentComposition: 1])
    }

    /// Fire-and-forget never waits: unhealthy drops in O(1); a stalled IPC queue coalesces
    /// composition updates and caps everything else.
    @Test func fireAndForgetIsBoundedAndNeverBlocks() throws {
        let rig = InMemoryRig()
        let clock = ContinuousClock()
        let before = clock.now
        for generation in 0..<10_000 {
            rig.manager.sendFireAndForget(.compositionStateChanged(
                CompositionSnapshot(sessionEpoch: UUID(), generationID: UInt64(generation), isComposing: true, candidateCount: 1, isASCIIMode: false)))
        }
        let elapsed = clock.now - before
        #expect(rig.manager.statistics.droppedWhileUnhealthy == 10_000)
        #expect(elapsed < .milliseconds(200), "10k unhealthy sends took \(elapsed)")
        #expect(rig.server.receivedFrames.isEmpty)

        rig.startHealthy()
        let stall = DispatchSemaphore(value: 0)
        rig.manager.queue.async { stall.wait() }
        for generation in 1...100 {
            rig.manager.sendFireAndForget(.compositionStateChanged(
                CompositionSnapshot(sessionEpoch: UUID(), generationID: UInt64(generation), isComposing: true, candidateCount: 1, isASCIIMode: false)))
        }
        for _ in 0..<100 { rig.manager.sendFireAndForget(.openSettingsRequested(section: .other)) }
        stall.signal()
        rig.settle()
        let statistics = rig.manager.statistics
        #expect(statistics.coalesced == 99 && statistics.droppedOutboxFull == 69)
        let sent = try rig.server.receivedFrames.dropFirst().map { try IPCWireCodec.decode(IMEToAgent.self, from: $0) }
        #expect(sent.count == 32)
        #expect(sent.first?.payload.kind == IMEToAgent.compositionStateChangedKind && sent.first?.generationID == 100)
        let composition = try #require(rig.agent.snapshot.lastComposition)
        #expect(composition.generationID == 100 && composition.sessionEpoch == rig.manager.sessionEpoch, "the manager stamps the epoch")
    }

    @Test func readySignalsAreDebounced() {
        let rig = InMemoryRig(startAgent: false)
        rig.manager.start()
        rig.settle()
        #expect(rig.transport.connectCalls == 1)
        rig.manager.agentReadySignalReceived()
        rig.manager.agentReadySignalReceived()
        rig.settle()
        #expect(rig.transport.connectCalls == 2)
        #expect(rig.manager.statistics.debouncedReadySignals == 1)
        rig.clock.advance(by: .milliseconds(100))
        rig.manager.agentReadySignalReceived()
        rig.settle()
        #expect(rig.transport.connectCalls == 3)
    }

    /// The real Darwin notification wakes an open circuit.
    @Test func darwinReadyNotificationReconnects() {
        let name = "dev.noema.tests.ready.\(UUID().uuidString)"
        let rig = InMemoryRig(startAgent: false, readyNotificationName: name)
        rig.manager.start()
        rig.settle()
        for delay in [150, 300, 600] { rig.clock.advance(by: .milliseconds(delay)) }
        guard case .circuitOpen = rig.manager.state else {
            Issue.record("expected an open circuit, got \(rig.manager.state)")
            return
        }
        rig.agent.start()
        #expect(notify_post(name) == UInt32(NOTIFY_STATUS_OK))
        #expect(waitUntil { rig.settle(); return rig.manager.state == .healthy })
    }

    /// `stop()` called from the state observer itself, on `.degraded` and on `.healthy`:
    /// nothing is scheduled after it, the state stays `.idle`, no timer is left.
    @Test func reentrantStopFromTheStateObserverLeavesNothingRunning() {
        var policy = InMemoryRig.policy
        policy.heartbeatInterval = .seconds(1)
        for trigger in ["degraded", "healthy"] {
            let rig = InMemoryRig(policy: policy, startAgent: trigger == "healthy")
            let recorder = rig.recorder
            rig.manager.setStateObserver { [weak manager = rig.manager] state in
                recorder.record(state)
                let hit: Bool
                switch state {
                case .degraded: hit = trigger == "degraded"
                case .healthy: hit = trigger == "healthy"
                default: hit = false
                }
                if hit { manager?.stop() }
            }
            rig.manager.start()
            rig.settle()
            #expect(rig.manager.state == .idle, "\(trigger): \(rig.manager.state)")
            #expect(rig.recorder.shape.last == "idle", "\(trigger): \(rig.recorder.shape)")
            #expect(rig.clock.pendingTimerCount == 0, "\(trigger): a timer survived the re-entrant stop")
            rig.clock.advance(by: .seconds(60))
            rig.settle()
            #expect(rig.transport.connectCalls == 1 && rig.manager.state == .idle, "\(trigger)")
        }
    }

    /// A `heartbeatAck` while `.connecting` must not disarm the handshake timeout.
    @Test func heartbeatAckWhileConnectingIsIgnored() throws {
        let rig = InMemoryRig(startAgent: false)
        try rig.server.start(IPCServerHandlers(onFrame: { _, _, _ in nil }))
        rig.manager.start()
        rig.settle()
        #expect(rig.manager.state == .connecting(attempt: 1))
        rig.transport.injectInbound(try agentFrame(.heartbeatAck(sessionEpoch: rig.manager.sessionEpoch), generationID: 1))
        rig.settle()
        #expect(rig.manager.statistics.ignoredOutOfStateMessages == 1)
        #expect(rig.recorder.received.isEmpty)
        rig.clock.advance(by: .milliseconds(300))
        #expect(rig.recorder.shape.suffix(2) == ["degraded(timeout)", "reconnecting(1)"], "\(rig.recorder.shape)")
    }

    /// `helloAck` counts only while `.connecting`; settings revisions never go backwards.
    @Test func lateHelloAckAndOlderSettingsRevisionsAreIgnored() throws {
        let rig = InMemoryRig()
        rig.agent.updateSettings(AgentSettingsSnapshot(panelBackdropPreference: "one"))
        rig.agent.updateSettings(AgentSettingsSnapshot(panelBackdropPreference: "two"))
        rig.startHealthy()
        #expect(rig.manager.agentSettings?.panelBackdropPreference == "two", "helloAck carries revision 2")
        let epoch = rig.manager.sessionEpoch

        // A second helloAck (new generation, so the gate admits it) changes nothing.
        rig.transport.injectInbound(try agentFrame(
            .helloAck(AgentHelloAck(agentVersion: "evil", sessionEpoch: epoch, settings: AgentSettingsSnapshot(panelBackdropPreference: "late"), settingsRevision: 99)),
            generationID: 50))
        rig.settle()
        #expect(rig.manager.agentSettings?.panelBackdropPreference == "two")
        #expect(rig.manager.statistics.ignoredOutOfStateMessages == 1)

        // Gate-fresh generations (no settingsSnapshot seen yet), but revision 1 < 2: ignored.
        func snapshot(_ backdrop: String, revision: UInt64, generation: UInt64) throws -> Data {
            try agentFrame(.settingsSnapshot(sessionEpoch: epoch, settings: AgentSettingsSnapshot(panelBackdropPreference: backdrop), revision: revision), generationID: generation)
        }
        rig.transport.injectInbound(try snapshot("older", revision: 1, generation: 1))
        rig.settle()
        #expect(rig.manager.agentSettings?.panelBackdropPreference == "two")
        #expect(rig.manager.statistics.staleSettingsRevisions == 1)
        rig.transport.injectInbound(try snapshot("three", revision: 3, generation: 2))
        rig.settle()
        #expect(rig.manager.agentSettings?.panelBackdropPreference == "three")
        // The real agent's next push is revision 3 as well (>= applied): accepted.
        rig.agent.updateSettings(AgentSettingsSnapshot(panelBackdropPreference: "agent"))
        rig.settle()
        #expect(rig.manager.agentSettings?.panelBackdropPreference == "agent")
        let seen = rig.recorder.received.compactMap { if case .settingsSnapshot(_, let s, _) = $0 { s.panelBackdropPreference } else { nil } }
        #expect(seen == ["three", "agent"])
        #expect(rig.manager.state == .healthy && rig.manager.consecutiveFailures == 0)
    }

    /// The agent pushes revision 1 while handling `hello`, so the client sees that
    /// `settingsSnapshot` before the `helloAck` carrying revision 0. The ack still completes
    /// the handshake, but its older settings must not roll revision 1 back.
    @Test func settingsPushedBeforeHelloAckAreNotRolledBack() throws {
        let push = PushSettingsDuringHello(AgentSettingsSnapshot(panelBackdropPreference: "visualEffect"))
        let rig = InMemoryRig(agentOnChange: push.onChange)
        push.attach(rig.agent)
        rig.startHealthy()
        #expect(rig.recorder.shape == ["connecting(1)", "healthy"])
        #expect(rig.manager.agentSettings?.panelBackdropPreference == "visualEffect", "helloAck (revision 0, glass) rolled settings back")
        #expect(rig.manager.statistics.staleSettingsRevisions == 1)
        #expect(rig.manager.statistics.ignoredOutOfStateMessages == 0)
        #expect(rig.manager.consecutiveFailures == 0)
        // Each attempt starts its own revision baseline: a restarted agent counts from 0.
        rig.agent.stop()
        rig.settle()
        let restarted = AgentServiceCoordinator(
            transport: rig.server, agentVersion: "9.9.9", settings: AgentSettingsSnapshot(panelBackdropPreference: "restarted"))
        restarted.start()
        defer { restarted.stop() }
        rig.clock.advance(by: .milliseconds(150))
        rig.settle()
        #expect(rig.manager.state == .healthy)
        #expect(rig.manager.agentSettings?.panelBackdropPreference == "restarted", "a new agent's revision 0 is not stale")
        #expect(rig.manager.statistics.staleSettingsRevisions == 1)
    }

    /// The ready notification is unauthenticated: spamming it cannot bypass the circuit
    /// cooldown. One ready probe per open circuit, then a fresh one after a cooldown elapses.
    @Test func readyProbesFromAnOpenCircuitAreRateLimited() {
        let rig = InMemoryRig(startAgent: false)
        rig.manager.start()
        rig.settle()
        for delay in [150, 300, 600] { rig.clock.advance(by: .milliseconds(delay)) }
        #expect(rig.transport.connectCalls == 4)
        rig.manager.agentReadySignalReceived()
        rig.settle()
        #expect(rig.transport.connectCalls == 5, "the first ready signal probes at once")
        guard case .circuitOpen(5, _) = rig.manager.state else {
            Issue.record("the failed probe re-opens the circuit, got \(rig.manager.state)")
            return
        }
        for _ in 0..<20 {
            rig.clock.advance(by: .milliseconds(100))
            rig.manager.agentReadySignalReceived()
            rig.settle()
        }
        #expect(rig.transport.connectCalls == 5, "spammed ready signals must not bypass the cooldown")
        #expect(rig.manager.statistics.rateLimitedReadySignals == 20)

        // 2 s already passed; the cooldown elapses on its own: one natural probe, and the
        // next open circuit honours one ready probe again.
        rig.clock.advance(by: .seconds(8))
        rig.settle()
        #expect(rig.transport.connectCalls == 6)
        rig.agent.start()
        rig.clock.advance(by: .milliseconds(100))
        rig.manager.agentReadySignalReceived()
        rig.settle()
        #expect(rig.transport.connectCalls == 7 && rig.manager.state == .healthy)
    }

    /// Dropped without `stop()`: `deinit` cancels every pending timer.
    @Test func droppingAManagerCancelsItsTimers() {
        let clock = ManualIPCClock()
        do {
            let manager = IPCConnectionManager(
                transport: InMemoryClientTransport(server: InMemoryServerTransport(), clock: clock),
                client: .init(bundleID: "dev.noema.tests.ime", version: "1.0.0"), policy: InMemoryRig.policy,
                clock: clock, jitter: FixedJitter(fraction: 1), readyNotificationName: "dev.noema.tests.ready.\(UUID().uuidString)")
            manager.start()
            for _ in 0..<4 { manager.sync {} }
            #expect(clock.pendingTimerCount == 1)
        }
        #expect(clock.pendingTimerCount == 0)
    }

    @Test func stopCancelsTimersAndIgnoresLateEvents() {
        let rig = InMemoryRig(startAgent: false)
        rig.manager.start()
        rig.settle()
        #expect(rig.clock.pendingTimerCount == 1)
        rig.manager.stop()
        #expect(rig.manager.state == .idle && rig.clock.pendingTimerCount == 0)
        rig.clock.advance(by: .seconds(60))
        #expect(rig.transport.connectCalls == 1)
        rig.manager.stop()
    }
}
