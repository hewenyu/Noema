import Foundation
import NoemaCore
@testable import NoemaIPC
import Testing
import XPC

@Suite struct WireFormatTests {
    struct Ping: Codable, Sendable, Equatable { let text: String }

    @Test func v1EnvelopeWithoutGenerationDecodes() throws {
        let json = #"{"version":1,"sequence":1,"kind":"test.ping","payload":{"text":"hi"}}"#
        let envelope = try IPCWireCodec.decode(Ping.self, from: Data(json.utf8))
        #expect(envelope.generationID == nil && envelope.sequence == 1 && envelope.payload == Ping(text: "hi"))
        // Encoding without a generation omits the key, so older readers see the same JSON.
        let encoded = try IPCWireCodec.encode(envelope)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("generationID"))
        let withGeneration = IPCEnvelope(sequence: 2, kind: "test.ping", payload: Ping(text: "x"), generationID: 7)
        #expect(try IPCWireCodec.decode(Ping.self, from: IPCWireCodec.encode(withGeneration)) == withGeneration)
    }

    @Test func unsupportedVersionIsRejected() {
        let json = #"{"version":2,"sequence":1,"kind":"ime.hello","payload":{}}"#
        #expect(throws: IPCError.unsupportedVersion(found: 2)) {
            try IPCWireCodec.decode(IMEToAgent.self, from: Data(json.utf8))
        }
    }

    @Test func everyMessageRoundTrips() throws {
        let epoch = UUID()
        let settings = AgentSettingsSnapshot(inlinePreeditDisabledBundleIDs: ["com.example"], panelBackdropPreference: "visualEffect", aiSuggestionsEnabled: true)
        let ime: [IMEToAgent] = [
            .hello(IMEHello(clientBundleID: NoemaPaths.imeBundleID, clientVersion: "1.2.3", sessionEpoch: epoch, engineMode: "rime")),
            .heartbeat(sessionEpoch: epoch),
            .compositionStateChanged(CompositionSnapshot(sessionEpoch: epoch, generationID: 9, isComposing: true, candidateCount: 5, isASCIIMode: false)),
            .openSettingsRequested(section: .quickActions),
            .openSettingsRequested(section: nil),
        ]
        for (index, message) in ime.enumerated() {
            let envelope = IPCEnvelope(sequence: UInt64(index), message: message, generationID: UInt64(index))
            let decoded = try IPCWireCodec.decode(IMEToAgent.self, from: IPCWireCodec.encode(envelope))
            #expect(decoded == envelope && decoded.isConsistent)
        }
        let agent: [AgentToIME] = [
            .helloAck(AgentHelloAck(agentVersion: "1.0.0", sessionEpoch: epoch, settings: settings)),
            .heartbeatAck(sessionEpoch: epoch),
            .settingsSnapshot(sessionEpoch: epoch, settings: settings),
            .aiSuggestion(AISuggestionMessage(sessionEpoch: epoch, generationID: 3, suggestion: "建议", provider: "test")),
        ]
        for (index, message) in agent.enumerated() {
            let envelope = IPCEnvelope(sequence: UInt64(index), message: message, generationID: 3)
            #expect(try IPCWireCodec.decode(AgentToIME.self, from: IPCWireCodec.encode(envelope)) == envelope)
        }
        #expect(Set(ime.map(\.kind)).count == 4 && Set(agent.map(\.kind)).count == 4)
    }

    /// `settingsRevision` is append-only: a v1 frame without it decodes as revision 0.
    @Test func settingsRevisionIsOptionalOnTheWire() throws {
        let epoch = UUID()
        func strip(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.filter { $0.key != "settingsRevision" }.mapValues(strip)
            }
            return value
        }
        for message: AgentToIME in [
            .helloAck(AgentHelloAck(agentVersion: "1.0.0", sessionEpoch: epoch, settings: .defaults, settingsRevision: 7)),
            .settingsSnapshot(sessionEpoch: epoch, settings: .defaults, revision: 7),
        ] {
            let frame = try IPCWireCodec.encode(IPCEnvelope(sequence: 1, message: message, generationID: 1))
            #expect(String(decoding: frame, as: UTF8.self).contains("\"settingsRevision\":7"))
            let legacy = try JSONSerialization.data(withJSONObject: strip(try JSONSerialization.jsonObject(with: frame)))
            #expect(!String(decoding: legacy, as: UTF8.self).contains("settingsRevision"))
            switch try IPCWireCodec.decode(AgentToIME.self, from: legacy).payload {
            case .helloAck(let ack): #expect(ack.settingsRevision == 0 && ack.sessionEpoch == epoch)
            case .settingsSnapshot(_, _, let revision): #expect(revision == 0)
            default: Issue.record("unexpected payload")
            }
        }
    }

    @Test func unknownKindIsMalformed() {
        let json = #"{"version":1,"sequence":1,"kind":"ime.future","payload":{"kind":"ime.future"}}"#
        #expect(throws: IPCError.malformedFrame) { try IPCWireCodec.decode(IMEToAgent.self, from: Data(json.utf8)) }
        #expect(throws: IPCError.malformedFrame) { try IPCWireCodec.decode(IMEToAgent.self, from: Data("not json".utf8)) }
    }

    /// A frame over the cap fails with `payloadTooLarge`, not `malformedFrame`: the size is
    /// checked before `JSONDecoder` reads it (these bytes are not JSON at all).
    @Test func oversizedFramesAreRejectedBeforeDecoding() throws {
        let limit = IPCWireLimits.maxPayloadBytes
        #expect(limit == 256 * 1024)
        let garbage = Data(repeating: 0x7B, count: limit + 1)
        #expect(throws: IPCError.payloadTooLarge(bytes: limit + 1, limit: limit)) {
            try IPCWireCodec.decode(IMEToAgent.self, from: garbage)
        }
        let huge = AISuggestionMessage(sessionEpoch: UUID(), generationID: 1, suggestion: String(repeating: "字", count: limit), provider: "x")
        #expect(throws: IPCError.self) {
            try IPCWireCodec.encode(IPCEnvelope(sequence: 1, message: AgentToIME.aiSuggestion(huge), generationID: 1))
        }
        // XPC framing: an oversized "e" is refused when read and when written.
        let dictionary = xpc_dictionary_create_empty()
        garbage.withUnsafeBytes { xpc_dictionary_set_data(dictionary, XPCFraming.envelopeKey, $0.baseAddress!, $0.count) }
        #expect(XPCFraming.frame(of: dictionary) == .failure(.payloadTooLarge(bytes: limit + 1, limit: limit)))
        #expect(throws: IPCError.payloadTooLarge(bytes: limit + 1, limit: limit)) { try XPCFraming.message(carrying: garbage) }
        #expect(XPCFraming.frame(of: xpc_dictionary_create_empty()) == .failure(.malformedFrame))
        let ok = try XPCFraming.message(carrying: Data("{}".utf8))
        #expect(ok.withUnsafeUnderlyingDictionary { XPCFraming.frame(of: $0) } == .success(Data("{}".utf8)))
    }
}

@Suite struct GenerationGateTests {
    let epoch = UUID()

    func envelope(_ message: AgentToIME, _ generation: UInt64?) -> IPCEnvelope<AgentToIME> {
        IPCEnvelope(sequence: 1, message: message, generationID: generation)
    }

    @Test func dropsPriorEpochStaleAndDuplicateGenerations() {
        var gate = GenerationGate(sessionEpoch: epoch)
        let settings = AgentSettingsSnapshot.defaults
        #expect(gate.admit(envelope(.settingsSnapshot(sessionEpoch: epoch, settings: settings), 5)) == .accept)
        #expect(gate.admit(envelope(.settingsSnapshot(sessionEpoch: epoch, settings: settings), 4)) == .stale)
        #expect(gate.admit(envelope(.settingsSnapshot(sessionEpoch: epoch, settings: settings), 5)) == .duplicate)
        #expect(gate.admit(envelope(.settingsSnapshot(sessionEpoch: UUID(), settings: settings), 9)) == .epochMismatch)
        #expect(gate.admit(envelope(.settingsSnapshot(sessionEpoch: epoch, settings: settings), nil)) == .missingGeneration)
        #expect(gate.admit(envelope(.settingsSnapshot(sessionEpoch: epoch, settings: settings), 6)) == .accept)
        // Watermarks are per kind.
        #expect(gate.admit(envelope(.heartbeatAck(sessionEpoch: epoch), 1)) == .accept)
        #expect(gate.droppedCount == 4)
        #expect(gate.drops == [.stale: 1, .duplicate: 1, .epochMismatch: 1, .missingGeneration: 1])

        // A new connection: the old epoch is now foreign, watermarks start over.
        let next = UUID()
        gate.reset(sessionEpoch: next)
        #expect(gate.admit(envelope(.heartbeatAck(sessionEpoch: epoch), 2)) == .epochMismatch)
        #expect(gate.admit(envelope(.heartbeatAck(sessionEpoch: next), 1)) == .accept)
    }

    @Test func aiSuggestionsOnlyForTheCurrentComposition() {
        var gate = GenerationGate(sessionEpoch: epoch)
        func suggestion(_ generation: UInt64) -> IPCEnvelope<AgentToIME> {
            envelope(.aiSuggestion(AISuggestionMessage(sessionEpoch: epoch, generationID: generation, suggestion: "s", provider: "p")), generation)
        }
        #expect(gate.admit(suggestion(1)) == .notCurrentComposition, "no composition yet")
        gate.noteComposition(generationID: 10)
        #expect(gate.admit(suggestion(9)) == .notCurrentComposition)
        #expect(gate.admit(suggestion(10)) == .accept)
        #expect(gate.admit(suggestion(10)) == .duplicate)
        gate.noteComposition(generationID: 11)
        #expect(gate.admit(suggestion(10)) == .duplicate)
        #expect(gate.admit(suggestion(12)) == .notCurrentComposition, "ahead of the composition")
        #expect(gate.admit(suggestion(11)) == .accept)
        // The envelope generation must agree with the suggestion's.
        let mismatched = envelope(.aiSuggestion(AISuggestionMessage(sessionEpoch: epoch, generationID: 11, suggestion: "s", provider: "p")), 3)
        #expect(gate.admit(mismatched) == .stale)
    }

    @Test func backoffDoublesAndCaps() {
        let policy = IPCReconnectPolicy(baseDelay: .milliseconds(100), maxDelay: .milliseconds(1000))
        #expect((1...6).map { policy.backoff(afterFailures: $0) } == [
            .milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800), .milliseconds(1000), .milliseconds(1000),
        ])
        #expect(policy.readyDebounce >= .milliseconds(100))
        #expect(IPCReconnectPolicy(readyDebounce: .milliseconds(1)).readyDebounce == .milliseconds(100))
    }
}
