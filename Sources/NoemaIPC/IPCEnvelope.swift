import Foundation

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

/// Errors raised while reading, writing, or transporting IPC messages. One type for every
/// payload, so callers can match it without knowing the envelope's `Payload`. Append-only.
public enum IPCError: Error, Sendable, Hashable {
    /// The envelope declares a protocol version outside `IPCProtocolVersion.supported`.
    case unsupportedVersion(found: Int)
    /// An encoded envelope, or a received frame, exceeds `IPCWireLimits.maxPayloadBytes`.
    case payloadTooLarge(bytes: Int, limit: Int)
    /// A frame is missing, is not a JSON envelope, or names an unknown message kind.
    case malformedFrame
    /// The peer's code signature does not satisfy the `PeerIdentityPolicy`.
    case peerRejected(String)
    /// No connection to the peer; the reason the client degraded.
    case connectionUnavailable(IPCDegradationReason)
    case timeout
    case cancelled
}

/// Hard limits on one frame, enforced before any byte is decoded.
public enum IPCWireLimits {
    /// The largest encoded envelope either side sends or accepts: 256 KiB.
    public static let maxPayloadBytes = 256 * 1024
}

/// A versioned, correlated message between Noema processes.
public struct IPCEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let version: IPCProtocolVersion
    /// Monotonic per-connection sequence number used to correlate replies.
    public let sequence: UInt64
    /// Message kind, e.g. "engine.processKey". Stable once released.
    public let kind: String
    public let payload: Payload
    /// The sender's generation for `kind`: receivers drop stale and duplicate generations
    /// (`GenerationGate`). Absent in envelopes that predate it, which decode as `nil`.
    public let generationID: UInt64?

    public init(
        version: IPCProtocolVersion = .current, sequence: UInt64, kind: String, payload: Payload,
        generationID: UInt64? = nil
    ) {
        self.version = version
        self.sequence = sequence
        self.kind = kind
        self.payload = payload
        self.generationID = generationID
    }

    private enum CodingKeys: String, CodingKey {
        case version, sequence, kind, payload, generationID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(IPCProtocolVersion.self, forKey: .version)
        guard version.isSupported else { throw IPCError.unsupportedVersion(found: version.rawValue) }
        self.version = version
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        kind = try container.decode(String.self, forKey: .kind)
        payload = try container.decode(Payload.self, forKey: .payload)
        generationID = try container.decodeIfPresent(UInt64.self, forKey: .generationID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(kind, forKey: .kind)
        try container.encode(payload, forKey: .payload)
        try container.encodeIfPresent(generationID, forKey: .generationID)
    }
}

extension IPCEnvelope: Equatable where Payload: Equatable {}

/// JSON encoding of an `IPCEnvelope` for one frame, with `IPCWireLimits` enforced on both
/// sides: `decode` rejects an oversized frame before `JSONDecoder` reads a byte.
public enum IPCWireCodec {
    public static func encode<Payload>(_ envelope: IPCEnvelope<Payload>) throws(IPCError) -> Data {
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            throw .malformedFrame
        }
        guard data.count <= IPCWireLimits.maxPayloadBytes else {
            throw .payloadTooLarge(bytes: data.count, limit: IPCWireLimits.maxPayloadBytes)
        }
        return data
    }

    public static func decode<Payload>(
        _ type: Payload.Type = Payload.self, from data: Data
    ) throws(IPCError) -> IPCEnvelope<Payload> {
        guard data.count <= IPCWireLimits.maxPayloadBytes else {
            throw .payloadTooLarge(bytes: data.count, limit: IPCWireLimits.maxPayloadBytes)
        }
        do {
            return try JSONDecoder().decode(IPCEnvelope<Payload>.self, from: data)
        } catch let error as IPCError {
            throw error
        } catch {
            throw .malformedFrame
        }
    }
}
