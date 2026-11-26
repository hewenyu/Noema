import Foundation

// The v1 message families between `NoemaIME` and `NoemaAgent`. Every message travels as
// the payload of an `IPCEnvelope` whose `kind` is the message's `kind`. Kinds and field
// names are stable once released; new messages and optional fields are append-only.
//
// Privacy: nothing here carries user text. `CompositionSnapshot` is metadata only
// (counts and flags), and `NoemaIME` sends no message at all while secure input is on.

/// A Settings window section, shared so the IME can ask the agent to open one.
public enum SettingsSectionID: String, Codable, Sendable, Hashable, CaseIterable {
    case general
    case quickActions
    case other
}

/// The agent-owned settings the IME reads. Sent in `helloAck` and on every change.
public struct AgentSettingsSnapshot: Codable, Sendable, Hashable {
    public var inlinePreeditDisabledBundleIDs: [String]
    /// `CandidatePanelBackdrop` raw value (`glass` or `visualEffect`).
    public var panelBackdropPreference: String
    public var aiSuggestionsEnabled: Bool

    public init(inlinePreeditDisabledBundleIDs: [String] = [], panelBackdropPreference: String = "glass", aiSuggestionsEnabled: Bool = false) {
        self.inlinePreeditDisabledBundleIDs = inlinePreeditDisabledBundleIDs
        self.panelBackdropPreference = panelBackdropPreference
        self.aiSuggestionsEnabled = aiSuggestionsEnabled
    }

    public static let defaults = AgentSettingsSnapshot()
}

/// The first message of every IME connection. `sessionEpoch` is new per connection: the
/// IME drops every agent message that names another epoch.
public struct IMEHello: Codable, Sendable, Hashable {
    public var clientBundleID: String
    public var clientVersion: String
    public var sessionEpoch: UUID
    /// `rime`, `safeMode`, `booting`, or `unavailable`.
    public var engineMode: String

    public init(clientBundleID: String, clientVersion: String, sessionEpoch: UUID, engineMode: String) {
        self.clientBundleID = clientBundleID
        self.clientVersion = clientVersion
        self.sessionEpoch = sessionEpoch
        self.engineMode = engineMode
    }
}

/// Non-sensitive composition metadata: no preedit, candidates, or committed text.
public struct CompositionSnapshot: Codable, Sendable, Hashable {
    public var sessionEpoch: UUID
    public var generationID: UInt64
    public var isComposing: Bool
    public var candidateCount: Int
    public var isASCIIMode: Bool

    public init(sessionEpoch: UUID, generationID: UInt64, isComposing: Bool, candidateCount: Int, isASCIIMode: Bool) {
        self.sessionEpoch = sessionEpoch
        self.generationID = generationID
        self.isComposing = isComposing
        self.candidateCount = candidateCount
        self.isASCIIMode = isASCIIMode
    }
}

public struct AgentHelloAck: Codable, Sendable, Hashable {
    public var agentVersion: String
    public var sessionEpoch: UUID
    public var settings: AgentSettingsSnapshot

    public init(agentVersion: String, sessionEpoch: UUID, settings: AgentSettingsSnapshot) {
        self.agentVersion = agentVersion
        self.sessionEpoch = sessionEpoch
        self.settings = settings
    }
}

/// An asynchronous AI suggestion for composition `generationID`. It goes only to the
/// separate suggestion slot and never changes the first Rime candidate.
public struct AISuggestionMessage: Codable, Sendable, Hashable {
    public var sessionEpoch: UUID
    public var generationID: UInt64
    public var suggestion: String
    public var provider: String

    public init(sessionEpoch: UUID, generationID: UInt64, suggestion: String, provider: String) {
        self.sessionEpoch = sessionEpoch
        self.generationID = generationID
        self.suggestion = suggestion
        self.provider = provider
    }
}

/// A message family carried in `IPCEnvelope.payload`.
public protocol IPCMessage: Codable, Sendable, Equatable {
    /// The stable envelope kind of this case.
    var kind: String { get }
}

/// Messages from `NoemaIME` to `NoemaAgent`.
public enum IMEToAgent: IPCMessage {
    case hello(IMEHello)
    case heartbeat(sessionEpoch: UUID)
    case compositionStateChanged(CompositionSnapshot)
    case openSettingsRequested(section: SettingsSectionID?)

    public static let helloKind = "ime.hello"
    public static let heartbeatKind = "ime.heartbeat"
    public static let compositionStateChangedKind = "ime.compositionStateChanged"
    public static let openSettingsRequestedKind = "ime.openSettingsRequested"

    public var kind: String {
        switch self {
        case .hello: Self.helloKind
        case .heartbeat: Self.heartbeatKind
        case .compositionStateChanged: Self.compositionStateChangedKind
        case .openSettingsRequested: Self.openSettingsRequestedKind
        }
    }

    /// The connection epoch the message belongs to, when it names one.
    public var sessionEpoch: UUID? {
        switch self {
        case .hello(let hello): hello.sessionEpoch
        case .heartbeat(let epoch): epoch
        case .compositionStateChanged(let snapshot): snapshot.sessionEpoch
        case .openSettingsRequested: nil
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, hello, sessionEpoch, snapshot, section }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case Self.helloKind: self = .hello(try container.decode(IMEHello.self, forKey: .hello))
        case Self.heartbeatKind: self = .heartbeat(sessionEpoch: try container.decode(UUID.self, forKey: .sessionEpoch))
        case Self.compositionStateChangedKind:
            self = .compositionStateChanged(try container.decode(CompositionSnapshot.self, forKey: .snapshot))
        case Self.openSettingsRequestedKind:
            self = .openSettingsRequested(section: try container.decodeIfPresent(SettingsSectionID.self, forKey: .section))
        default:
            throw IPCError.malformedFrame
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .hello(let hello): try container.encode(hello, forKey: .hello)
        case .heartbeat(let epoch): try container.encode(epoch, forKey: .sessionEpoch)
        case .compositionStateChanged(let snapshot): try container.encode(snapshot, forKey: .snapshot)
        case .openSettingsRequested(let section): try container.encodeIfPresent(section, forKey: .section)
        }
    }
}

/// Messages from `NoemaAgent` to `NoemaIME`. Every case names the IME's `sessionEpoch`.
public enum AgentToIME: IPCMessage {
    case helloAck(AgentHelloAck)
    case heartbeatAck(sessionEpoch: UUID)
    case settingsSnapshot(sessionEpoch: UUID, settings: AgentSettingsSnapshot)
    case aiSuggestion(AISuggestionMessage)

    public static let helloAckKind = "agent.helloAck"
    public static let heartbeatAckKind = "agent.heartbeatAck"
    public static let settingsSnapshotKind = "agent.settingsSnapshot"
    public static let aiSuggestionKind = "agent.aiSuggestion"

    public var kind: String {
        switch self {
        case .helloAck: Self.helloAckKind
        case .heartbeatAck: Self.heartbeatAckKind
        case .settingsSnapshot: Self.settingsSnapshotKind
        case .aiSuggestion: Self.aiSuggestionKind
        }
    }

    public var sessionEpoch: UUID {
        switch self {
        case .helloAck(let ack): ack.sessionEpoch
        case .heartbeatAck(let epoch): epoch
        case .settingsSnapshot(let epoch, _): epoch
        case .aiSuggestion(let suggestion): suggestion.sessionEpoch
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, ack, sessionEpoch, settings, suggestion }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case Self.helloAckKind: self = .helloAck(try container.decode(AgentHelloAck.self, forKey: .ack))
        case Self.heartbeatAckKind: self = .heartbeatAck(sessionEpoch: try container.decode(UUID.self, forKey: .sessionEpoch))
        case Self.settingsSnapshotKind:
            self = .settingsSnapshot(
                sessionEpoch: try container.decode(UUID.self, forKey: .sessionEpoch),
                settings: try container.decode(AgentSettingsSnapshot.self, forKey: .settings))
        case Self.aiSuggestionKind: self = .aiSuggestion(try container.decode(AISuggestionMessage.self, forKey: .suggestion))
        default:
            throw IPCError.malformedFrame
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .helloAck(let ack): try container.encode(ack, forKey: .ack)
        case .heartbeatAck(let epoch): try container.encode(epoch, forKey: .sessionEpoch)
        case .settingsSnapshot(let epoch, let settings):
            try container.encode(epoch, forKey: .sessionEpoch)
            try container.encode(settings, forKey: .settings)
        case .aiSuggestion(let suggestion): try container.encode(suggestion, forKey: .suggestion)
        }
    }
}

extension IPCEnvelope where Payload: IPCMessage {
    /// An envelope whose `kind` is the message's kind.
    public init(sequence: UInt64, message: Payload, generationID: UInt64?) {
        self.init(sequence: sequence, kind: message.kind, payload: message, generationID: generationID)
    }

    /// True when `kind` agrees with the payload, the frame's consistency check.
    public var isConsistent: Bool { kind == payload.kind }
}
