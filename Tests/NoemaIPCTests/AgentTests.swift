import Foundation
import NoemaAgentCore
import NoemaCore
@testable import NoemaIPC
import os
import Testing

/// The real `NoemaAgent` executable's headless probes, and the agent-side coordinator and
/// Settings model.
@Suite struct AgentTests {
    @Test func agentExecutableAnswersProbesWithoutAppKit() throws {
        let agent = try TestBinaries.path(NoemaPaths.agentExecutableName)
        let version = try TestBinaries.run(agent, ["--version"])
        #expect(version.status == 0 && version.stdout == "NoemaAgent \(NoemaVersion.current)\n")
        let help = try TestBinaries.run(agent, ["--help"])
        #expect(help.status == 0 && help.stdout.contains("usage: NoemaAgent"))
        let bogus = try TestBinaries.run(agent, ["--bogus"])
        #expect(bogus.status == 2 && bogus.stdout.isEmpty && bogus.stderr.contains("usage: NoemaAgent"))
    }

    @Test func coordinatorAnswersHelloHeartbeatAndRecordsMetadata() throws {
        let server = InMemoryServerTransport()
        let opened = OSAllocatedUnfairLock<[SettingsSectionID?]>(initialState: [])
        let agent = AgentServiceCoordinator(
            transport: server, agentVersion: "2.0.0", onOpenSettings: { section in opened.withLock { $0.append(section) } })
        #expect(agent.start() == .listening)
        let client = InMemoryClientTransport(server: server)
        let replies = OSAllocatedUnfairLock<[IPCEnvelope<AgentToIME>]>(initialState: [])
        try client.connect(attemptID: 1) { _, event in
            if case .received(let frame, _) = event, let envelope = try? IPCWireCodec.decode(AgentToIME.self, from: frame) {
                replies.withLock { $0.append(envelope) }
            }
        }
        #expect(agent.snapshot.connectedPeers == 1)
        // Two settings changes before any hello: nothing is pushed, the revision is 2.
        agent.updateSettings(AgentSettingsSnapshot(panelBackdropPreference: "visualEffect"))
        agent.updateSettings(.defaults)
        let epoch = UUID()
        func send(_ message: IMEToAgent, _ generation: UInt64?) throws {
            try client.send(IPCWireCodec.encode(IPCEnvelope(sequence: 1, message: message, generationID: generation)), expectingReply: true)
        }
        try send(.hello(IMEHello(clientBundleID: NoemaPaths.imeBundleID, clientVersion: "0.1.0", sessionEpoch: epoch, engineMode: "rime")), 1)
        try send(.heartbeat(sessionEpoch: epoch), 7)
        try send(.heartbeat(sessionEpoch: UUID()), 8)
        for generation: UInt64 in [3, 5, 4] {
            try send(.compositionStateChanged(CompositionSnapshot(sessionEpoch: epoch, generationID: generation, isComposing: true, candidateCount: 2, isASCIIMode: false)), generation)
        }
        try send(.openSettingsRequested(section: .quickActions), nil)
        let received = replies.withLock { $0 }
        #expect(received.map(\.kind) == [AgentToIME.helloAckKind, AgentToIME.heartbeatAckKind])
        #expect(received.map(\.generationID) == [1, 7], "replies echo the request generation")
        #expect(received.allSatisfy { $0.payload.sessionEpoch == epoch })
        if case .helloAck(let ack) = received.first?.payload {
            #expect(ack.settingsRevision == 2, "helloAck carries the agent's settings revision")
        } else {
            Issue.record("expected helloAck first")
        }
        let snapshot = agent.snapshot
        #expect(snapshot.lastComposition?.generationID == 5 && snapshot.staleCompositionDrops == 1)
        #expect(snapshot.lastHello?.engineMode == "rime" && snapshot.framesHandled == 7)
        #expect(opened.withLock { $0 } == [.quickActions])

        client.disconnect(reason: "done")
        #expect(agent.snapshot.connectedPeers == 0)
        #expect(throws: IPCError.connectionUnavailable(.agentUnavailable)) { try client.send(Data("{}".utf8), expectingReply: false) }
    }

    @MainActor
    @Test func settingsModelDrivesTheLaunchAgent() {
        let fake = FakeLaunchAgent()
        let model = AgentStatusModel(agentVersion: "1.0.0", launchAgent: fake)
        #expect(model.launchAgentStatus == .notRegistered && !model.isLaunchAgentRequested)
        model.setLaunchAgentEnabled(true)
        #expect(model.launchAgentStatus == .requiresApproval && model.isLaunchAgentRequested)
        fake.approve()
        model.refreshLaunchAgentStatus()
        #expect(model.launchAgentStatus == .enabled)
        model.setLaunchAgentEnabled(false)
        #expect(model.launchAgentStatus == .notRegistered && model.lastLaunchAgentError == nil)
        fake.failNext()
        model.setLaunchAgentEnabled(true)
        #expect(model.launchAgentStatus == .notRegistered && model.lastLaunchAgentError != nil)
        model.openLoginItems()
        #expect(fake.calls == ["register", "unregister", "register-failed", "openLoginItems"])

        var snapshot = AgentServiceSnapshot()
        snapshot.listenerState = .standbyNotLaunchdManaged
        snapshot.connectedPeers = 2
        model.apply(snapshot)
        #expect(model.service.listenerState == .standbyNotLaunchdManaged && model.service.connectedPeers == 2)
        #expect(SettingsSectionID.sidebarOrder.map(\.title) == ["基础设置", "快速操作", "词库", "其他"])
        #expect(Set(SettingsSectionID.sidebarOrder) == Set(SettingsSectionID.allCases), "every section is in the sidebar")
    }

    @Test func unbundledSMAppServiceReportsAStatus() {
        // A test binary carries no Contents/Library/LaunchAgents plist; the real
        // SMAppService answers without registering anything.
        #expect(LaunchAgentStatus.allCases.contains(SMAppServiceLaunchAgentController().status))
    }
}

/// The launchd/System Settings boundary, recorded.
final class FakeLaunchAgent: LaunchAgentControlling, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var current: LaunchAgentStatus = .notRegistered
    private var failing = false
    private var log: [String] = []

    var calls: [String] { lock.withLock { log } }
    var status: LaunchAgentStatus { lock.withLock { current } }
    func approve() { lock.withLock { current = .enabled } }
    func failNext() { lock.withLock { failing = true } }

    func register() throws {
        try lock.withLock {
            if failing {
                failing = false
                log.append("register-failed")
                throw Failure()
            }
            log.append("register")
            current = .requiresApproval
        }
    }

    func unregister() throws {
        lock.withLock {
            log.append("unregister")
            current = .notRegistered
        }
    }

    func openSystemSettingsLoginItems() { lock.withLock { log.append("openLoginItems") } }
}
