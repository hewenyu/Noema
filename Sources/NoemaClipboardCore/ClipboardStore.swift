import CryptoKit
import Darwin
import Foundation
import NoemaCore
import os
import SQLite3

/// Counters for the Settings window and tests.
public struct ClipboardStoreDiagnostics: Sendable, Hashable {
    /// Rows whose payload failed to decrypt at the last hydration (tampered, wrong key).
    public var undecryptableRows = 0
    /// Rows in the in-memory FTS5 index.
    public var indexedRows = 0
    /// Blob files and rows removed by the last orphan collection.
    public var orphansRemoved = 0
}

/// The clipboard history: `clipboard.sqlite` (WAL) holds item metadata and AES-GCM sealed
/// text; `blobs/` holds sealed images. Nothing on disk is plaintext content, and there is
/// no FTS table on disk: search runs on an ephemeral `:memory:` FTS5 index rebuilt from
/// decrypted rows at open and unlock and kept in step with every change.
///
/// - The directory must be a real `0700` directory; `clipboard.sqlite` and its `-wal` and
///   `-shm` must be regular `0600` files, opened with `SQLITE_OPEN_NOFOLLOW`.
/// - Text dedups on `(kind, dedup_hmac)`; a repeat copy only refreshes `last_used_at` and
///   the source app. Images dedup the same way, and a blob is unlinked only when no row
///   references it.
/// - Unpinned rows expire `ttl(for:)` after their last use and are evicted oldest first
///   past `maxItems` or `maxTotalImageBytes`; pinned rows never expire or get evicted.
/// - When the keychain refuses the master key the store is `.keychainLocked`: listing is
///   empty and content writes throw `.storeLocked` until `retryUnlock()` succeeds; TTL and
///   quota maintenance may still drop expired or over-quota rows.
///
/// Thread-safe: every call is serialized by one lock.
public final class ClipboardStore: @unchecked Sendable {
    public static let schemaVersion: Int32 = 1
    /// Characters of a text entry kept in memory as its list preview.
    public static let previewLength = 240
    /// Characters of a text entry indexed for search.
    public static let indexedCharacterLimit = 32_768

    public let directory: URL
    public let databaseURL: URL
    public let quota: ClipboardStorageQuota
    public let blobs: ClipboardBlobStore

    private let keyStore: any ClipboardKeyStore
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var index: OpaquePointer?
    private var cipher: ClipboardCipher?
    private var previews: [String: String] = [:]
    private var unreadable: Set<String> = []
    private var diagnosticsValue = ClipboardStoreDiagnostics()
    private let log = NoemaLog.agent("clipboard-store")

    /// Opens (creating when missing) the store in `directory`, loads the master key, builds
    /// the search index, drops expired rows, and collects orphaned blobs.
    public init(
        directory: URL, keyStore: any ClipboardKeyStore, quota: ClipboardStorageQuota = .default, now: Date = Date()
    ) throws(ClipboardError) {
        let parent = directory.deletingLastPathComponent()
        if !parent.path.isEmpty, !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw .blobIO(parent.path, errno: errno == 0 ? EIO : errno)
            }
        }
        try ClipboardBlobStore.ensurePrivateDirectory(directory)
        // SQLITE_OPEN_NOFOLLOW refuses a symlink anywhere in the path: resolve the ancestors
        // (`/var` -> `/private/var`); the directory itself was just checked not to be one.
        guard let resolved = realpath(directory.path, nil) else { throw .openFailed(directory.path, code: errno) }
        let root = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
        free(resolved)
        self.directory = root
        self.databaseURL = NoemaPaths.clipboardStoreURL(root: root)
        self.quota = quota
        self.keyStore = keyStore
        self.blobs = try ClipboardBlobStore(
            directory: NoemaPaths.clipboardBlobsDir(root: root), maxBlobBytes: quota.maxImageBytes + 4_096)

        try Self.refuseNonRegularFiles(at: databaseURL)
        try Self.createPrivateFile(at: databaseURL)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2"
            sqlite3_close_v2(handle)
            throw .openFailed("\(databaseURL.path): \(message)", code: status)
        }
        db = handle
        var memory: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &memory, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let memory
        else {
            sqlite3_close_v2(memory)
            close()
            throw .openFailed(":memory:", code: SQLITE_CANTOPEN)
        }
        index = memory
        do {
            try configure(handle)
            try Self.exec(memory, "PRAGMA temp_store = MEMORY")
            try Self.exec(
                memory,
                "CREATE VIRTUAL TABLE clip_fts USING fts5(item_id UNINDEXED, body, source_app, tokenize='unicode61 remove_diacritics 2')")
            try Self.refuseNonRegularFiles(at: databaseURL)
            Self.restrictPermissions(of: databaseURL)
        } catch {
            close()
            throw error
        }
        lock.lock()
        defer { lock.unlock() }
        unlockLocked()
        _ = try? purgeExpiredLocked(now: now)
        collectOrphansLocked()
    }

    deinit { close() }

    // MARK: State

    public var state: ClipboardStoreState {
        lock.lock()
        defer { lock.unlock() }
        return cipher == nil ? .keychainLocked : .ready
    }

    public var diagnostics: ClipboardStoreDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsValue
    }

    /// Non-interactively verifies that the master key is still readable when the store is
    /// `.ready`; transitions to `.keychainLocked` and wipes in-memory key material, previews,
    /// and `:memory:` FTS5 tokens if access is refused. Never prompts interactively and never
    /// creates a key when already `.keychainLocked`.
    @discardableResult
    public func verifyKeychainAccess() -> ClipboardStoreState {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil, cipher != nil else { return .keychainLocked }
        do {
            try keyStore.verifyMasterKeyAccess()
        } catch {
            lockLocked()
            log.error("clipboard master key became unavailable: \(String(describing: error), privacy: .public)")
        }
        return cipher == nil ? .keychainLocked : .ready
    }

    /// Non-interactively verifies keychain access when `.ready`, or attempts to reload an
    /// existing master key when `.keychainLocked` without ever prompting interactively or
    /// creating a new key.
    @discardableResult
    public func tryUnlockNonInteractive() -> ClipboardStoreState {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return .keychainLocked }
        if cipher == nil {
            do {
                guard let key = try keyStore.loadExistingMasterKeyNonInteractive() else {
                    return .keychainLocked
                }
                cipher = ClipboardCipher(masterKey: key)
                hydrateLocked()
            } catch {
                lockLocked()
                log.error("clipboard master key unavailable: \(String(describing: error), privacy: .public)")
            }
        } else {
            do {
                try keyStore.verifyMasterKeyAccess()
            } catch {
                lockLocked()
                log.error("clipboard master key became unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        return cipher == nil ? .keychainLocked : .ready
    }

    /// Re-verifies master-key availability against the key store: unlocks and rebuilds the
    /// `:memory:` search index when locked and now accessible; transitions to `.keychainLocked`
    /// and wipes the derived cipher, previews, and `:memory:` index if the keychain was locked
    /// while the store was running.
    @discardableResult
    public func retryUnlock() -> ClipboardStoreState {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return .keychainLocked }
        if cipher == nil {
            unlockLocked()
        } else {
            do {
                try keyStore.verifyMasterKeyAccess()
            } catch {
                lockLocked()
                log.error("clipboard master key became unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        return cipher == nil ? .keychainLocked : .ready
    }

    /// Checkpoints the WAL and closes both connections; later calls throw `.closed`.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db {
            sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE)", nil, nil, nil)
            sqlite3_close_v2(db)
        }
        if let index { sqlite3_close_v2(index) }
        db = nil
        index = nil
        cipher = nil
        previews = [:]
        unreadable = []
    }

    private func unlockLocked() {
        do {
            cipher = ClipboardCipher(masterKey: try keyStore.loadOrCreateMasterKey())
        } catch {
            lockLocked()
            log.error("clipboard master key unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        hydrateLocked()
    }

    /// Drops all in-memory key material, decrypted previews, and `:memory:` FTS5 tokens when
    /// the keychain locks at runtime.
    private func lockLocked() {
        cipher = nil
        previews = [:]
        unreadable = []
        if let index { _ = try? Self.exec(index, "DELETE FROM clip_fts") }
        diagnosticsValue.indexedRows = 0
    }

    // MARK: Writing

    /// Records `content` copied from `source`, or refreshes the identical entry.
    @discardableResult
    public func insert(_ content: ClipboardEntryContent, source: ClipboardSourceApp?, now: Date = Date()) throws(ClipboardError)
        -> ClipboardEntryMetadata
    {
        switch content {
        case .text(let text):
            return try insertText(text, source: source, now: now)
        case .image(let png, let thumbnail, let width, let height):
            try ClipboardImageProcessor.validateDimensions(width: width, height: height)
            let image = ClipboardImage(
                pngData: png, thumbnailData: thumbnail, width: width, height: height, sha256: Data(SHA256.hash(data: png)).hexString)
            return try insertImage(image, source: source, now: now)
        }
    }

    @discardableResult
    public func insertText(_ text: String, source: ClipboardSourceApp?, now: Date = Date()) throws(ClipboardError) -> ClipboardEntryMetadata {
        let bytes = Data(text.utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyContent }
        guard bytes.count <= quota.maxTextBytes else { throw .textTooLarge(bytes.count) }
        lock.lock()
        defer { lock.unlock() }
        let (db, index, cipher) = try ready()
        let dedup = cipher.dedupHMAC(kind: .text, payload: bytes)
        if let existing = try existingID(db, kind: .text, dedup: dedup) {
            if !unreadable.contains(existing) {
                return try bumpLocked(db, index, id: existing, source: source, now: now)
            }
            // A corrupted row with matching dedup HMAC is replaced cleanly when re-copied.
            try deleteRowsLocked(db, index, ids: [existing])
            unreadable.remove(existing)
            diagnosticsValue.undecryptableRows = unreadable.count
        }
        let id = UUID().uuidString.lowercased()
        let sensitivity = ClipboardPrivacyFilter.classifySensitivity(text)
        let sealed = try cipher.sealText(text, id: id, dedupHMAC: dedup)
        let lines = text.reduce(into: 1) { count, character in if character.isNewline { count += 1 } }
        try insertRow(
            db, id: id, kind: .text, dedup: dedup, source: source, byteSize: bytes.count, charCount: text.count, lineCount: lines,
            blob: nil, payload: sealed, sensitivity: sensitivity, now: now)
        previews[id] = Self.preview(of: text)
        try indexInsert(index, id: id, body: Self.indexBody(text), sourceApp: source?.name)
        try enforceQuotasLocked()
        return try metadataLocked(db, id: id)
    }

    @discardableResult
    public func insertImage(_ image: ClipboardImage, source: ClipboardSourceApp?, now: Date = Date()) throws(ClipboardError)
        -> ClipboardEntryMetadata
    {
        guard !image.pngData.isEmpty else { throw .emptyContent }
        guard image.pngData.count <= quota.maxImageBytes else { throw .imageTooLarge(image.pngData.count) }
        guard image.thumbnailData.count <= quota.maxImageBytes else { throw .imageTooLarge(image.thumbnailData.count) }
        lock.lock()
        defer { lock.unlock() }
        let (db, index, cipher) = try ready()
        let digest = cipher.dedupHMAC(kind: .image, payload: image.pngData)
        if let existing = try existingID(db, kind: .image, dedup: digest) {
            try ensureImageBlobsReadableLocked(cipher, image: image, digest: digest)
            return try bumpLocked(db, index, id: existing, source: source, now: now)
        }
        try ensureImageBlobsReadableLocked(cipher, image: image, digest: digest)
        let id = UUID().uuidString.lowercased()
        do {
            try Self.transaction(db) { () throws(ClipboardError) in
                let statement = try Self.prepare(db, """
                    INSERT OR IGNORE INTO image_blobs(sha256, byte_size, thumbnail_size, width, height, created_at)
                    VALUES(?1, ?2, ?3, ?4, ?5, ?6)
                    """)
                defer { sqlite3_finalize(statement) }
                Self.bind(statement, 1, digest)
                sqlite3_bind_int64(statement, 2, Int64(image.pngData.count))
                sqlite3_bind_int64(statement, 3, Int64(image.thumbnailData.count))
                sqlite3_bind_int64(statement, 4, Int64(image.width))
                sqlite3_bind_int64(statement, 5, Int64(image.height))
                sqlite3_bind_double(statement, 6, now.timeIntervalSince1970)
                try Self.stepDone(db, statement)
                try insertRow(
                    db, id: id, kind: .image, dedup: digest, source: source, byteSize: image.pngData.count, charCount: 0,
                    lineCount: 0, blob: digest, payload: nil, sensitivity: .standard, now: now)
            }
        } catch {
            if (try? Self.scalarInt(db, "SELECT COUNT(*) FROM image_blobs WHERE sha256 = ?1", digest)) == 0 {
                blobs.remove(digest: digest)
            }
            throw error
        }
        try indexInsert(index, id: id, body: "", sourceApp: source?.name)
        try enforceQuotasLocked()
        return try metadataLocked(db, id: id)
    }

    /// Marks an entry used (pasted or copied back): newest in the list, TTL restarted.
    /// Rejects (and deletes) unpinned entries that have already expired as of `now`.
    public func markUsed(id: String, now: Date = Date()) throws(ClipboardError) {
        lock.lock()
        defer { lock.unlock() }
        let (db, index, _) = try ready()
        try rejectIfExpiredLocked(db, index, id: id, now: now)
        try markUsedLocked(db, id: id, now: now)
    }

    /// Atomically verifies `id` has not expired as of `now`, decrypts its payload, and
    /// updates `last_used_at`/`expires_at` under one lock acquisition so an expired entry
    /// can never be pasted back or revived between a read and a mark-used call.
    public func useContent(id: String, now: Date = Date()) throws(ClipboardError) -> ClipboardEntryContent {
        lock.lock()
        defer { lock.unlock() }
        let (db, index, cipher) = try ready()
        try rejectIfExpiredLocked(db, index, id: id, now: now)
        let content = try contentLocked(db, cipher, id: id)
        try markUsedLocked(db, id: id, now: now)
        return content
    }

    public func setPinned(id: String, pinned: Bool, now: Date = Date()) throws(ClipboardError) {
        lock.lock()
        defer { lock.unlock() }
        let (db, index, _) = try ready()
        try rejectIfExpiredLocked(db, index, id: id, now: now)
        let statement = try Self.prepare(db, """
            UPDATE clipboard_items SET pinned = ?5,
              expires_at = CASE WHEN ?5 = 1 THEN NULL
                WHEN sensitivity = 'sensitive' THEN ?2 + ?3 ELSE ?2 + ?4 END
            WHERE id = ?1 AND (pinned = 1 OR expires_at IS NULL OR expires_at > ?2)
            """)
        defer { sqlite3_finalize(statement) }
        bindTimes(statement, id: id, now: now)
        sqlite3_bind_int64(statement, 5, pinned ? 1 : 0)
        try Self.stepDone(db, statement)
        guard sqlite3_changes(db) > 0 else { throw .notFound(id) }
    }

    public func delete(id: String) throws(ClipboardError) {
        lock.lock()
        defer { lock.unlock() }
        let (db, index, _) = try ready()
        try deleteRowsLocked(db, index, ids: [id])
    }

    /// Deletes every unpinned entry; returns how many.
    @discardableResult
    public func clearUnpinned() throws(ClipboardError) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let (db, index, _) = try ready()
        let ids = try Self.strings(db, "SELECT id FROM clipboard_items WHERE pinned = 0")
        try deleteRowsLocked(db, index, ids: ids)
        return ids.count
    }

    /// Deletes unpinned entries whose `expires_at` has passed; returns how many.
    @discardableResult
    public func purgeExpired(now: Date = Date()) throws(ClipboardError) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try purgeExpiredLocked(now: now)
    }

    /// Evicts the oldest unpinned entries past `maxItems`, then the oldest unpinned images
    /// past `maxTotalImageBytes`, then unreferenced blobs.
    public func enforceQuotas() throws(ClipboardError) {
        lock.lock()
        defer { lock.unlock() }
        try enforceQuotasLocked()
    }

    // MARK: Reading

    /// Entries matching `filter` and `query`, most recently used first, excluding unreadable
    /// or already-expired unpinned rows. An empty query lists everything; a query without a
    /// searchable term matches nothing.
    public func items(
        filter: ClipboardFilter = .all, query: String = "", limit: Int = 500, now: Date = Date()
    ) -> [ClipboardEntryMetadata] {
        lock.lock()
        defer { lock.unlock() }
        guard let handles = try? ready() else { return [] }
        let (db, index, _) = handles
        var matches: Set<String>?
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let compiled = ClipboardTokenizer.compileFTSQuery(query),
                  let found = try? Self.strings(index, "SELECT item_id FROM clip_fts WHERE clip_fts MATCH ?1", compiled)
            else { return [] }
            matches = Set(found)
        }
        let clause = switch filter {
        case .all: ""
        case .text: "WHERE i.kind = 'text'"
        case .image: "WHERE i.kind = 'image'"
        case .pinned: "WHERE i.pinned = 1"
        }
        guard let rows = try? metadataRows(db, clause: clause, order: "ORDER BY i.last_used_at DESC, i.created_at DESC") else { return [] }
        return Array(rows.lazy.filter {
            !self.unreadable.contains($0.id)
                && ($0.expiresAt.map { $0 > now } ?? true)
                && (matches?.contains($0.id) ?? true)
        }.prefix(limit))
    }

    /// The ids FTS5 returns for a compiled query (tests and diagnostics); throws on a
    /// SQLite error so callers can prove a query never produces one.
    public func searchIDs(_ query: String) throws(ClipboardError) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let (_, index, _) = try ready()
        guard let compiled = ClipboardTokenizer.compileFTSQuery(query) else { return [] }
        return try Self.strings(index, "SELECT item_id FROM clip_fts WHERE clip_fts MATCH ?1", compiled)
    }

    public func metadata(id: String) throws(ClipboardError) -> ClipboardEntryMetadata {
        lock.lock()
        defer { lock.unlock() }
        let (db, _, _) = try ready()
        return try metadataLocked(db, id: id)
    }

    /// The decrypted payload of `id`; rejects (and deletes) unpinned entries expired as of `now`.
    public func content(id: String, now: Date = Date()) throws(ClipboardError) -> ClipboardEntryContent {
        lock.lock()
        defer { lock.unlock() }
        let (db, index, cipher) = try ready()
        try rejectIfExpiredLocked(db, index, id: id, now: now)
        return try contentLocked(db, cipher, id: id)
    }

    /// The decrypted PNG thumbnail of image entry `id`; rejects expired unpinned entries.
    public func thumbnail(id: String, now: Date = Date()) throws(ClipboardError) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let (db, index, cipher) = try ready()
        try rejectIfExpiredLocked(db, index, id: id, now: now)
        let digests = try Self.strings(db, "SELECT blob_sha256 FROM clipboard_items WHERE id = ?1 AND blob_sha256 IS NOT NULL", id)
        guard let digest = digests.first else { throw .notFound(id) }
        return try cipher.openBlob(try blobs.read(digest: digest, thumbnail: true), digest: digest, thumbnail: true)
    }

    public var itemCount: Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }
        return (try? Self.scalarInt(db, "SELECT COUNT(*) FROM clipboard_items")) ?? 0
    }

    /// Bytes of image blobs (PNG plus thumbnail plaintext sizes).
    public var totalImageBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }
        return (try? Self.scalarInt(db, "SELECT COALESCE(SUM(byte_size + thumbnail_size), 0) FROM image_blobs")) ?? 0
    }

    // MARK: - Internals

    private func ready() throws(ClipboardError) -> (OpaquePointer, OpaquePointer, ClipboardCipher) {
        guard let db, let index else { throw .closed }
        guard let cipher else { throw .storeLocked }
        return (db, index, cipher)
    }

    /// Ensures both the full PNG blob and thumbnail blob for `digest` exist on disk and
    /// decrypt cleanly, rewriting whichever file is missing or corrupted from the freshly
    /// captured `image`.
    private func ensureImageBlobsReadableLocked(_ cipher: ClipboardCipher, image: ClipboardImage, digest: String) throws(ClipboardError) {
        if !isBlobReadable(cipher, digest: digest, thumbnail: false) {
            try blobs.write(try cipher.sealBlob(image.pngData, digest: digest, thumbnail: false), digest: digest, thumbnail: false)
        }
        if !isBlobReadable(cipher, digest: digest, thumbnail: true) {
            try blobs.write(try cipher.sealBlob(image.thumbnailData, digest: digest, thumbnail: true), digest: digest, thumbnail: true)
        }
    }

    private func isBlobReadable(_ cipher: ClipboardCipher, digest: String, thumbnail: Bool) -> Bool {
        guard let sealed = try? blobs.read(digest: digest, thumbnail: thumbnail),
              let plain = try? cipher.openBlob(sealed, digest: digest, thumbnail: thumbnail)
        else { return false }
        if !thumbnail {
            return cipher.dedupHMAC(kind: .image, payload: plain) == digest
        }
        return true
    }

    /// Verifies `id` exists and, if unpinned, has not expired as of `now`. If an unpinned
    /// row's TTL has already elapsed, deletes it immediately and throws `.notFound(id)`.
    private func rejectIfExpiredLocked(
        _ db: OpaquePointer, _ index: OpaquePointer, id: String, now: Date
    ) throws(ClipboardError) {
        let isExpired: Bool = try { () throws(ClipboardError) -> Bool in
            let statement = try Self.prepare(db, "SELECT pinned, expires_at FROM clipboard_items WHERE id = ?1")
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw .notFound(id) }
            let pinned = sqlite3_column_int64(statement, 0) != 0
            guard !pinned, sqlite3_column_type(statement, 1) != SQLITE_NULL else { return false }
            return sqlite3_column_double(statement, 1) <= now.timeIntervalSince1970
        }()
        if isExpired {
            try deleteRowsLocked(db, index, ids: [id])
            throw .notFound(id)
        }
    }

    private func markUsedLocked(_ db: OpaquePointer, id: String, now: Date) throws(ClipboardError) {
        let statement = try Self.prepare(db, """
            UPDATE clipboard_items SET last_used_at = ?2,
              expires_at = CASE WHEN pinned = 1 THEN NULL
                WHEN sensitivity = 'sensitive' THEN ?2 + ?3 ELSE ?2 + ?4 END
            WHERE id = ?1 AND (pinned = 1 OR expires_at IS NULL OR expires_at > ?2)
            """)
        defer { sqlite3_finalize(statement) }
        bindTimes(statement, id: id, now: now)
        try Self.stepDone(db, statement)
        guard sqlite3_changes(db) > 0 else { throw .notFound(id) }
    }

    private func contentLocked(_ db: OpaquePointer, _ cipher: ClipboardCipher, id: String) throws(ClipboardError) -> ClipboardEntryContent {
        let statement = try Self.prepare(db, """
            SELECT i.kind, i.dedup_hmac, i.encrypted_payload, i.blob_sha256, b.width, b.height
            FROM clipboard_items i LEFT JOIN image_blobs b ON b.sha256 = i.blob_sha256 WHERE i.id = ?1
            """)
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw .notFound(id) }
        let dedup = Self.columnString(statement, 1) ?? ""
        if Self.columnString(statement, 0) == ClipboardItemKind.text.rawValue {
            guard let sealed = Self.columnData(statement, 2) else { throw .decryptionFailed }
            return .text(try cipher.openText(sealed, id: id, dedupHMAC: dedup))
        }
        guard let digest = Self.columnString(statement, 3), digest == dedup else { throw .decryptionFailed }
        let png = try cipher.openBlob(try blobs.read(digest: digest, thumbnail: false), digest: digest, thumbnail: false)
        guard cipher.dedupHMAC(kind: .image, payload: png) == digest else { throw .decryptionFailed }
        let thumbnail = try cipher.openBlob(try blobs.read(digest: digest, thumbnail: true), digest: digest, thumbnail: true)
        return .image(
            pngData: png, thumbnailData: thumbnail, width: Int(sqlite3_column_int64(statement, 4)),
            height: Int(sqlite3_column_int64(statement, 5)))
    }

    private func configure(_ db: OpaquePointer) throws(ClipboardError) {
        try Self.exec(db, "PRAGMA journal_mode = WAL")
        try Self.exec(db, "PRAGMA foreign_keys = ON")
        try Self.exec(db, "PRAGMA secure_delete = ON")
        try Self.exec(db, "PRAGMA busy_timeout = 5000")
        try Self.exec(db, "PRAGMA synchronous = NORMAL")
        try Self.exec(db, "PRAGMA temp_store = MEMORY")
        try Self.transaction(db) { () throws(ClipboardError) in
            try Self.exec(db, """
                CREATE TABLE IF NOT EXISTS schema_meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS image_blobs(
                  sha256 TEXT PRIMARY KEY CHECK(length(sha256) = 64),
                  byte_size INTEGER NOT NULL,
                  thumbnail_size INTEGER NOT NULL,
                  width INTEGER NOT NULL,
                  height INTEGER NOT NULL,
                  created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS clipboard_items(
                  id TEXT PRIMARY KEY,
                  kind TEXT NOT NULL CHECK(kind IN ('text', 'image')),
                  dedup_hmac TEXT NOT NULL,
                  source_bundle_id TEXT,
                  source_app_name TEXT,
                  byte_size INTEGER NOT NULL,
                  char_count INTEGER NOT NULL DEFAULT 0,
                  line_count INTEGER NOT NULL DEFAULT 0,
                  blob_sha256 TEXT REFERENCES image_blobs(sha256) ON DELETE RESTRICT,
                  encrypted_payload BLOB,
                  key_version INTEGER NOT NULL,
                  sensitivity TEXT NOT NULL CHECK(sensitivity IN ('standard', 'sensitive')),
                  pinned INTEGER NOT NULL DEFAULT 0,
                  created_at REAL NOT NULL,
                  last_used_at REAL NOT NULL,
                  expires_at REAL,
                  UNIQUE(kind, dedup_hmac)
                );
                CREATE INDEX IF NOT EXISTS clipboard_items_recency ON clipboard_items(pinned, last_used_at);
                CREATE INDEX IF NOT EXISTS clipboard_items_blob ON clipboard_items(blob_sha256);
                INSERT OR IGNORE INTO schema_meta(key, value) VALUES('schema_version', \(Self.schemaVersion));
                PRAGMA user_version = \(Self.schemaVersion);
                """)
        }
    }

    private func hydrateLocked() {
        guard let db, let index, let cipher else { return }
        previews = [:]
        unreadable = []
        var corrupted = 0
        var indexed = 0
        do {
            try Self.exec(index, "DELETE FROM clip_fts")
            let statement = try Self.prepare(db, "SELECT id, kind, dedup_hmac, encrypted_payload, source_app_name FROM clipboard_items")
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = Self.columnString(statement, 0) else { continue }
                let sourceApp = Self.columnString(statement, 4)
                if Self.columnString(statement, 1) == ClipboardItemKind.text.rawValue {
                    guard let sealed = Self.columnData(statement, 3),
                          let text = try? cipher.openText(sealed, id: id, dedupHMAC: Self.columnString(statement, 2) ?? "")
                    else {
                        unreadable.insert(id)
                        corrupted += 1
                        continue
                    }
                    previews[id] = Self.preview(of: text)
                    try indexInsert(index, id: id, body: Self.indexBody(text), sourceApp: sourceApp)
                } else {
                    try indexInsert(index, id: id, body: "", sourceApp: sourceApp)
                }
                indexed += 1
            }
        } catch {
            log.error("clipboard index hydration failed: \(String(describing: error), privacy: .public)")
        }
        if corrupted > 0 { log.error("\(corrupted, privacy: .public) clipboard row(s) failed to decrypt; skipped") }
        diagnosticsValue.undecryptableRows = corrupted
        diagnosticsValue.indexedRows = indexed
    }

    private func existingID(_ db: OpaquePointer, kind: ClipboardItemKind, dedup: String) throws(ClipboardError) -> String? {
        let statement = try Self.prepare(db, "SELECT id FROM clipboard_items WHERE kind = ?1 AND dedup_hmac = ?2")
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, kind.rawValue)
        Self.bind(statement, 2, dedup)
        return sqlite3_step(statement) == SQLITE_ROW ? Self.columnString(statement, 0) : nil
    }

    private func bumpLocked(
        _ db: OpaquePointer, _ index: OpaquePointer, id: String, source: ClipboardSourceApp?, now: Date
    ) throws(ClipboardError) -> ClipboardEntryMetadata {
        let statement = try Self.prepare(db, """
            UPDATE clipboard_items SET last_used_at = ?2, source_bundle_id = ?5, source_app_name = ?6,
              expires_at = CASE WHEN pinned = 1 THEN NULL
                WHEN sensitivity = 'sensitive' THEN ?2 + ?3 ELSE ?2 + ?4 END
            WHERE id = ?1
            """)
        defer { sqlite3_finalize(statement) }
        bindTimes(statement, id: id, now: now)
        Self.bind(statement, 5, source?.bundleID)
        Self.bind(statement, 6, source?.name)
        try Self.stepDone(db, statement)
        let update = try Self.prepare(index, "UPDATE clip_fts SET source_app = ?2 WHERE item_id = ?1")
        defer { sqlite3_finalize(update) }
        Self.bind(update, 1, id)
        Self.bind(update, 2, source?.name.map(ClipboardTokenizer.indexForm))
        try Self.stepDone(index, update)
        return try metadataLocked(db, id: id)
    }

    private func bindTimes(_ statement: OpaquePointer, id: String, now: Date) {
        Self.bind(statement, 1, id)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, quota.sensitiveTTLSeconds)
        sqlite3_bind_double(statement, 4, quota.defaultTTLSeconds)
    }

    private func insertRow(
        _ db: OpaquePointer, id: String, kind: ClipboardItemKind, dedup: String, source: ClipboardSourceApp?, byteSize: Int,
        charCount: Int, lineCount: Int, blob: String?, payload: Data?, sensitivity: ClipboardSensitivity, now: Date
    ) throws(ClipboardError) {
        let statement = try Self.prepare(db, """
            INSERT INTO clipboard_items(id, kind, dedup_hmac, source_bundle_id, source_app_name, byte_size, char_count,
              line_count, blob_sha256, encrypted_payload, key_version, sensitivity, pinned, created_at, last_used_at, expires_at)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 0, ?13, ?13, ?14)
            """)
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, id)
        Self.bind(statement, 2, kind.rawValue)
        Self.bind(statement, 3, dedup)
        Self.bind(statement, 4, source?.bundleID)
        Self.bind(statement, 5, source?.name)
        sqlite3_bind_int64(statement, 6, Int64(byteSize))
        sqlite3_bind_int64(statement, 7, Int64(charCount))
        sqlite3_bind_int64(statement, 8, Int64(lineCount))
        Self.bind(statement, 9, blob)
        Self.bind(statement, 10, payload)
        sqlite3_bind_int64(statement, 11, Int64(ClipboardCipher.keyVersion))
        Self.bind(statement, 12, sensitivity.rawValue)
        sqlite3_bind_double(statement, 13, now.timeIntervalSince1970)
        sqlite3_bind_double(statement, 14, now.timeIntervalSince1970 + quota.ttl(for: sensitivity))
        try Self.stepDone(db, statement)
    }

    private func indexInsert(_ index: OpaquePointer, id: String, body: String, sourceApp: String?) throws(ClipboardError) {
        let statement = try Self.prepare(index, "INSERT INTO clip_fts(item_id, body, source_app) VALUES(?1, ?2, ?3)")
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, id)
        Self.bind(statement, 2, body)
        Self.bind(statement, 3, sourceApp.map(ClipboardTokenizer.indexForm))
        try Self.stepDone(index, statement)
    }

    /// Deletes `ids` and, in the same transaction, every blob row no longer referenced;
    /// then unlinks those blobs and drops the ids from the index and the previews.
    private func deleteRowsLocked(_ db: OpaquePointer, _ index: OpaquePointer, ids: [String]) throws(ClipboardError) {
        guard !ids.isEmpty else { return }
        var freedBlobs: [String] = []
        try Self.transaction(db) { () throws(ClipboardError) in
            var candidates = Set<String>()
            for id in ids {
                candidates.formUnion(try Self.strings(
                    db, "SELECT blob_sha256 FROM clipboard_items WHERE id = ?1 AND blob_sha256 IS NOT NULL", id))
                try Self.run(db, "DELETE FROM clipboard_items WHERE id = ?1", id)
            }
            for digest in candidates.sorted() {
                guard try Self.scalarInt(db, "SELECT COUNT(*) FROM clipboard_items WHERE blob_sha256 = ?1", digest) == 0 else { continue }
                try Self.run(db, "DELETE FROM image_blobs WHERE sha256 = ?1", digest)
                freedBlobs.append(digest)
            }
        }
        for digest in freedBlobs { blobs.remove(digest: digest) }
        if !freedBlobs.isEmpty { FileSafety.syncDirectory(blobs.directory) }
        for id in ids {
            try Self.run(index, "DELETE FROM clip_fts WHERE item_id = ?1", id)
            previews.removeValue(forKey: id)
            unreadable.remove(id)
        }
    }

    @discardableResult
    private func purgeExpiredLocked(now: Date) throws(ClipboardError) -> Int {
        guard let db, let index else { throw .closed }
        let statement = try Self.prepare(
            db, "SELECT id FROM clipboard_items WHERE pinned = 0 AND expires_at IS NOT NULL AND expires_at <= ?1")
        var ids: [String] = []
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = Self.columnString(statement, 0) { ids.append(id) }
        }
        sqlite3_finalize(statement)
        try deleteRowsLocked(db, index, ids: ids)
        return ids.count
    }

    private func enforceQuotasLocked() throws(ClipboardError) {
        guard let db, let index else { throw .closed }
        let count = try Self.scalarInt(db, "SELECT COUNT(*) FROM clipboard_items")
        if count > quota.maxItems {
            let victims = try Self.strings(
                db, "SELECT id FROM clipboard_items WHERE pinned = 0 ORDER BY last_used_at ASC, created_at ASC LIMIT \(count - quota.maxItems)")
            try deleteRowsLocked(db, index, ids: victims)
        }
        while try Self.scalarInt(db, "SELECT COALESCE(SUM(byte_size + thumbnail_size), 0) FROM image_blobs") > quota.maxTotalImageBytes {
            let victims = try Self.strings(db, """
                SELECT id FROM clipboard_items WHERE kind = 'image' AND pinned = 0
                ORDER BY last_used_at ASC, created_at ASC LIMIT 1
                """)
            guard !victims.isEmpty else { break }
            try deleteRowsLocked(db, index, ids: victims)
        }
    }

    /// Drops blob rows no item references, then every blob file without a row.
    private func collectOrphansLocked() {
        guard let db else { return }
        var removed = 0
        do {
            let orphans = try Self.strings(
                db, "SELECT sha256 FROM image_blobs WHERE sha256 NOT IN (SELECT blob_sha256 FROM clipboard_items WHERE blob_sha256 IS NOT NULL)")
            for digest in orphans {
                try Self.run(db, "DELETE FROM image_blobs WHERE sha256 = ?1", digest)
                blobs.remove(digest: digest)
                removed += 1
            }
            removed += blobs.removeOrphans(keeping: Set(try Self.strings(db, "SELECT sha256 FROM image_blobs")))
        } catch {
            log.error("clipboard orphan collection failed: \(String(describing: error), privacy: .public)")
        }
        diagnosticsValue.orphansRemoved = removed
    }

    private func metadataLocked(_ db: OpaquePointer, id: String) throws(ClipboardError) -> ClipboardEntryMetadata {
        guard let row = try metadataRows(db, clause: "WHERE i.id = ?1", order: "", argument: id).first else { throw .notFound(id) }
        return row
    }

    private func metadataRows(_ db: OpaquePointer, clause: String, order: String, argument: String? = nil) throws(ClipboardError)
        -> [ClipboardEntryMetadata]
    {
        let statement = try Self.prepare(db, """
            SELECT i.id, i.kind, i.source_bundle_id, i.source_app_name, i.byte_size, i.char_count, i.line_count,
              i.blob_sha256, i.sensitivity, i.pinned, i.created_at, i.last_used_at, i.expires_at, i.key_version, b.width, b.height
            FROM clipboard_items i LEFT JOIN image_blobs b ON b.sha256 = i.blob_sha256 \(clause) \(order)
            """)
        defer { sqlite3_finalize(statement) }
        if let argument { Self.bind(statement, 1, argument) }
        var rows: [ClipboardEntryMetadata] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = Self.columnString(statement, 0) else { continue }
            let kind = ClipboardItemKind(rawValue: Self.columnString(statement, 1) ?? "") ?? .text
            let isImage = kind == .image
            rows.append(ClipboardEntryMetadata(
                id: id, kind: kind,
                source: ClipboardSourceApp(bundleID: Self.columnString(statement, 2), name: Self.columnString(statement, 3)),
                byteSize: Int(sqlite3_column_int64(statement, 4)), charCount: Int(sqlite3_column_int64(statement, 5)),
                lineCount: Int(sqlite3_column_int64(statement, 6)),
                imageWidth: isImage ? Int(sqlite3_column_int64(statement, 14)) : nil,
                imageHeight: isImage ? Int(sqlite3_column_int64(statement, 15)) : nil,
                blobDigest: Self.columnString(statement, 7),
                sensitivity: ClipboardSensitivity(rawValue: Self.columnString(statement, 8) ?? "") ?? .sensitive,
                isPinned: sqlite3_column_int64(statement, 9) != 0,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                expiresAt: sqlite3_column_type(statement, 12) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
                preview: previews[id], keyVersion: Int(sqlite3_column_int64(statement, 13))))
        }
        return rows
    }

    static func preview(of text: String) -> String {
        let head = text.prefix(previewLength * 2)
        let flattened = head.map { $0.isNewline || $0 == "\t" ? " " : String($0) }.joined()
        return String(flattened.trimmingCharacters(in: .whitespaces).prefix(previewLength))
    }

    static func indexBody(_ text: String) -> String {
        ClipboardTokenizer.indexForm(String(text.prefix(indexedCharacterLimit)))
    }

    // MARK: Files

    /// The database and its sidecars must be regular files when they exist.
    static func refuseNonRegularFiles(at url: URL) throws(ClipboardError) {
        for path in [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"] {
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { throw .notRegularFile(path) }
        }
    }

    static func createPrivateFile(at url: URL) throws(ClipboardError) {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? .notRegularFile(url.path) : .openFailed(url.path, code: errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile(url.path) }
    }

    static func restrictPermissions(of url: URL) {
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 != 0o600 { chmod(path, 0o600) }
        }
    }

    // MARK: SQLite helpers

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String?) {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let text { sqlite3_bind_text(statement, index, text, -1, sqliteTransient) } else { sqlite3_bind_null(statement, index) }
    }

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ data: Data?) {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard let data else {
            sqlite3_bind_null(statement, index)
            return
        }
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
    }

    static func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    static func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    static func error(_ db: OpaquePointer, _ what: String) -> ClipboardError {
        .sqlite("\(what): \(String(cString: sqlite3_errmsg(db)))", code: sqlite3_extended_errcode(db))
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws(ClipboardError) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db, String(sql.prefix(40))) }
    }

    static func prepare(_ db: OpaquePointer, _ sql: String) throws(ClipboardError) -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error(db, "prepare") }
        return statement
    }

    static func stepDone(_ db: OpaquePointer, _ statement: OpaquePointer) throws(ClipboardError) {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(db, "step") }
    }

    /// Runs `sql` with text arguments `?1`, `?2`, ….
    static func run(_ db: OpaquePointer, _ sql: String, _ arguments: String...) throws(ClipboardError) {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        for (offset, argument) in arguments.enumerated() { bind(statement, Int32(offset + 1), argument) }
        try stepDone(db, statement)
    }

    static func strings(_ db: OpaquePointer, _ sql: String, _ arguments: String...) throws(ClipboardError) -> [String] {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        for (offset, argument) in arguments.enumerated() { bind(statement, Int32(offset + 1), argument) }
        var result: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: if let value = columnString(statement, 0) { result.append(value) }
            case SQLITE_DONE: return result
            default: throw error(db, "query")
            }
        }
    }

    static func scalarInt(_ db: OpaquePointer, _ sql: String, _ arguments: String...) throws(ClipboardError) -> Int {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        for (offset, argument) in arguments.enumerated() { bind(statement, Int32(offset + 1), argument) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error(db, "scalar") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func transaction(_ db: OpaquePointer, _ body: () throws(ClipboardError) -> Void) throws(ClipboardError) {
        try exec(db, "BEGIN IMMEDIATE")
        do {
            try body()
            try exec(db, "COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }
}
