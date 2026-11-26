import Darwin
import Foundation
import NoemaAgentCore
import NoemaCore
@testable import NoemaIPC
import NoemaLearning
import NoemaLexiconAdmin
import os
import Testing

/// The schema-set switch messages (appended to v1), the agent coordinator that sends and
/// tracks them over the real `IPCConnectionManager`, and the Settings "词库" model.
@Suite struct SchemaSwitchIPCTests {
    @Test func settingsSectionsAreAppendOnly() throws {
        #expect(SettingsSectionID.allCases.map(\.rawValue) == ["general", "quickActions", "other", "lexicon"])
        let json = try JSONEncoder().encode(IMEToAgent.openSettingsRequested(section: .lexicon))
        #expect(try JSONDecoder().decode(IMEToAgent.self, from: json) == .openSettingsRequested(section: .lexicon))
        #expect(SettingsSectionID.lexicon.title == "词库")
    }

    @Test func switchMessagesRoundTripAndStampTheirEpoch() throws {
        let epoch = UUID()
        let request = SchemaSetSwitchRequest(schemaSetID: .rimeIce, schemaID: "rime_ice")
        let status = SchemaSetSwitchStatus(requestID: request.requestID, schemaSetID: .rimeIce, phase: .failed, detail: "why")
        let toIME = IPCEnvelope(sequence: 4, message: AgentToIME.switchSchemaSet(sessionEpoch: epoch, request: request), generationID: 2)
        let decoded = try IPCWireCodec.decode(AgentToIME.self, from: IPCWireCodec.encode(toIME))
        #expect(decoded == toIME && decoded.isConsistent && decoded.kind == "agent.switchSchemaSet")
        #expect(decoded.payload.sessionEpoch == epoch)
        let toAgent = IPCEnvelope(sequence: 5, message: IMEToAgent.schemaSwitchStatus(sessionEpoch: epoch, status: status), generationID: nil)
        let back = try IPCWireCodec.decode(IMEToAgent.self, from: IPCWireCodec.encode(toAgent))
        #expect(back == toAgent && back.kind == "ime.schemaSwitchStatus" && back.payload.sessionEpoch == epoch)
        // The wire names: schema set raw values, phases, and a request without a schema.
        let text = String(decoding: try JSONEncoder().encode(toAgent), as: UTF8.self)
        #expect(text.contains("\"rime-ice\"") && text.contains("\"failed\""))
        let bare = #"{"kind":"agent.switchSchemaSet","sessionEpoch":"\#(epoch.uuidString)","request":{"requestID":"\#(request.requestID.uuidString)","schemaSetID":"mint"}}"#
        #expect(try JSONDecoder().decode(AgentToIME.self, from: Data(bare.utf8))
            == .switchSchemaSet(sessionEpoch: epoch, request: SchemaSetSwitchRequest(requestID: request.requestID, schemaSetID: .mint)))
        let unknownSet = bare.replacingOccurrences(of: "\"mint\"", with: "\"sogou\"")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentToIME.self, from: Data(unknownSet.utf8)) }
        // The epoch is replaced when the outbox drains; the status is not latest-wins.
        let stamped = IMEToAgent.schemaSwitchStatus(sessionEpoch: UUID(), status: status).stamped(epoch: epoch)
        #expect(stamped == .schemaSwitchStatus(sessionEpoch: epoch, status: status))
        #expect(!stamped.isLatestWins)
    }

    /// Agent -> IME: `requestSchemaSetSwitch` reaches the real manager's message handler
    /// once; the gate drops a repeated generation and a foreign epoch. IME -> agent: every
    /// phase is recorded on the IME's epoch, and a status on another epoch is ignored.
    @Test func coordinatorSendsSwitchesAndTracksStatusThroughTheManager() throws {
        let server = InMemoryServerTransport()
        let agent = AgentServiceCoordinator(transport: server, agentVersion: "1.0.0-test")
        agent.start()
        let clock = ManualIPCClock()
        let manager = IPCConnectionManager(
            transport: InMemoryClientTransport(server: server, clock: clock),
            client: .init(bundleID: NoemaPaths.imeBundleID, version: "0.0.0-test"),
            policy: .init(heartbeatInterval: nil), clock: clock, readyNotificationName: nil)
        defer { manager.stop() }
        let recorder = StateRecorder()
        recorder.attach(to: manager)
        func settle() { for _ in 0..<12 { manager.sync {} } }
        manager.start()
        settle()
        try #require(manager.state == .healthy)

        let requestID = agent.requestSchemaSetSwitch(schemaSetID: .wanxiang, schemaID: "wanxiang_fixture")
        settle()
        #expect(agent.snapshot.lastSchemaSwitchRecipients == 1)
        let switches = recorder.received.compactMap { message -> SchemaSetSwitchRequest? in
            if case .switchSchemaSet(_, let request) = message { return request }
            return nil
        }
        #expect(switches == [SchemaSetSwitchRequest(requestID: requestID, schemaSetID: .wanxiang, schemaID: "wanxiang_fixture")])
        #expect(manager.gate.watermarks[AgentToIME.switchSchemaSetKind] == 1)

        // A replayed generation and a previous connection's epoch never reach the handler.
        let replay = AgentToIME.switchSchemaSet(sessionEpoch: manager.sessionEpoch, request: switches[0])
        var gate = manager.gate
        #expect(gate.admit(IPCEnvelope(sequence: 9, message: replay, generationID: 1)) == GenerationGate.Decision.duplicate)
        let foreign = AgentToIME.switchSchemaSet(sessionEpoch: UUID(), request: switches[0])
        #expect(gate.admit(IPCEnvelope(sequence: 9, message: foreign, generationID: 5)) == GenerationGate.Decision.epochMismatch)

        // A second request gets the next generation.
        let second = agent.requestSchemaSetSwitch(schemaSetID: .builtin)
        settle()
        #expect(second != requestID && manager.gate.watermarks[AgentToIME.switchSchemaSetKind] == 2)

        for phase in [SchemaSwitchPhase.pendingIdle, .compiling, .ready] {
            manager.reportSchemaSwitch(SchemaSetSwitchStatus(requestID: second, schemaSetID: .builtin, phase: phase))
            settle()
            #expect(agent.snapshot.lastSchemaSwitchStatus?.phase == phase)
        }
        #expect(agent.snapshot.lastSchemaSwitchStatus?.requestID == second)
    }

    /// A status naming another epoch than the peer's hello is dropped.
    @Test func statusOnAnotherEpochIsIgnored() throws {
        let server = InMemoryServerTransport()
        let agent = AgentServiceCoordinator(transport: server, agentVersion: "1.0.0-test")
        agent.start()
        let client = InMemoryClientTransport(server: server)
        try client.connect(attemptID: 1) { _, _ in }
        let epoch = UUID()
        func send(_ message: IMEToAgent) throws {
            try client.send(IPCWireCodec.encode(IPCEnvelope(sequence: 1, message: message, generationID: nil)), expectingReply: false)
        }
        try send(.hello(IMEHello(clientBundleID: NoemaPaths.imeBundleID, clientVersion: "0", sessionEpoch: epoch, engineMode: "rime")))
        let status = SchemaSetSwitchStatus(requestID: UUID(), schemaSetID: .mint, phase: .ready)
        try send(.schemaSwitchStatus(sessionEpoch: UUID(), status: status))
        #expect(agent.snapshot.lastSchemaSwitchStatus == nil)
        try send(.schemaSwitchStatus(sessionEpoch: epoch, status: status))
        #expect(agent.snapshot.lastSchemaSwitchStatus == status)
        client.disconnect(reason: "done")
    }

    /// The "词库" model scans the real inventory (dictionaries and sizes, the learning store
    /// through a read-only connection, the active record), never writes `learning.sqlite`,
    /// and only sends a switch to an installed set.
    @MainActor
    @Test func lexiconControllerReadsTheInventoryAndSendsSwitches() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "noema-lexicon-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let builtin = root.appending(path: "builtin")
        let iceSchemas = NoemaPaths.downloadedSchemaDir(.rimeIce, root: root)
        try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iceSchemas.appending(path: "cn_dicts"), withIntermediateDirectories: true)
        try "x".write(to: builtin.appending(path: "default.yaml"), atomically: true, encoding: .utf8)
        try String(repeating: "a", count: 1234).write(to: builtin.appending(path: "noema_pinyin.dict.yaml"), atomically: true, encoding: .utf8)
        try "x".write(to: iceSchemas.appending(path: "default.yaml"), atomically: true, encoding: .utf8)
        try "x".write(to: iceSchemas.appending(path: "rime_ice.schema.yaml"), atomically: true, encoding: .utf8)
        try String(repeating: "b", count: 4321).write(to: iceSchemas.appending(path: "cn_dicts/8105.dict.yaml"), atomically: true, encoding: .utf8)
        // A mint directory without its schema is not installed.
        try FileManager.default.createDirectory(at: NoemaPaths.downloadedSchemaDir(.mint, root: root), withIntermediateDirectories: true)
        let storeURL = NoemaPaths.learningStoreURL(root: root)
        do {
            let store = try LearningStore(url: storeURL)
            #expect(try store.recordBatch([
                LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "你好"),
                LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "你好"),
                LearningCommitEvent(rawInput: "shijie", preedit: "shi jie", text: "世界"),
            ]) == 3)
            try store.setWatermark(for: .rimeIce, dictName: "rime_ice", lastRevision: 2, projectedCount: 2)
            store.close()
        }
        try ActiveSchemaSetRecord(schemaSetID: .rimeIce, schemaID: "rime_ice").save(to: NoemaPaths.activeSchemaSetURL(root: root))
        let before = try sidecarDigests(storeURL)

        let sent = OSAllocatedUnfairLock<[(SchemaSetID, String?)]>(initialState: [])
        let controller = LexiconController(
            root: root, builtinSharedDataDir: builtin,
            lockfileURL: Self.repository.appending(path: "vendor/dictionaries.lock.json"),
            requestSwitch: { set, schema in
                sent.withLock { $0.append((set, schema)) }
                return (UUID(), 1)
            })
        await controller.refresh()
        #expect(controller.activeSchemaSetID == .rimeIce)
        #expect(controller.installedSets == [.builtin, .rimeIce])
        #expect(controller.lockfile?.entry(for: .wanxiang) != nil && controller.lockfileError == nil)
        let dictionaries = try #require(controller.inventory?.dictionaries)
        #expect(dictionaries.contains { $0.schemaSetID == .rimeIce && $0.relativePath == "cn_dicts/8105.dict.yaml" && $0.byteSize == 4321 })
        #expect(dictionaries.contains { $0.schemaSetID == .builtin && $0.relativePath == "noema_pinyin.dict.yaml" && $0.byteSize == 1234 })
        let stats = try #require(controller.inventory?.learning)
        #expect(stats.entryCount == 2 && stats.totalFrequency == 3)
        #expect(stats.watermarks.map { "\($0.schemaSet)/\($0.dictName)" } == ["rime-ice/rime_ice"])
        let after = try sidecarDigests(storeURL)
        #expect(after[""] == before[""], "the agent wrote learning.sqlite: \(before.keys.sorted()) -> \(after.keys.sorted())")
        #expect(after["-wal"].map(\.isEmpty) ?? true, "the agent left WAL frames: \(after["-wal"]?.count ?? 0) bytes")

        #expect(controller.switchTo(schemaSetID: .mint) == nil)
        #expect(controller.lastSwitchError != nil)
        #expect(controller.switchTo(schemaSetID: .builtin) != nil && controller.lastSwitchError == nil)
        #expect(sent.withLock { $0.map(\.0) } == [.builtin])

        // The latest status of this controller's own request is the one shown.
        var service = AgentServiceSnapshot()
        let mine = try #require(controller.lastRequest?.requestID)
        service.lastSchemaSwitchStatus = SchemaSetSwitchStatus(requestID: UUID(), schemaSetID: .mint, phase: .ready)
        #expect(controller.switchStatus(in: service) == nil)
        service.lastSchemaSwitchStatus = SchemaSetSwitchStatus(requestID: mine, schemaSetID: .builtin, phase: .compiling)
        #expect(controller.switchStatus(in: service)?.phase == .compiling)

        // No IME connected: the request is reported as not sent.
        let offline = LexiconController(root: root, builtinSharedDataDir: builtin, lockfileURL: nil, requestSwitch: { _, _ in (UUID(), 0) })
        await offline.refresh()
        #expect(offline.lockfileError != nil)
        #expect(offline.switchTo(schemaSetID: .rimeIce) == nil && offline.lastSwitchError != nil)
    }

    static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The bytes of the store and its WAL sidecars that exist.
    private func sidecarDigests(_ url: URL) throws -> [String: Data] {
        var digests: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if let data = FileManager.default.contents(atPath: path) { digests[suffix] = data }
        }
        return digests
    }
}
