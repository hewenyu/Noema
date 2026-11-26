import Foundation
@testable import NoemaIPC
import Testing

/// `PeerIdentityVerifier` on real processes: this test process and a freshly compiled,
/// ad-hoc signed child, both resolved from real audit tokens.
@Suite(.serialized) struct PeerIdentityVerifierTests {
    static let fakeTeam = "ABCDE12345"

    @Test func selfAuditTokenAcceptsMatchingIdentifierAndRejectsOthers() throws {
        let token = try #require(PeerIdentityVerifier.currentAuditToken())
        #expect(token.count == PeerIdentityVerifier.auditTokenSize)
        let me = try #require(SelfCodeIdentity.current())
        let identifier = try #require(me.signingIdentifier)

        let accepted = PeerIdentityVerifier.verify(auditToken: token, policy: .allowAdHocForTesting(signingIdentifiers: [identifier]))
        #expect(accepted == .success(me))
        #expect(PeerIdentityVerifier.verify(auditToken: token, policy: .allowAdHocForTesting(signingIdentifiers: ["dev.noema.other"]))
            == .failure(.signingIdentifierMismatch(identifier)))
        // The anti-downgrade resolution of the request accepts this process too.
        #expect(PeerIdentityVerifier.verify(auditToken: token, policy: try .resolvedSelf()) == .success(me))
    }

    @Test func adHocChildIsAcceptedOnlyForTestingAndNeverUnderStrict() throws {
        let child = try AdHocPeerProcess()
        defer { child.stop() }
        let token = try child.auditToken()

        let testing = PeerIdentityVerifier.verify(auditToken: token, policy: .allowAdHocForTesting(signingIdentifiers: [AdHocPeerProcess.identifier]))
        let identity = try testing.get()
        #expect(identity.signingIdentifier == AdHocPeerProcess.identifier && identity.isAdHoc && identity.teamID == nil)
        #expect(PeerIdentityVerifier.verify(auditToken: token, policy: .allowAdHocForTesting(signingIdentifiers: ["dev.noema.agent"]))
            == .failure(.signingIdentifierMismatch(AdHocPeerProcess.identifier)))

        let strict = PeerIdentityPolicy.strict(signingIdentifiers: [AdHocPeerProcess.identifier], teamID: Self.fakeTeam, requireHardenedRuntime: false)
        #expect(PeerIdentityVerifier.verify(auditToken: token, policy: strict) == .failure(.adHocRejected))
    }

    @Test func malformedAuditTokensAndUnpinnedStrictPoliciesFailClosed() throws {
        let policy = PeerIdentityPolicy.allowAdHocForTesting(signingIdentifiers: ["x"])
        for token in [Data(), Data(count: 31), Data(count: PeerIdentityVerifier.auditTokenSize), Data(count: 64)] {
            #expect(PeerIdentityVerifier.verify(auditToken: token, policy: policy) == .failure(.malformedAuditToken))
        }
        let token = try #require(PeerIdentityVerifier.currentAuditToken())
        let identifier = try #require(SelfCodeIdentity.current()?.signingIdentifier)
        let unpinned = PeerIdentityPolicy.strict(signingIdentifiers: [identifier], teamID: nil, leafCertificateSHA1: nil)
        #expect(unpinned.isUnpinnedStrict)
        #expect(PeerIdentityVerifier.verify(auditToken: token, policy: unpinned) == .failure(.unpinnedStrictPolicy))
        #expect(PeerIdentityVerifier.verify(auditToken: token, policy: .allowAdHocForTesting(signingIdentifiers: []))
            == .failure(.noExpectedSigningIdentifiers))
        // No layer-1 requirement either, so the transports refuse to open anything.
        #expect(unpinned.xpcPeerRequirement == nil && PeerIdentityPolicy.allowAdHocForTesting(signingIdentifiers: []).xpcPeerRequirement == nil)
    }

    /// A certificate-signed binary ignores an ad-hoc request: it pins itself and rejects
    /// the real ad-hoc child. Only a valid ad-hoc binary keeps the request; no valid self
    /// signature, or a non-ad-hoc one with nothing to pin, fails closed.
    @Test func antiDowngradeGuardPinsASignedSelf() throws {
        let signedSelf = SelfCodeIdentity(
            signingIdentifier: "dev.noema.inputmethod.NoemaIME", teamID: Self.fakeTeam,
            leafCertificateSHA1: String(repeating: "ab", count: 20), isAdHoc: false, hasHardenedRuntime: true)
        let requested = PeerIdentityPolicy.allowAdHocForTesting(signingIdentifiers: [AdHocPeerProcess.identifier])
        let resolved = PeerIdentityPolicy.resolved(requested: requested, selfIdentity: signedSelf)
        #expect(resolved == .strict(
            signingIdentifiers: [AdHocPeerProcess.identifier], teamID: Self.fakeTeam,
            leafCertificateSHA1: String(repeating: "AB", count: 20), requireHardenedRuntime: true))
        // An unpinned strict request is upgraded the same way; a pinned one is kept.
        let unpinned = PeerIdentityPolicy.strict(signingIdentifiers: ["a"], teamID: nil)
        #expect(PeerIdentityPolicy.resolved(requested: unpinned, selfIdentity: signedSelf).expectedTeamID == Self.fakeTeam)
        let pinned = PeerIdentityPolicy.strict(signingIdentifiers: ["a"], teamID: "ZZZZZ99999")
        #expect(PeerIdentityPolicy.resolved(requested: pinned, selfIdentity: signedSelf) == pinned)

        let child = try AdHocPeerProcess()
        defer { child.stop() }
        let token = try child.auditToken()
        #expect(PeerIdentityVerifier.verify(auditToken: token, policy: resolved) == .failure(.adHocRejected))
        #expect(throws: Never.self) { try PeerIdentityVerifier.verify(auditToken: token, policy: requested).get() }

        let adHocSelf = SelfCodeIdentity(signingIdentifier: "x", teamID: nil, leafCertificateSHA1: nil, isAdHoc: true, hasHardenedRuntime: false)
        #expect(PeerIdentityPolicy.resolved(requested: requested, selfIdentity: adHocSelf) == requested)

        // Fail closed: no valid self signature (e.g. -67034 after the bundle was replaced).
        let resolvedNil = PeerIdentityPolicy.resolved(requested: requested, selfIdentity: nil)
        #expect(resolvedNil.isUnpinnedStrict && resolvedNil.expectedSigningIdentifiers == requested.expectedSigningIdentifiers)
        #expect(resolvedNil.xpcPeerRequirement == nil)
        let selfToken = try #require(PeerIdentityVerifier.currentAuditToken())
        #expect(PeerIdentityVerifier.verify(auditToken: selfToken, policy: resolvedNil) == .failure(.unpinnedStrictPolicy))
        #expect(PeerIdentityVerifier.verify(auditToken: token, policy: resolvedNil) == .failure(.unpinnedStrictPolicy))
        // Non-ad-hoc but with neither a Team ID nor a leaf certificate: nothing to pin.
        let nonAdHocUnpinned = SelfCodeIdentity(signingIdentifier: "x", teamID: nil, leafCertificateSHA1: nil, isAdHoc: false, hasHardenedRuntime: true)
        #expect(PeerIdentityPolicy.resolved(requested: requested, selfIdentity: nonAdHocUnpinned).isUnpinnedStrict)
        #expect(PeerIdentityPolicy.resolved(requested: unpinned, selfIdentity: nil).isUnpinnedStrict)
    }

    @Test func strictEvaluationChecksRuntimeTeamAndCertificate() {
        let leaf = String(repeating: "C0", count: 20)
        let peer = PeerIdentity(signingIdentifier: "dev.noema.agent", teamID: Self.fakeTeam, leafCertificateSHA1: leaf, isAdHoc: false, hasHardenedRuntime: true)
        let policy = PeerIdentityPolicy.strict(signingIdentifiers: ["dev.noema.agent"], teamID: Self.fakeTeam, leafCertificateSHA1: leaf.lowercased())
        #expect(PeerIdentityVerifier.evaluate(peer, policy: policy) == .success(peer))
        var unhardened = peer
        unhardened.hasHardenedRuntime = false
        #expect(PeerIdentityVerifier.evaluate(unhardened, policy: policy) == .failure(.hardenedRuntimeMissing))
        var otherTeam = peer
        otherTeam.teamID = "ZZZZZ99999"
        #expect(PeerIdentityVerifier.evaluate(otherTeam, policy: policy) == .failure(.teamIDMismatch("ZZZZZ99999")))
        var otherCertificate = peer
        otherCertificate.leafCertificateSHA1 = String(repeating: "0", count: 40)
        #expect(PeerIdentityVerifier.evaluate(otherCertificate, policy: policy) == .failure(.certificateMismatch))
        var adHoc = peer
        adHoc.isAdHoc = true
        #expect(PeerIdentityVerifier.evaluate(adHoc, policy: policy) == .failure(.adHocRejected))
        #expect(PeerIdentityVerifier.sha1Hex(Data("abc".utf8)) == "A9993E364706816ABA3E25717850C26C9CD0D89D")
    }
}
