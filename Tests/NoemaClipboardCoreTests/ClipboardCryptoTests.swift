import CryptoKit
import Foundation
import LocalAuthentication
@testable import NoemaClipboardCore
import os
import Security
import Testing

/// AES-GCM sealing with domain-separated keys and row-bound associated data, and the
/// keychain key store's status mapping (against a fake backend: the user's keychain is
/// never touched).
@Suite struct ClipboardCryptoTests {
    @Test func textRoundTripsWithFreshNonces() throws {
        let cipher = ClipboardCipher(masterKey: SymmetricKey(size: .bits256))
        let dedup = cipher.dedupHMAC(kind: .text, payload: Data("你好 swift".utf8))
        let first = try cipher.sealText("你好 swift", id: "a", dedupHMAC: dedup)
        let second = try cipher.sealText("你好 swift", id: "a", dedupHMAC: dedup)
        #expect(first != second, "every seal draws a new nonce")
        #expect(first.count == 12 + Data("你好 swift".utf8).count + 16)
        #expect(try cipher.openText(first, id: "a", dedupHMAC: dedup) == "你好 swift")
        #expect(RawDisk.occurrences(of: Data("swift".utf8), in: first) == 0)
    }

    @Test func tamperingFailsToOpen() throws {
        let cipher = ClipboardCipher(masterKey: SymmetricKey(size: .bits256))
        let dedup = cipher.dedupHMAC(kind: .text, payload: Data("payload".utf8))
        let sealed = try cipher.sealText("payload", id: "row-1", dedupHMAC: dedup)
        for index in [0, 12, sealed.count - 1] {
            var flipped = sealed
            flipped[index] ^= 0x01
            #expect(throws: ClipboardError.decryptionFailed) { try cipher.openText(flipped, id: "row-1", dedupHMAC: dedup) }
        }
        // Moved to another row (id or dedup in the AAD differs).
        #expect(throws: ClipboardError.decryptionFailed) { try cipher.openText(sealed, id: "row-2", dedupHMAC: dedup) }
        #expect(throws: ClipboardError.decryptionFailed) { try cipher.openText(sealed, id: "row-1", dedupHMAC: String(repeating: "0", count: 64)) }
        // Another master key.
        let other = ClipboardCipher(masterKey: SymmetricKey(size: .bits256))
        #expect(throws: ClipboardError.decryptionFailed) { try other.openText(sealed, id: "row-1", dedupHMAC: dedup) }
        // Truncated.
        #expect(throws: ClipboardError.decryptionFailed) { try cipher.openText(sealed.prefix(10), id: "row-1", dedupHMAC: dedup) }
    }

    @Test func keysAreDomainSeparated() throws {
        let cipher = ClipboardCipher(masterKey: SymmetricKey(size: .bits256))
        let digest = String(repeating: "a", count: 64)
        let blob = try cipher.sealBlob(Data("png".utf8), digest: digest, thumbnail: false)
        #expect(try cipher.openBlob(blob, digest: digest, thumbnail: false) == Data("png".utf8))
        #expect(throws: ClipboardError.decryptionFailed) { try cipher.openBlob(blob, digest: digest, thumbnail: true) }
        #expect(throws: ClipboardError.decryptionFailed) { try cipher.openBlob(blob, digest: String(repeating: "b", count: 64), thumbnail: false) }
        // The blob key is not the text key, even with matching associated data.
        let aad = ClipboardCipher.blobAAD(digest: digest)
        #expect(ClipboardCipher.textAAD(id: "x", dedupHMAC: "y") != aad)
        // The dedup HMAC is keyed and kind-separated.
        let payload = Data("same".utf8)
        #expect(cipher.dedupHMAC(kind: .text, payload: payload) != cipher.dedupHMAC(kind: .image, payload: payload))
        #expect(cipher.dedupHMAC(kind: .text, payload: payload) != Data(SHA256.hash(data: payload)).hexString)
        #expect(ClipboardBlobStore.isValidDigest(cipher.dedupHMAC(kind: .image, payload: payload)))
    }

    // MARK: Keychain status mapping

    final class FakeKeychain: KeychainItemBackend, @unchecked Sendable {
        struct State {
            var copyStatus: OSStatus = errSecItemNotFound
            var stored: Data?
            var addStatus: OSStatus = errSecSuccess
            var adds: [[String: String]] = []
            var queries: [[String: String]] = []
            var nonInteractiveFlags: [Bool?] = []
        }

        let state = OSAllocatedUnfairLock(initialState: State())

        func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
            state.withLockUnchecked { state in
                state.queries.append(query.mapValues { "\($0)" })
                let context = query[kSecUseAuthenticationContext as String] as? LAContext
                state.nonInteractiveFlags.append(context?.interactionNotAllowed)
                return (state.copyStatus, state.copyStatus == errSecSuccess ? state.stored : nil)
            }
        }

        func add(_ attributes: [String: Any]) -> OSStatus {
            state.withLockUnchecked { state in
                state.adds.append(attributes.filter { $0.key != kSecValueData as String }.mapValues { "\($0)" })
                if state.addStatus == errSecSuccess {
                    state.stored = attributes[kSecValueData as String] as? Data
                    state.copyStatus = errSecSuccess
                }
                return state.addStatus
            }
        }
    }

    @Test func createsAKeyOnlyWhenNoneExists() throws {
        let fake = FakeKeychain()
        let store = KeychainClipboardKeyStore(backend: fake)
        let key = try store.loadOrCreateMasterKey()
        let adds = fake.state.withLockUnchecked { $0.adds }
        #expect(adds.count == 1)
        #expect(adds[0][kSecAttrService as String] == "dev.noema.agent.clipboard" && adds[0][kSecAttrAccount as String] == "master-key-v1")
        #expect(adds[0][kSecAttrSynchronizable as String] == "false")
        #expect(adds[0][kSecUseDataProtectionKeychain as String] == nil, "legacy login keychain: no entitlement needed")
        #expect(fake.state.withLockUnchecked { $0.stored?.count } == 32)
        // The second load reads the same key back and adds nothing.
        let again = try store.loadOrCreateMasterKey()
        #expect(again.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
        #expect(fake.state.withLockUnchecked { $0.adds.count } == 1)
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed])
    func lockedKeychainNeverCreatesOrReplacesAKey(_ status: OSStatus) {
        let fake = FakeKeychain()
        let existing = Data(repeating: 7, count: 32)
        fake.state.withLockUnchecked {
            $0.stored = existing
            $0.copyStatus = status
        }
        #expect(throws: ClipboardError.keychainLocked) { try KeychainClipboardKeyStore(backend: fake).loadOrCreateMasterKey() }
        #expect(fake.state.withLockUnchecked { $0.adds.isEmpty })
        #expect(fake.state.withLockUnchecked { $0.stored } == existing)
    }

    @Test func otherFailuresAreNotSilentlyReplaced() {
        let fake = FakeKeychain()
        fake.state.withLockUnchecked {
            $0.stored = Data(repeating: 1, count: 16)
            $0.copyStatus = errSecSuccess
        }
        #expect(throws: ClipboardError.keyCorrupted) { try KeychainClipboardKeyStore(backend: fake).loadOrCreateMasterKey() }
        fake.state.withLockUnchecked { $0.copyStatus = errSecDecode }
        #expect(throws: ClipboardError.keychainFailure(errSecDecode)) { try KeychainClipboardKeyStore(backend: fake).loadOrCreateMasterKey() }
        #expect(fake.state.withLockUnchecked { $0.adds.isEmpty })
    }

    @Test func verifyMasterKeyAccessIsNonInteractiveAndNeverCreatesKeys() throws {
        let fake = FakeKeychain()
        let keyStore = KeychainClipboardKeyStore(backend: fake)

        // Missing item: throws keychainFailure(errSecItemNotFound), never adds a key, passes non-interactive LAContext.
        #expect(throws: ClipboardError.keychainFailure(errSecItemNotFound)) { try keyStore.verifyMasterKeyAccess() }
        #expect(fake.state.withLockUnchecked { $0.adds.isEmpty && $0.nonInteractiveFlags == [true] })

        // Locked keychain: maps to .keychainLocked without creating/replacing a key.
        fake.state.withLockUnchecked {
            $0.stored = Data(repeating: 9, count: 32)
            $0.copyStatus = errSecInteractionNotAllowed
        }
        #expect(throws: ClipboardError.keychainLocked) { try keyStore.verifyMasterKeyAccess() }
        #expect(fake.state.withLockUnchecked { $0.adds.isEmpty && $0.nonInteractiveFlags == [true, true] })

        // Unlocked keychain with valid 32-byte key: succeeds non-interactively.
        fake.state.withLockUnchecked { $0.copyStatus = errSecSuccess }
        try keyStore.verifyMasterKeyAccess()
        #expect(fake.state.withLockUnchecked { $0.adds.isEmpty && $0.nonInteractiveFlags == [true, true, true] })
    }

    @Test func loadExistingMasterKeyNonInteractiveNeverPromptsOrCreates() throws {
        let fake = FakeKeychain()
        let keyStore = KeychainClipboardKeyStore(backend: fake)

        // Missing item returns nil without adding a key.
        #expect(try keyStore.loadExistingMasterKeyNonInteractive() == nil)
        #expect(fake.state.withLockUnchecked { $0.adds.isEmpty && $0.nonInteractiveFlags == [true] })

        // Locked keychain throws .keychainLocked without prompting or adding.
        let stored = Data(repeating: 4, count: 32)
        fake.state.withLockUnchecked {
            $0.stored = stored
            $0.copyStatus = errSecInteractionNotAllowed
        }
        #expect(throws: ClipboardError.keychainLocked) { _ = try keyStore.loadExistingMasterKeyNonInteractive() }
        #expect(fake.state.withLockUnchecked { $0.adds.isEmpty && $0.nonInteractiveFlags == [true, true] })

        // Unlocked keychain returns the existing key non-interactively.
        fake.state.withLockUnchecked { $0.copyStatus = errSecSuccess }
        let loaded = try #require(try keyStore.loadExistingMasterKeyNonInteractive())
        #expect(loaded.withUnsafeBytes { Data($0) } == stored)
        #expect(fake.state.withLockUnchecked { $0.adds.isEmpty && $0.nonInteractiveFlags == [true, true, true] })
    }

    @Test func inMemoryKeyStoreSimulatesALock() throws {
        let store = InMemoryClipboardKeyStore(isLocked: true)
        #expect(throws: ClipboardError.keychainLocked) { try store.loadOrCreateMasterKey() }
        #expect(store.creationCount == 0)
        store.isLocked = false
        let key = try store.loadOrCreateMasterKey()
        #expect(store.creationCount == 1 && store.key.map { $0.withUnsafeBytes { Data($0) } } == key.withUnsafeBytes { Data($0) })
    }
}
