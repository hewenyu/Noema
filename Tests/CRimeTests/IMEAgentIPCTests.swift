import AppKit
import Foundation
import NoemaAgentCore
import NoemaCore
import NoemaEngine
import NoemaIMEShell
import NoemaIPC
import notify
import os
import Testing
import XPC

/// The IME's typing path with the agent connection attached exactly as `EngineHost` wires
/// it (`InputSessionCoordinator.onCompositionChange` -> `CompositionIPCReporter` ->
/// `IPCConnectionManager.sendFireAndForget`): the real `RimeEngine`, the real coordinator,
/// the real manager, and a real libxpc agent (`AgentServiceCoordinator` on an anonymous
/// `XPCListener`). Only the text client is a recording stand-in.
extension LibrimeSerializedTests {
    @MainActor
    @Suite struct IMEAgentIPCTests {
        /// The latency benchmark's mix: letters, paging, selection, backspace, commits, punctuation.
        static let cycle: [KeyEvent] = {
            var keys: [KeyEvent] = "nihao".map(KeyEvent.text)
            keys += [.text("="), .text("-"), .key(VirtualKeyCode.space, " ")]
            keys += "jintiantianqi".map(KeyEvent.text)
            keys += [.key(VirtualKeyCode.delete, "\u{7F}"), .text("i")]
            keys += [.key(VirtualKeyCode.leftArrow, "", .function), .key(VirtualKeyCode.return, "\r")]
            keys += "shi".map(KeyEvent.text)
            keys += [.key(VirtualKeyCode.pageDown, "", .function), .text("2"), .text(",")]
            keys += "xi'an".map(KeyEvent.text)
            keys += [.key(VirtualKeyCode.escape, "\u{1B}")]
            return keys
        }()

        static func keys(_ count: Int) -> [KeyEvent] {
            (0..<count).map { cycle[$0 % cycle.count] }
        }

        /// The agent dies (its listener and every peer session cancelled) at key 150 of 500.
        /// Typing is byte-for-byte what it is without any agent, P95 stays under 2 ms, the
        /// connection walks degraded -> reconnecting -> circuitOpen, and a restarted agent
        /// plus the ready notification brings it back.
        @Test func killedAgentNeverStallsOrChangesTyping() throws {
            let keys = Self.keys(500)

            // Reference: the same keys with no agent connection at all.
            let reference = try Harness()
            let referenceClient = RecordingClient()
            let referenceToken = UUID()
            let referenceHandled = keys.map { reference.coordinator.handleKey($0, token: referenceToken, client: referenceClient) }
            reference.shutdown()

            let harness = try Harness()
            defer { harness.shutdown() }
            let readyName = "dev.noema.tests.ready.\(UUID().uuidString)"
            let link = try AgentLink(readyNotificationName: readyName)
            defer { link.shutdown() }
            let reporter = CompositionIPCReporter(manager: link.manager, isSecureInputEnabled: { false })
            harness.coordinator.onCompositionChange = { reporter.report($0) }
            link.manager.start()
            #expect(poll { link.manager.state == .healthy }, "state: \(link.manager.state)")

            let client = RecordingClient()
            let token = UUID()
            let clock = ContinuousClock()
            var samples: [Duration] = []
            var handled: [Bool] = []
            var agentBeforeKill = AgentServiceSnapshot()
            for (index, key) in keys.enumerated() {
                if index == 150 {
                    #expect(poll { link.agent.snapshot.lastComposition != nil })
                    agentBeforeKill = link.agent.snapshot
                    link.killAgent()
                }
                let start = clock.now
                handled.append(harness.coordinator.handleKey(key, token: token, client: client))
                samples.append(clock.now - start)
            }

            #expect(handled == referenceHandled, "the agent's death changed which keys were handled")
            #expect(client.calls == referenceClient.calls, "the agent's death changed what the client received")
            #expect(client.inserts.contains("你好"))
            #expect(handled.filter { $0 }.count > 400)
            samples.sort()
            let p95 = samples[Int(Double(samples.count) * 0.95)]
            print("[IME+IPC latency] keys=500 agent killed at 150 P95=\(p95) max=\(samples.last!)")
            #expect(p95 < .milliseconds(2), "P95 \(p95) exceeds the 2 ms budget")

            // The agent saw metadata only, and the manager walked down to an open circuit.
            let seen = try #require(agentBeforeKill.lastComposition)
            #expect(seen.sessionEpoch == agentBeforeKill.lastHello?.sessionEpoch)
            #expect(poll { if case .circuitOpen = link.manager.state { true } else { false } }, "state: \(link.manager.state)")
            let shape = link.recorder.shape
            #expect(shape.prefix(4) == ["connecting(1)", "healthy", "degraded(directASCII)", "reconnecting(1)"], "\(shape)")
            #expect(shape.last == "circuitOpen(3)", "\(shape)")
            #expect(link.manager.statistics.droppedWhileUnhealthy > 0, "keys after the kill were dropped, not queued")

            // The agent restarts and announces itself.
            try link.restartAgent()
            #expect(notify_post(readyName) == UInt32(NOTIFY_STATUS_OK))
            #expect(poll { link.manager.state == .healthy }, "state: \(link.manager.state)")
            for key in "nihao" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            #expect(poll { link.agent.snapshot.lastComposition?.isComposing == true })
            #expect(link.agent.snapshot.lastComposition?.candidateCount ?? 0 > 0)
        }

        /// While `IsSecureEventInputEnabled()` is true not one IPC frame leaves the IME:
        /// keys, commits, panel clicks, mode switches, direct reports, and the live 15 s
        /// heartbeat are all silent. The manager is wired with the same flag, as `EngineHost` does.
        @Test func secureInputEmitsZeroIPCMessages() throws {
            let secure = SecureFlag()
            let harness = try Harness(isSecureInputEnabled: { secure.isOn })
            defer { harness.shutdown() }
            let server = InMemoryServerTransport()
            let agent = AgentServiceCoordinator(transport: server, agentVersion: "1.0.0-test")
            agent.start()
            let clock = ManualIPCClock()
            let manager = IPCConnectionManager(
                transport: InMemoryClientTransport(server: server, clock: clock),
                client: .init(bundleID: NoemaPaths.imeBundleID, version: "0.0.0-test"),
                policy: .init(heartbeatInterval: .seconds(15)), clock: clock, readyNotificationName: nil,
                isSecureInputEnabled: { secure.isOn })
            defer { manager.stop() }
            let reporter = CompositionIPCReporter(manager: manager, isSecureInputEnabled: { secure.isOn })
            harness.coordinator.onCompositionChange = { reporter.report($0) }
            func settle() { for _ in 0..<12 { manager.sync {} } }
            manager.start()
            settle()
            try #require(manager.state == .healthy)

            let client = RecordingClient()
            let token = UUID()
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            settle()
            let framesBefore = server.receivedFrames.count
            #expect(framesBefore >= 2, "hello plus composition updates")

            secure.isOn = true
            for key in "hao" { #expect(!harness.coordinator.handleKey(.text(key), token: token, client: client)) }
            _ = harness.coordinator.handleKey(.key(VirtualKeyCode.space, " "), token: token, client: client)
            harness.coordinator.commitComposition(token: token, client: client)
            _ = harness.coordinator.selectCandidate(at: 0)
            harness.coordinator.setInputMode(InputSessionCoordinator.asciiInputModeID, token: token, client: client)
            reporter.report(harness.engine.currentState)
            reporter.requestOpenSettings(section: .general)
            settle()
            // Four heartbeat intervals pass under secure input.
            for _ in 0..<4 {
                clock.advance(by: .seconds(15))
                settle()
            }
            #expect(server.receivedFrames.count == framesBefore, "an IPC frame left the IME under secure input")
            #expect(manager.statistics.suppressedForSecureInput >= 4, "the skipped heartbeats")
            // The dropped "ni" (first secure key), the ASCII switch, the direct report, and
            // the Settings request.
            #expect(reporter.suppressedForSecureInput == 4)
            #expect(manager.state == .healthy)

            secure.isOn = false
            harness.engine.setASCIIMode(false)
            _ = harness.coordinator.handleKey(.text("a"), token: token, client: client)
            settle()
            #expect(server.receivedFrames.count > framesBefore, "reports resume once secure input ends")
            let framesAfterResume = server.receivedFrames.count
            clock.advance(by: .seconds(15))
            settle()
            #expect(server.receivedFrames.count == framesAfterResume + 1, "heartbeats resume once secure input ends")
            #expect(manager.state == .healthy)
        }
    }
}

extension LibrimeSerializedTests.IMEAgentIPCTests {
    /// Each way a composition leaves the screen without a commit.
    enum Leave: CaseIterable {
        case deactivate, controllerWillClose, ownershipTransfer
    }

    /// Typing `ni`, then losing it (focus loss, controller close, another client taking
    /// over) tells the real agent over real libxpc that nothing is composing, and a late AI
    /// suggestion for the lost generation is dropped as `.notCurrentComposition`. A
    /// suggestion for the next live composition is still delivered.
    @Test func droppedCompositionsClearTheAgentAndRejectLateSuggestions() throws {
        let harness = try Harness()
        defer { harness.shutdown() }
        let link = try AgentLink(readyNotificationName: "dev.noema.tests.ready.\(UUID().uuidString)")
        defer { link.shutdown() }
        let reporter = CompositionIPCReporter(manager: link.manager, isSecureInputEnabled: { false })
        harness.coordinator.onCompositionChange = { reporter.report($0) }
        let suggestions = SuggestionRecorder()
        link.manager.setMessageHandler { suggestions.record($0) }
        link.manager.start()
        try #require(poll { link.manager.state == .healthy }, "state: \(link.manager.state)")

        func push(_ generation: UInt64) {
            link.agent.pushSuggestion(AISuggestionMessage(
                sessionEpoch: link.manager.sessionEpoch, generationID: generation, suggestion: "s\(generation)", provider: "test"))
        }
        func notCurrentDrops() -> Int { link.manager.statistics.gateDrops[.notCurrentComposition] ?? 0 }
        func typeNi(token: UUID, client: RecordingClient) -> UInt64 {
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            let generation = harness.engine.currentState.generationID
            #expect(poll { link.agent.snapshot.lastComposition.map { $0.generationID == generation && $0.isComposing } == true })
            return generation
        }

        for leave in Leave.allCases {
            let token = UUID()
            let client = RecordingClient()
            let oldGen = typeNi(token: token, client: client)
            let other = (token: UUID(), client: RecordingClient())
            switch leave {
            case .deactivate: harness.coordinator.deactivate(token: token)
            case .controllerWillClose: harness.coordinator.controllerWillClose(token: token)
            case .ownershipTransfer: harness.coordinator.activate(token: other.token, client: other.client)
            }
            #expect(!harness.engine.currentState.isComposing, "\(leave)")
            #expect(
                poll { link.agent.snapshot.lastComposition.map { !$0.isComposing && $0.generationID > oldGen } == true },
                "\(leave): the agent still believes generation \(oldGen) is composing: \(String(describing: link.agent.snapshot.lastComposition))")

            let dropsBefore = notCurrentDrops()
            push(oldGen)
            #expect(poll { notCurrentDrops() > dropsBefore || suggestions.count(for: oldGen) > 0 }, "\(leave)")
            #expect(suggestions.count(for: oldGen) == 0, "\(leave): a late suggestion for generation \(oldGen) was delivered")
            #expect(notCurrentDrops() == dropsBefore + 1, "\(leave)")

            // The next live composition still receives its suggestion.
            let liveGen = typeNi(token: other.token, client: other.client)
            push(liveGen)
            #expect(poll { suggestions.count(for: liveGen) == 1 }, "\(leave)")
            harness.coordinator.deactivate(token: other.token)
        }
        #expect(link.manager.state == .healthy)
    }

    /// Secure input drops the composition without one IPC frame leaving the IME, yet the
    /// local gate forgets it: a late suggestion for it is dropped as `.notCurrentComposition`.
    @Test func secureInputDropInvalidatesTheLocalGateSilently() throws {
        let secure = SecureFlag()
        let harness = try Harness(isSecureInputEnabled: { secure.isOn })
        defer { harness.shutdown() }
        let server = InMemoryServerTransport()
        let agent = AgentServiceCoordinator(transport: server, agentVersion: "1.0.0-test")
        agent.start()
        let manager = IPCConnectionManager(
            transport: InMemoryClientTransport(server: server, clock: ManualIPCClock()),
            client: .init(bundleID: NoemaPaths.imeBundleID, version: "0.0.0-test"),
            policy: .init(heartbeatInterval: nil), clock: ManualIPCClock(), readyNotificationName: nil)
        defer { manager.stop() }
        let reporter = CompositionIPCReporter(manager: manager, isSecureInputEnabled: { secure.isOn })
        harness.coordinator.onCompositionChange = { reporter.report($0) }
        let suggestions = SuggestionRecorder()
        manager.setMessageHandler { suggestions.record($0) }
        func settle() { for _ in 0..<12 { manager.sync {} } }
        manager.start()
        settle()
        try #require(manager.state == .healthy)

        let client = RecordingClient()
        let token = UUID()
        for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
        settle()
        let oldGen = harness.engine.currentState.generationID
        #expect(manager.gate.currentCompositionGenerationID == oldGen)
        let framesBefore = server.receivedFrames.count

        secure.isOn = true
        #expect(!harness.coordinator.handleKey(.text("h"), token: token, client: client))
        settle()
        #expect(!harness.engine.currentState.isComposing, "the secure key dropped the composition")
        #expect(server.receivedFrames.count == framesBefore, "an IPC frame left the IME under secure input")
        #expect(reporter.suppressedForSecureInput == 1)
        #expect(manager.gate.currentCompositionGenerationID == nil, "the local gate still holds generation \(oldGen)")

        agent.pushSuggestion(AISuggestionMessage(sessionEpoch: manager.sessionEpoch, generationID: oldGen, suggestion: "late", provider: "test"))
        settle()
        #expect(suggestions.count(for: oldGen) == 0, "a late suggestion for the dropped composition was delivered")
        #expect(manager.statistics.gateDrops[.notCurrentComposition] == 1)
        #expect(server.receivedFrames.count == framesBefore)
    }
}

/// AI suggestions the manager delivered, by generation.
final class SuggestionRecorder: @unchecked Sendable {
    private let generations = OSAllocatedUnfairLock<[UInt64]>(initialState: [])

    func record(_ message: AgentToIME) {
        if case .aiSuggestion(let suggestion) = message { generations.withLock { $0.append(suggestion.generationID) } }
    }

    func count(for generation: UInt64) -> Int { generations.withLock { $0.filter { $0 == generation }.count } }
}

/// The secure-input flag both the main-actor coordinator and the manager's queue read.
final class SecureFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isOn: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Polls `condition` every 5 ms for up to `timeout`.
@MainActor
func poll(timeout: Duration = .seconds(5), _ condition: () -> Bool) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

/// A real libxpc agent on an anonymous listener and the IME-side manager dialing it.
final class AgentLink: @unchecked Sendable {
    let policy: PeerIdentityPolicy
    private(set) var server: XPCListenerServerTransport
    private(set) var agent: AgentServiceCoordinator
    private let target: OSAllocatedUnfairLock<XPCConnectionTarget?>
    let manager: IPCConnectionManager
    let recorder = ConnectionRecorder()

    init(readyNotificationName: String) throws {
        // The test runner by signing identifier (it is Apple platform code, for which
        // libxpc Team ID requirements never match).
        let identifier = try #require(SelfCodeIdentity.current()?.signingIdentifier)
        policy = .allowAdHocForTesting(signingIdentifiers: [identifier])
        let (server, agent) = try Self.makeAgent(policy: policy)
        (self.server, self.agent) = (server, agent)
        let target = OSAllocatedUnfairLock<XPCConnectionTarget?>(initialState: server.endpoint.map(XPCConnectionTarget.endpoint))
        self.target = target
        let queue = DispatchQueue(label: "dev.noema.tests.ime-ipc")
        let transport = XPCClientTransport(policy: policy, queue: queue) { target.withLock { $0 } }
        manager = IPCConnectionManager(
            transport: transport, client: .init(bundleID: NoemaPaths.imeBundleID, version: "0.0.0-test"),
            policy: .init(
                baseDelay: .milliseconds(10), maxDelay: .milliseconds(50), jitterFraction: 0, circuitBreakerThreshold: 3,
                circuitCooldown: .seconds(60), handshakeTimeout: .seconds(1), heartbeatInterval: nil),
            jitter: FixedJitter(fraction: 0), readyNotificationName: readyNotificationName, queue: queue)
        let recorder = recorder
        manager.setStateObserver { recorder.record($0) }
    }

    static func makeAgent(policy: PeerIdentityPolicy) throws -> (XPCListenerServerTransport, AgentServiceCoordinator) {
        let server = XPCListenerServerTransport(mode: .anonymous, policy: policy)
        let agent = AgentServiceCoordinator(transport: server, agentVersion: "1.0.0-test")
        try #require(agent.start() == .listening)
        return (server, agent)
    }

    /// The agent process dying: the listener and every peer session are cancelled.
    func killAgent() { agent.stop() }

    func restartAgent() throws {
        (server, agent) = try Self.makeAgent(policy: policy)
        let new = server.endpoint.map(XPCConnectionTarget.endpoint)
        target.withLock { $0 = new }
    }

    func shutdown() {
        manager.stop()
        agent.stop()
    }
}

final class ConnectionRecorder: @unchecked Sendable {
    private let states = OSAllocatedUnfairLock<[IPCConnectionState]>(initialState: [])

    func record(_ state: IPCConnectionState) { states.withLock { $0.append(state) } }

    var shape: [String] {
        states.withLock { $0 }.map { state in
            switch state {
            case .idle: "idle"
            case .connecting(let attempt): "connecting(\(attempt))"
            case .healthy: "healthy"
            case .degraded(let reason): "degraded(\(reason.rawValue))"
            case .reconnecting(let attempt, _): "reconnecting(\(attempt))"
            case .circuitOpen(let failures, _): "circuitOpen(\(failures))"
            }
        }
    }
}
