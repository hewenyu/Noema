import CryptoKit
import Foundation
import LocalAuthentication
import os
import Security

/// Supplies the clipboard history's 256-bit master key.
public protocol ClipboardKeyStore: Sendable {
    /// The existing key, or a new one when none exists. Throws `.keychainLocked` when the
    /// keychain refuses access; an implementation never replaces an existing key then.
    func loadOrCreateMasterKey() throws(ClipboardError) -> SymmetricKey

    /// Non-interactively verifies that the master key is still readable (e.g. after a
    /// runtime keychain lock). Implementations must never create or replace a key here.
    func verifyMasterKeyAccess() throws(ClipboardError)
}

public extension ClipboardKeyStore {
    func verifyMasterKeyAccess() throws(ClipboardError) {
        _ = try loadOrCreateMasterKey()
    }
}

/// The `SecItem` calls `KeychainClipboardKeyStore` makes; tests substitute a fake so they
/// never touch the user's keychain.
public protocol KeychainItemBackend: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
}

/// The real `SecItemCopyMatching` / `SecItemAdd`.
public struct SystemKeychainItemBackend: KeychainItemBackend {
    public init() {}

    public func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// The master key as a generic password in the login keychain (service
/// `dev.noema.agent.clipboard`, account `master-key-v1`, never synchronized). It uses the
/// file-based login keychain, not the Data Protection keychain, so `Noema.app` needs no
/// keychain-access-groups entitlement. Only `errSecItemNotFound` creates a key; a locked or
/// refused keychain is `.keychainLocked`, never a new key and never plaintext.
public struct KeychainClipboardKeyStore: ClipboardKeyStore {
    public static let service = "dev.noema.agent.clipboard"
    public static let account = "master-key-v1"

    private let backend: any KeychainItemBackend

    public init(backend: any KeychainItemBackend = SystemKeychainItemBackend()) {
        self.backend = backend
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func loadOrCreateMasterKey() throws(ClipboardError) -> SymmetricKey {
        if let key = try read() { return key }
        let key = SymmetricKey(size: .bits256)
        var attributes = baseQuery
        attributes[kSecAttrLabel as String] = "Noema 剪贴板历史密钥"
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = backend.add(attributes)
        switch status {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Another instance created it first: use theirs.
            guard let existing = try read() else { throw .keychainFailure(status) }
            return existing
        default:
            throw Self.map(status)
        }
    }

    public func verifyMasterKeyAccess() throws(ClipboardError) {
        guard (try read(allowUI: false)) != nil else { throw .keychainFailure(errSecItemNotFound) }
    }

    /// The stored key, nil only for `errSecItemNotFound`.
    private func read(allowUI: Bool = true) throws(ClipboardError) -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUI {
            // Non-interactive runtime probe: fail with `errSecInteractionNotAllowed` when
            // locked instead of presenting a modal unlock sheet in the background.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let (status, data) = backend.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data, data.count == 32 else { throw .keyCorrupted }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Self.map(status)
        }
    }

    static func map(_ status: OSStatus) -> ClipboardError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNotAvailable:
            .keychainLocked
        default:
            .keychainFailure(status)
        }
    }
}

/// A process-local key for tests and headless runs: `isLocked` simulates a locked keychain.
public final class InMemoryClipboardKeyStore: ClipboardKeyStore, @unchecked Sendable {
    private struct State {
        var key: SymmetricKey?
        var isLocked = false
        var loads = 0
        var creations = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(key: SymmetricKey? = nil, isLocked: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(key: key, isLocked: isLocked))
    }

    public var isLocked: Bool {
        get { state.withLock { $0.isLocked } }
        set { state.withLock { $0.isLocked = newValue } }
    }

    public var key: SymmetricKey? { state.withLock { $0.key } }
    public var loadCount: Int { state.withLock { $0.loads } }
    public var creationCount: Int { state.withLock { $0.creations } }

    public func loadOrCreateMasterKey() throws(ClipboardError) -> SymmetricKey {
        let result = state.withLock { state -> SymmetricKey? in
            state.loads += 1
            guard !state.isLocked else { return nil }
            if let key = state.key { return key }
            let key = SymmetricKey(size: .bits256)
            state.key = key
            state.creations += 1
            return key
        }
        guard let result else { throw .keychainLocked }
        return result
    }
}

/// AES-GCM sealing for the history. Three domain-separated keys come from the master key
/// with HKDF-SHA256: text payloads, image blobs, and the dedup HMAC. Every seal draws a
/// fresh random 96-bit nonce and binds the row or blob it belongs to as associated data,
/// so a ciphertext moved to another row or file fails to open.
public struct ClipboardCipher: Sendable {
    public static let keyVersion = 1
    static let textInfo = "noema.clipboard.v1.text-aesgcm"
    static let blobInfo = "noema.clipboard.v1.blob-aesgcm"
    static let dedupInfo = "noema.clipboard.v1.dedup-hmac"

    private let textKey: SymmetricKey
    private let blobKey: SymmetricKey
    private let dedupKey: SymmetricKey

    public init(masterKey: SymmetricKey) {
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: masterKey, salt: Data("noema.clipboard".utf8), info: Data(info.utf8), outputByteCount: 32)
        }
        textKey = derive(Self.textInfo)
        blobKey = derive(Self.blobInfo)
        dedupKey = derive(Self.dedupInfo)
    }

    /// The keyed content digest (64 lowercase hex): the dedup key of a row and the file
    /// name of an image blob. Keyed, so the database never holds a plain hash that confirms
    /// a guessed copy.
    public func dedupHMAC(kind: ClipboardItemKind, payload: Data) -> String {
        var hmac = HMAC<SHA256>(key: dedupKey)
        hmac.update(data: Data("\(kind.rawValue)\u{0}".utf8))
        hmac.update(data: payload)
        return Data(hmac.finalize()).hexString
    }

    public static func textAAD(id: String, dedupHMAC: String) -> Data { Data("noema.clip.v1|text|\(id)|\(dedupHMAC)".utf8) }
    public static func blobAAD(digest: String) -> Data { Data("noema.clip.v1|blob|\(digest)".utf8) }
    public static func thumbnailAAD(digest: String) -> Data { Data("noema.clip.v1|thumb|\(digest)".utf8) }

    public func sealText(_ text: String, id: String, dedupHMAC: String) throws(ClipboardError) -> Data {
        try seal(Data(text.utf8), key: textKey, aad: Self.textAAD(id: id, dedupHMAC: dedupHMAC))
    }

    public func openText(_ sealed: Data, id: String, dedupHMAC: String) throws(ClipboardError) -> String {
        let data = try open(sealed, key: textKey, aad: Self.textAAD(id: id, dedupHMAC: dedupHMAC))
        guard let text = String(data: data, encoding: .utf8) else { throw .decryptionFailed }
        return text
    }

    public func sealBlob(_ data: Data, digest: String, thumbnail: Bool) throws(ClipboardError) -> Data {
        try seal(data, key: blobKey, aad: thumbnail ? Self.thumbnailAAD(digest: digest) : Self.blobAAD(digest: digest))
    }

    public func openBlob(_ sealed: Data, digest: String, thumbnail: Bool) throws(ClipboardError) -> Data {
        try open(sealed, key: blobKey, aad: thumbnail ? Self.thumbnailAAD(digest: digest) : Self.blobAAD(digest: digest))
    }

    private func seal(_ data: Data, key: SymmetricKey, aad: Data) throws(ClipboardError) -> Data {
        do {
            guard let combined = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce(), authenticating: aad).combined else {
                throw ClipboardError.encryptionFailed
            }
            return combined
        } catch {
            throw .encryptionFailed
        }
    }

    private func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws(ClipboardError) -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
        } catch {
            throw .decryptionFailed
        }
    }
}

extension Data {
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(count * 2)
        for byte in self {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
