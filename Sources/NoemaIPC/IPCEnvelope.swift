/// Version of the IPC wire format between Noema processes. Append-only: a reader
/// accepts any version in `supported` and rejects the rest.
public struct IPCProtocolVersion: Sendable, Hashable, Codable, Comparable, RawRepresentable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let v1 = IPCProtocolVersion(rawValue: 1)
    public static let current = v1
    public static let supported = v1.rawValue...current.rawValue

    public var isSupported: Bool { Self.supported.contains(rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A versioned, correlated message between Noema processes.
public struct IPCEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let version: IPCProtocolVersion
    /// Monotonic per-connection sequence number used to correlate replies.
    public let sequence: UInt64
    /// Message kind, e.g. "engine.processKey". Stable once released.
    public let kind: String
    public let payload: Payload

    public init(version: IPCProtocolVersion = .current, sequence: UInt64, kind: String, payload: Payload) {
        self.version = version
        self.sequence = sequence
        self.kind = kind
        self.payload = payload
    }

    /// Thrown when decoding an envelope whose version this build does not support.
    public struct UnsupportedVersion: Error, Sendable, Equatable {
        public let found: Int

        public init(found: Int) {
            self.found = found
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, sequence, kind, payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(IPCProtocolVersion.self, forKey: .version)
        guard version.isSupported else { throw UnsupportedVersion(found: version.rawValue) }
        self.version = version
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        kind = try container.decode(String.self, forKey: .kind)
        payload = try container.decode(Payload.self, forKey: .payload)
    }
}

extension IPCEnvelope: Equatable where Payload: Equatable {}
