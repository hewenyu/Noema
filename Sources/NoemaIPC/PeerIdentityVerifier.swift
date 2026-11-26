import CryptoKit
import Darwin
import Foundation
import Security
import XPC

// Peer code-signing checks for both ends of the NoemaIME <-> NoemaAgent connection, with
// public APIs only (XPC exposes no audit token on XPCSession):
//
// - Layer 1, in libxpc: `PeerIdentityPolicy.xpcPeerRequirement`, set on the client
//   session and on every accepted peer session (a listener's requirement is not inherited
//   by the sessions it accepts).
// - Layer 2, per message: `PeerIdentityVerifier.verify(xpcMessage:policy:)` resolves the
//   sender of that very message (`SecCodeCreateWithXPCMessage`, its audit token), checks
//   the signature without network access, and evaluates the policy. No PID lookup, so no
//   PID-reuse TOCTOU.

/// How strictly a peer's signature is checked.
public enum PeerIdentityMode: String, Sendable, Hashable {
    /// A certificate signature: never ad-hoc, pinned to a Team ID and/or leaf certificate.
    case strict
    /// Development and CI builds: an ad-hoc (or any valid) signature with an expected
    /// signing identifier. Honoured only when the running binary has a valid ad-hoc
    /// signature (`PeerIdentityPolicy.resolved(requested:selfIdentity:)`).
    case allowAdHocForTesting
}

public struct PeerIdentityPolicy: Sendable, Hashable {
    public var mode: PeerIdentityMode
    /// The peer's `kSecCodeInfoIdentifier` must be one of these; empty never matches.
    public var expectedSigningIdentifiers: Set<String>
    public var expectedTeamID: String?
    /// Uppercase hex SHA-1 of the leaf signing certificate.
    public var expectedLeafCertificateSHA1: String?
    public var requireHardenedRuntime: Bool

    public init(
        mode: PeerIdentityMode, expectedSigningIdentifiers: Set<String>, expectedTeamID: String? = nil,
        expectedLeafCertificateSHA1: String? = nil, requireHardenedRuntime: Bool = false
    ) {
        self.mode = mode
        self.expectedSigningIdentifiers = expectedSigningIdentifiers
        self.expectedTeamID = expectedTeamID
        self.expectedLeafCertificateSHA1 = expectedLeafCertificateSHA1?.uppercased()
        self.requireHardenedRuntime = requireHardenedRuntime
    }

    public static func strict(
        signingIdentifiers: Set<String>, teamID: String?, leafCertificateSHA1: String? = nil,
        requireHardenedRuntime: Bool = true
    ) -> PeerIdentityPolicy {
        PeerIdentityPolicy(
            mode: .strict, expectedSigningIdentifiers: signingIdentifiers, expectedTeamID: teamID,
            expectedLeafCertificateSHA1: leafCertificateSHA1, requireHardenedRuntime: requireHardenedRuntime)
    }

    public static func allowAdHocForTesting(signingIdentifiers: Set<String>) -> PeerIdentityPolicy {
        PeerIdentityPolicy(mode: .allowAdHocForTesting, expectedSigningIdentifiers: signingIdentifiers)
    }

    /// True for a `.strict` policy that pins neither a Team ID nor a certificate: it
    /// rejects every peer, and the XPC transports refuse to start under it (fail closed).
    public var isUnpinnedStrict: Bool {
        mode == .strict && expectedTeamID == nil && expectedLeafCertificateSHA1 == nil
    }

    /// The policy a process actually enforces (anti-downgrade, fail closed). A pinned
    /// `.strict` request is always kept. Otherwise only a verified, valid ad-hoc self
    /// signature honours `requested` (`.allowAdHocForTesting` or an unpinned `.strict`):
    ///
    /// - No valid self signature (`selfIdentity == nil`, e.g. `SecCodeCheckValidity`
    ///   failing after the bundle was replaced or tampered with): an unpinned `.strict`,
    ///   which rejects every peer and opens no XPC session or listener.
    /// - Non-ad-hoc: `.strict` pinned to its own Team ID and leaf certificate, keeping
    ///   `requested`'s signing identifiers and requiring Hardened Runtime when it runs
    ///   hardened itself. Without a Team ID or leaf certificate that is an unpinned
    ///   `.strict` too. No Team ID is written in source.
    public static func resolved(requested: PeerIdentityPolicy, selfIdentity: SelfCodeIdentity?) -> PeerIdentityPolicy {
        if requested.mode == .strict && !requested.isUnpinnedStrict { return requested }
        guard let selfIdentity else {
            return .strict(
                signingIdentifiers: requested.expectedSigningIdentifiers, teamID: nil,
                leafCertificateSHA1: nil, requireHardenedRuntime: true)
        }
        if selfIdentity.isAdHoc { return requested }
        return .strict(
            signingIdentifiers: requested.expectedSigningIdentifiers, teamID: selfIdentity.teamID,
            leafCertificateSHA1: selfIdentity.leafCertificateSHA1,
            requireHardenedRuntime: requested.requireHardenedRuntime || selfIdentity.hasHardenedRuntime)
    }

    /// The layer-1 requirement libxpc enforces before any message is delivered: the
    /// signing identifier, plus the Team ID when pinned. Layer 2 still runs on every
    /// message. Nil when no identifier is expected or the policy is an unpinned `.strict`:
    /// the transports then refuse to open a session or listener at all (fail closed).
    public var xpcPeerRequirement: XPCPeerRequirement? {
        guard !expectedSigningIdentifiers.isEmpty, !isUnpinnedStrict else { return nil }
        let requirement = xpc_dictionary_create_empty()
        let identifiers = expectedSigningIdentifiers.sorted()
        if identifiers.count == 1 {
            xpc_dictionary_set_string(requirement, "signing-identifier", identifiers[0])
        } else {
            let list = xpc_array_create_empty()
            for identifier in identifiers { xpc_array_set_string(list, XPC_ARRAY_APPEND, identifier) }
            let anyOf = xpc_dictionary_create_empty()
            xpc_dictionary_set_value(anyOf, "$in", list)
            xpc_dictionary_set_value(requirement, "signing-identifier", anyOf)
        }
        if mode == .strict, let team = expectedTeamID {
            xpc_dictionary_set_string(requirement, "team-identifier", team)
        }
        return XPCPeerRequirement(lightweightCodeRequirements: XPCDictionary(requirement))
    }
}

/// The signing facts of one process, read from its validated `SecCode`.
public struct PeerIdentity: Sendable, Hashable {
    public var signingIdentifier: String?
    public var teamID: String?
    public var leafCertificateSHA1: String?
    public var isAdHoc: Bool
    public var hasHardenedRuntime: Bool

    public init(signingIdentifier: String?, teamID: String?, leafCertificateSHA1: String?, isAdHoc: Bool, hasHardenedRuntime: Bool) {
        self.signingIdentifier = signingIdentifier
        self.teamID = teamID
        self.leafCertificateSHA1 = leafCertificateSHA1?.uppercased()
        self.isAdHoc = isAdHoc
        self.hasHardenedRuntime = hasHardenedRuntime
    }

    /// Non-ad-hoc with a Team ID or a leaf certificate.
    public var isCertificateSigned: Bool { !isAdHoc && (teamID != nil || leafCertificateSHA1 != nil) }
}

/// The running process's own identity, the anchor of the anti-downgrade guard.
public typealias SelfCodeIdentity = PeerIdentity

extension PeerIdentity {
    /// The running binary's identity (`SecCodeCopySelf`), or nil when it has no valid signature.
    public static func current() -> SelfCodeIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return try? PeerIdentityVerifier.identity(of: code).get()
    }
}

public enum PeerVerificationError: Error, Sendable, Hashable {
    /// `.strict` without a Team ID or certificate pin.
    case unpinnedStrictPolicy
    case noExpectedSigningIdentifiers
    /// An audit token that is not exactly `audit_token_t`-sized, or all zero.
    case malformedAuditToken
    case codeLookupFailed(OSStatus)
    case invalidSignature(OSStatus)
    case signingInformationUnavailable(OSStatus)
    case adHocRejected
    case hardenedRuntimeMissing
    case signingIdentifierMismatch(String?)
    case teamIDMismatch(String?)
    case certificateMismatch

    public var description: String {
        switch self {
        case .unpinnedStrictPolicy: "strict policy pins no Team ID or certificate"
        case .noExpectedSigningIdentifiers: "policy expects no signing identifier"
        case .malformedAuditToken: "malformed audit token"
        case .codeLookupFailed(let status): "cannot resolve the peer's code (\(status))"
        case .invalidSignature(let status): "peer signature is invalid (\(status))"
        case .signingInformationUnavailable(let status): "cannot read the peer's signing information (\(status))"
        case .adHocRejected: "ad-hoc peer under a strict policy"
        case .hardenedRuntimeMissing: "peer lacks Hardened Runtime"
        case .signingIdentifierMismatch(let found): "unexpected signing identifier \(found ?? "<none>")"
        case .teamIDMismatch(let found): "unexpected Team ID \(found ?? "<none>")"
        case .certificateMismatch: "unexpected leaf certificate"
        }
    }
}

public enum PeerIdentityVerifier {
    /// `kSecCSNoNetworkAccess`: never fetch revocation data on the IPC path.
    static let validityFlags = SecCSFlags(rawValue: 1 << 29)
    /// `sizeof(audit_token_t)`.
    public static let auditTokenSize = MemoryLayout<audit_token_t>.size

    /// Verifies the sender of `xpcMessage`, a received `XPC_TYPE_DICTIONARY`.
    public static func verify(xpcMessage: xpc_object_t, policy: PeerIdentityPolicy) -> Result<PeerIdentity, PeerVerificationError> {
        if let error = policyError(policy) { return .failure(error) }
        var code: SecCode?
        let status = SecCodeCreateWithXPCMessage(xpcMessage, [], &code)
        guard status == errSecSuccess, let code else { return .failure(.codeLookupFailed(status)) }
        return verify(code: code, policy: policy)
    }

    /// Verifies the process named by a raw `audit_token_t`.
    public static func verify(auditToken: Data, policy: PeerIdentityPolicy) -> Result<PeerIdentity, PeerVerificationError> {
        if let error = policyError(policy) { return .failure(error) }
        guard auditToken.count == auditTokenSize, auditToken.contains(where: { $0 != 0 }) else {
            return .failure(.malformedAuditToken)
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken as NSData] as CFDictionary
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let code else { return .failure(.codeLookupFailed(status)) }
        return verify(code: code, policy: policy)
    }

    static func verify(code: SecCode, policy: PeerIdentityPolicy) -> Result<PeerIdentity, PeerVerificationError> {
        identity(of: code).flatMap { evaluate($0, policy: policy) }
    }

    /// The policy decision on already-read signing facts.
    public static func evaluate(_ identity: PeerIdentity, policy: PeerIdentityPolicy) -> Result<PeerIdentity, PeerVerificationError> {
        if let error = policyError(policy) { return .failure(error) }
        if policy.mode == .strict {
            if identity.isAdHoc { return .failure(.adHocRejected) }
            if policy.requireHardenedRuntime && !identity.hasHardenedRuntime { return .failure(.hardenedRuntimeMissing) }
        }
        guard let identifier = identity.signingIdentifier, policy.expectedSigningIdentifiers.contains(identifier) else {
            return .failure(.signingIdentifierMismatch(identity.signingIdentifier))
        }
        if policy.mode == .strict {
            if let team = policy.expectedTeamID, identity.teamID != team { return .failure(.teamIDMismatch(identity.teamID)) }
            if let pin = policy.expectedLeafCertificateSHA1, identity.leafCertificateSHA1 != pin {
                return .failure(.certificateMismatch)
            }
        }
        return .success(identity)
    }

    private static func policyError(_ policy: PeerIdentityPolicy) -> PeerVerificationError? {
        if policy.isUnpinnedStrict { return .unpinnedStrictPolicy }
        if policy.expectedSigningIdentifiers.isEmpty { return .noExpectedSigningIdentifiers }
        return nil
    }

    /// Validates `code` (`CS_VALID`, no network) and reads its signing facts.
    static func identity(of code: SecCode) -> Result<PeerIdentity, PeerVerificationError> {
        var cfError: Unmanaged<CFError>?
        let validity = SecCodeCheckValidityWithErrors(code, validityFlags, nil, &cfError)
        cfError?.release()
        guard validity == errSecSuccess else { return .failure(.invalidSignature(validity)) }
        var staticCode: SecStaticCode?
        let copied = SecCodeCopyStaticCode(code, [], &staticCode)
        guard copied == errSecSuccess, let staticCode else { return .failure(.signingInformationUnavailable(copied)) }
        var information: CFDictionary?
        let read = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &information)
        guard read == errSecSuccess, let info = information as? [String: Any] else {
            return .failure(.signingInformationUnavailable(read))
        }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        var leaf: String?
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certificates.first {
            leaf = sha1Hex(SecCertificateCopyData(first) as Data)
        }
        return .success(PeerIdentity(
            signingIdentifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            leafCertificateSHA1: leaf,
            isAdHoc: flags & UInt32(SecCodeSignatureFlags.adhoc.rawValue) != 0,
            hasHardenedRuntime: flags & UInt32(SecCodeSignatureFlags.runtime.rawValue) != 0))
    }

    /// Uppercase 40-hex SHA-1, the form `security find-identity` prints.
    public static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// This process's audit token (`task_info(TASK_AUDIT_TOKEN)`).
    public static func currentAuditToken() -> Data? {
        auditToken(ofTask: mach_task_self_)
    }

    /// The audit token of a task port or task name port.
    public static func auditToken(ofTask task: mach_port_t) -> Data? {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }
}
