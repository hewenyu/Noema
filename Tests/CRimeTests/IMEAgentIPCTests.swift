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
        /// keys, commits, panel clicks, mode switches, and direct reports are all silent.
        @Test func secureInputEmitsZeroIPCMessages() throws {
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
            #expect(server.receivedFrames.count == framesBefore, "an IPC frame left the IME under secure input")
            #expect(reporter.suppressedForSecureInput == 2)
            #expect(manager.state == .healthy)

            secure.isOn = false
            harness.engine.setASCIIMode(false)
            _ = harness.coordinator.handleKey(.text("a"), token: token, client: client)
            settle()
            #expect(server.receivedFrames.count > framesBefore, "reports resume once secure input ends")
        }
    }
}

@MainActor
final class SecureFlag {
    var isOn = false
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
    private let endpoint: OSAllocatedUnfairLock<XPCEndpoint?>
    let manager: IPCConnectionManager
    let recorder = ConnectionRecorder()

    init(readyNotificationName: String) throws {
        // The test runner by signing identifier (it is Apple platform code, for which
        // libxpc Team ID requirements never match).
        let identifier = try #require(SelfCodeIdentity.current()?.signingIdentifier)
        policy = .allowAdHocForTesting(signingIdentifiers: [identifier])
        let (server, agent) = try Self.makeAgent(policy: policy)
        (self.server, self.agent) = (server, agent)
        let endpoint = OSAllocatedUnfairLock<XPCEndpoint?>(initialState: server.endpoint)
        self.endpoint = endpoint
        let queue = DispatchQueue(label: "dev.noema.tests.ime-ipc")
        let transport = XPCClientTransport(policy: policy, queue: queue) { endpoint.withLock { $0 }.map { .endpoint($0) } }
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
        let new = server.endpoint
        endpoint.withLock { $0 = new }
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
