import AppKit
import Foundation
import NoemaCore
@testable import NoemaAgentCore
@testable import NoemaIPC
import os
import Testing

/// v-mode's agent side: `ime.quickActionRequested` on the wire and through the real
/// `IPCConnectionManager` → `AgentServiceCoordinator` path, the `emojiCandidatesEnabled`
/// setting, and the non-activating "coming soon" toast.
@Suite struct QuickActionIPCTests {
    @Test func quickActionRequestedRoundTripsAndIsStamped() throws {
        let epoch = UUID()
        for action in QuickActionID.allCases {
            let message = IMEToAgent.quickActionRequested(sessionEpoch: epoch, action: action)
            #expect(message.kind == "ime.quickActionRequested" && message.sessionEpoch == epoch)
            #expect(!message.isLatestWins, "every request reaches the agent")
            let frame = try IPCWireCodec.encode(IPCEnvelope(sequence: 3, message: message, generationID: nil))
            let json = String(decoding: frame, as: UTF8.self)
            #expect(json.contains("\"kind\":\"ime.quickActionRequested\"") && json.contains("\"action\":\"\(action.rawValue)\""))
            let decoded = try IPCWireCodec.decode(IMEToAgent.self, from: frame)
            #expect(decoded.payload == message && decoded.isConsistent)
            let other = UUID()
            #expect(message.stamped(epoch: other) == .quickActionRequested(sessionEpoch: other, action: action))
        }
        let unknown = #"{"version":1,"sequence":1,"kind":"ime.quickActionRequested","payload":{"kind":"ime.quickActionRequested","sessionEpoch":"\#(epoch.uuidString)","action":"teleport"}}"#
        #expect(throws: (any Error).self) { try IPCWireCodec.decode(IMEToAgent.self, from: Data(unknown.utf8)) }
    }

    /// `emojiCandidatesEnabled` is appended to v1: a frame without it decodes as true.
    @Test func emojiCandidatesEnabledIsOptionalOnTheWire() throws {
        let legacy = #"{"inlinePreeditDisabledBundleIDs":[],"panelBackdropPreference":"glass","aiSuggestionsEnabled":false}"#
        let decoded = try JSONDecoder().decode(AgentSettingsSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.emojiCandidatesEnabled && decoded == .defaults)
        let off = AgentSettingsSnapshot(emojiCandidatesEnabled: false)
        let data = try JSONEncoder().encode(off)
        #expect(String(decoding: data, as: UTF8.self).contains("\"emojiCandidatesEnabled\":false"))
        #expect(try JSONDecoder().decode(AgentSettingsSnapshot.self, from: data) == off)
    }

    /// The agent records a request only on the peer's own epoch and calls back outside its lock.
    @Test func coordinatorHandlesQuickActionsOnItsEpochOnly() throws {
        let server = InMemoryServerTransport()
        let requested = OSAllocatedUnfairLock<[QuickActionID]>(initialState: [])
        let agent = AgentServiceCoordinator(transport: server, agentVersion: "2.0.0", onQuickAction: { action in
            requested.withLock { $0.append(action) }
        })
        #expect(agent.start() == .listening)
        let client = InMemoryClientTransport(server: server)
        try client.connect(attemptID: 1) { _, _ in }
        func send(_ message: IMEToAgent) throws {
            try client.send(IPCWireCodec.encode(IPCEnvelope(sequence: 1, message: message, generationID: nil)), expectingReply: false)
        }
        let epoch = UUID()
        try send(.quickActionRequested(sessionEpoch: epoch, action: .translate))
        #expect(agent.snapshot.quickActionCount == 0, "before hello no epoch is known")
        try send(.hello(IMEHello(clientBundleID: NoemaPaths.imeBundleID, clientVersion: "0.1.0", sessionEpoch: epoch, engineMode: "rime")))
        try send(.quickActionRequested(sessionEpoch: epoch, action: .clipboard))
        try send(.quickActionRequested(sessionEpoch: UUID(), action: .rewrite))
        try send(.quickActionRequested(sessionEpoch: epoch, action: .settings))
        #expect(agent.snapshot.lastQuickAction == .settings && agent.snapshot.quickActionCount == 2)
        #expect(requested.withLock { $0 } == [.clipboard, .settings])
        client.disconnect(reason: "done")
        agent.stop()
    }

    /// Through the real manager: a request reaches the agent stamped with the connection
    /// epoch; under secure input the reporter sends nothing at all.
    @MainActor
    @Test func reporterSendsQuickActionsExceptUnderSecureInput() {
        let rig = InMemoryRig()
        rig.startHealthy()
        let reporter = CompositionIPCReporter(manager: rig.manager, isSecureInputEnabled: { [secure = rig.secure] in secure.isOn })
        reporter.requestQuickAction(.voiceInput)
        rig.settle()
        #expect(rig.agent.snapshot.lastQuickAction == .voiceInput && rig.agent.snapshot.quickActionCount == 1)
        #expect(rig.receivedKinds.last == "ime.quickActionRequested")

        let frames = rig.server.receivedFrames.count
        rig.secure.isOn = true
        reporter.requestQuickAction(.clipboard)
        rig.settle()
        #expect(rig.server.receivedFrames.count == frames, "no frame under secure input")
        #expect(reporter.suppressedForSecureInput == 1 && rig.agent.snapshot.quickActionCount == 1)

        // The manager's own barrier: a request queued by another producer is withheld too.
        rig.manager.sendFireAndForget(.quickActionRequested(sessionEpoch: IPCConnectionManager.unstampedEpoch, action: .rewrite))
        rig.settle()
        #expect(rig.server.receivedFrames.count == frames && rig.agent.snapshot.lastQuickAction == .voiceInput)
    }

    @MainActor
    @Test func toastNeverTakesFocusAndNamesTheMilestone() async throws {
        #expect(QuickActionToastController.message(for: .clipboard) == "剪贴板将在 M3 推出")
        #expect(QuickActionToastController.message(for: .voiceInput) == "语音输入将在 M3 推出")
        #expect(QuickActionToastController.message(for: .translate) == "翻译将在 M4 推出")
        #expect(QuickActionToastController.message(for: .rewrite) == "改写将在 M4 推出")
        let toast = QuickActionToastController()
        toast.shouldOrderFront = false
        let panel = toast.panelForTesting
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel) && panel.ignoresMouseEvents && !panel.hidesOnDeactivate)
        toast.show(.clipboard)
        #expect(toast.isVisible && toast.message == "剪贴板将在 M3 推出")
        toast.show(.translate)
        #expect(toast.message == "翻译将在 M4 推出")
        toast.dismiss()
        #expect(!toast.isVisible && !panel.isKeyWindow)
    }
}
