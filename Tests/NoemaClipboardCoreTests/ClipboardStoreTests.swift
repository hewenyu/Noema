import CryptoKit
import Foundation
@testable import NoemaClipboardCore
import NoemaCore
import SQLite3
import Testing

/// The real on-disk store in a temporary directory with an in-memory key store.
@Suite struct ClipboardStoreTests {
    static let source = ClipboardSourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 42)

    static func open(_ dir: TemporaryDirectory, keys: InMemoryClipboardKeyStore, quota: ClipboardStorageQuota = .default, now: Date = Date()) throws -> ClipboardStore {
        try ClipboardStore(directory: dir.store, keyStore: keys, quota: quota, now: now)
    }

    /// Runs `sql` on the database file through a separate connection (tests only).
    static func rawSQL(_ url: URL, _ sql: String) -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
        }
        return rows
    }

    /// A row's `encrypted_payload`, read through a separate connection.
    static func rawPayload(_ url: URL, id: String) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close_v2(db) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var select: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT encrypted_payload FROM clipboard_items WHERE id = ?1", -1, &select, nil)
        defer { sqlite3_finalize(select) }
        sqlite3_bind_text(select, 1, id, -1, transient)
        guard sqlite3_step(select) == SQLITE_ROW, let bytes = sqlite3_column_blob(select, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(select, 0)))
    }

    static func flipPayloadByte(_ url: URL, id: String, at offset: Int) {
        guard var payload = rawPayload(url, id: id) else { return }
        payload[offset] ^= 0xFF
        setRawPayload(url, id: id, payload)
    }

    /// Overwrites a row's `encrypted_payload` through a separate connection.
    static func setRawPayload(_ url: URL, id: String, _ payload: Data) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close_v2(db) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var update: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE clipboard_items SET encrypted_payload = ?2 WHERE id = ?1", -1, &update, nil)
        sqlite3_bind_text(update, 1, id, -1, transient)
        payload.withUnsafeBytes { _ = sqlite3_bind_blob(update, 2, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_step(update)
        sqlite3_finalize(update)
    }

    // MARK: Encryption at rest

    @Test func nothingPlaintextReachesTheDisk() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let keys = InMemoryClipboardKeyStore()
        let store = try Self.open(dir, keys: keys)
        let needle = "NoemaPlaintextCanary-你好世界-4f2a"
        let item = try store.insertText(needle + " and more text", source: Self.source)
        let canary = "sk" + "-canary" + String(repeating: "a", count: 16)
        try store.insertText(canary, source: Self.source)
        let png = TestImages.png(width: 120, height: 80, seed: 9)
        let image = try store.insertImage(try ClipboardImageProcessor.process(png), source: Self.source)
        #expect(item.preview?.hasPrefix(needle) == true && image.imageWidth == 120)

        func assertClean(_ phase: String) {
            #expect(RawDisk.scan(dir.store, for: Data(needle.utf8)) == 0, "plaintext on disk \(phase)")
            #expect(RawDisk.scan(dir.store, for: Data("你好世界".utf8)) == 0, "CJK plaintext on disk \(phase)")
            #expect(RawDisk.scan(dir.store, for: Data("sk-canary".utf8)) == 0, "secret on disk \(phase)")
            #expect(RawDisk.scan(dir.store, for: pngMagic) == 0, "PNG header on disk \(phase)")
            #expect(RawDisk.scan(dir.store, for: png.subdata(in: 16..<48)) == 0, "PNG bytes on disk \(phase)")
        }
        let files = RawDisk.files(under: dir.store).map(\.lastPathComponent)
        #expect(files.contains("clipboard.sqlite") && files.contains("clipboard.sqlite-wal"))
        #expect(files.filter { $0.hasSuffix(".enc") }.count == 2)
        assertClean("with the WAL live")

        // No FTS table, no plaintext column on disk.
        let tables = Self.rawSQL(store.databaseURL, "SELECT name, sql FROM sqlite_master")
        #expect(!tables.isEmpty && !tables.contains { $0.joined().lowercased().contains("fts") })

        // Permissions: 0700 directories, 0600 files.
        #expect(RawDisk.mode(dir.store) == 0o700 && RawDisk.mode(store.blobs.directory) == 0o700)
        for file in RawDisk.files(under: dir.store) { #expect(RawDisk.mode(file) == 0o600, "\(file.lastPathComponent)") }

        // Decrypts back.
        #expect(try store.content(id: item.id) == .text(needle + " and more text"))
        guard case .image(let roundTrip, _, 120, 80) = try store.content(id: image.id) else {
            Issue.record("image did not round-trip")
            return
        }
        #expect(roundTrip == png)
        store.close()
        assertClean("after the checkpoint")

        let reopened = try Self.open(dir, keys: keys)
        #expect(reopened.items().count == 3 && reopened.diagnostics.undecryptableRows == 0)
        #expect(reopened.items(query: "你好").map(\.id) == [item.id])
        reopened.close()
    }

    @Test func tamperedSwappedAndWrongKeyRowsAreSkipped() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let keys = InMemoryClipboardKeyStore()
        let store = try Self.open(dir, keys: keys)
        let a = try store.insertText("alpha entry", source: Self.source)
        let b = try store.insertText("bravo entry", source: Self.source)
        let c = try store.insertText("charlie entry", source: Self.source)
        let url = store.databaseURL
        store.close()

        // Swap a's and b's payloads (AAD mismatch), and flip one byte of c's.
        let payloadA = try #require(Self.rawPayload(url, id: a.id))
        let payloadB = try #require(Self.rawPayload(url, id: b.id))
        Self.setRawPayload(url, id: a.id, payloadB)
        Self.setRawPayload(url, id: b.id, payloadA)
        Self.flipPayloadByte(url, id: c.id, at: 20)
        let tampered = try Self.open(dir, keys: keys)
        #expect(tampered.diagnostics.undecryptableRows == 3, "corrupted rows are skipped, never crash")
        #expect(tampered.items().isEmpty && tampered.items(query: "alpha").isEmpty)
        #expect(throws: ClipboardError.decryptionFailed) { try tampered.content(id: a.id) }
        #expect(throws: ClipboardError.decryptionFailed) { try tampered.content(id: c.id) }
        let d = try tampered.insertText("delta entry", source: Self.source)
        #expect(tampered.items().map(\.id) == [d.id])
        tampered.close()

        let wrongKey = try Self.open(dir, keys: InMemoryClipboardKeyStore())
        #expect(wrongKey.diagnostics.undecryptableRows == 4 && wrongKey.items().isEmpty)
        wrongKey.close()
    }

    @Test func lockedKeychainRefusesWritesAndRecovers() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let keys = InMemoryClipboardKeyStore()
        let first = try Self.open(dir, keys: keys)
        let saved = try first.insertText("before the lock", source: Self.source)
        first.close()
        let originalKey = keys.key.map { $0.withUnsafeBytes { Data($0) } }

        keys.isLocked = true
        let locked = try Self.open(dir, keys: keys)
        #expect(locked.state == .keychainLocked)
        #expect(locked.items().isEmpty)
        #expect(throws: ClipboardError.storeLocked) { try locked.insertText("during the lock canary", source: Self.source) }
        #expect(throws: ClipboardError.storeLocked) { try locked.content(id: saved.id) }
        #expect(locked.itemCount == 1, "no row was written")
        #expect(RawDisk.scan(dir.store, for: Data("during the lock canary".utf8)) == 0)
        #expect(keys.creationCount == 1 && keys.key.map { $0.withUnsafeBytes { Data($0) } } == originalKey, "the key is never replaced")
        #expect(locked.retryUnlock() == .keychainLocked)

        keys.isLocked = false
        #expect(locked.retryUnlock() == .ready)
        #expect(locked.items().map(\.id) == [saved.id] && locked.items(query: "lock").count == 1)
        #expect(try locked.content(id: saved.id) == .text("before the lock"))

        // Codex PR #23 round 2: runtime keychain lock transitions `.ready` -> `.keychainLocked`,
        // wipes `:memory:` FTS5 and refuses reads/writes until unlocked again.
        keys.isLocked = true
        #expect(locked.retryUnlock() == .keychainLocked)
        #expect(locked.state == .keychainLocked && locked.items().isEmpty && locked.diagnostics.indexedRows == 0)
        #expect(throws: ClipboardError.storeLocked) { try locked.insertText("after runtime lock", source: Self.source) }
        #expect(throws: ClipboardError.storeLocked) { try locked.useContent(id: saved.id) }
        keys.isLocked = false
        #expect(locked.retryUnlock() == .ready)
        #expect(locked.items(query: "lock").map(\.id) == [saved.id])
        locked.close()
    }

    // MARK: Search

    @Test func cjkAndMixedSearch() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let store = try Self.open(dir, keys: InMemoryClipboardKeyStore())
        let hello = try store.insertText("你好世界", source: Self.source)
        let peace = try store.insertText("世界和平", source: Self.source)
        let mixed = try store.insertText("学习 Swift 你好编程", source: ClipboardSourceApp(bundleID: "com.apple.Notes", name: "备忘录"))
        let english = try store.insertText("Hello, World! café", source: Self.source)
        func ids(_ query: String) -> Set<String> { Set(store.items(query: query).map(\.id)) }

        #expect(ids("你") == [hello.id, mixed.id])
        #expect(ids("你好") == [hello.id, mixed.id])
        #expect(ids("你好世") == [hello.id])
        #expect(ids("世界") == [hello.id, peace.id])
        #expect(ids("你好 swift") == [mixed.id])
        #expect(ids("swift你好") == [mixed.id])
        #expect(ids("世你").isEmpty, "reversed characters are not adjacent")
        #expect(ids("好你").isEmpty)
        #expect(ids("hel") == [english.id], "prefix match")
        #expect(ids("CAFE") == [english.id], "case and diacritics folded")
        #expect(ids("备忘") == [mixed.id], "the source app is searchable")
        #expect(ids("").count == 4)

        for hostile in ["\"", "*", "OR", "NOT", "AND", "NEAR/5", "foo:bar", "(((", ")", "\"你好", "-swift", "^hello", "body:你好", "NEAR(a b)", "'", ";"] {
            #expect(throws: Never.self) { try store.searchIDs(hostile) }
            _ = store.items(query: hostile)
        }
        #expect(ids("\"你好").count == 2, "a stray quote is plain text")

        try store.delete(id: hello.id)
        #expect(ids("你好") == [mixed.id])
        #expect(try store.searchIDs("你好世").isEmpty)
        store.close()
    }

    // MARK: Dedup, quotas, TTL

    @Test func textDedupRefreshesTheExistingRow() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let store = try Self.open(dir, keys: InMemoryClipboardKeyStore())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try store.insertText("same text", source: Self.source, now: t0)
        try store.setPinned(id: first.id, pinned: true, now: t0)
        let second = try store.insertText("same text", source: ClipboardSourceApp(bundleID: "com.apple.Safari", name: "Safari"), now: t0 + 60)
        #expect(second.id == first.id && store.itemCount == 1)
        #expect(second.lastUsedAt == t0 + 60 && second.source.name == "Safari" && second.isPinned && second.expiresAt == nil)
        #expect(store.items(query: "safari", now: t0 + 60).map(\.id) == [first.id])
        #expect(store.items(query: "textedit", now: t0 + 60).isEmpty)
        // Re-copying from a CJK app re-tokenizes `source_app` in `:memory:` FTS5.
        let third = try store.insertText("same text", source: ClipboardSourceApp(bundleID: "com.apple.Notes", name: "备忘录"), now: t0 + 120)
        #expect(third.id == first.id && third.source.name == "备忘录")
        #expect(store.items(query: "备忘", now: t0 + 120).map(\.id) == [first.id])
        #expect(store.items(query: "safari", now: t0 + 120).isEmpty)
        #expect(throws: ClipboardError.emptyContent) { try store.insertText("  \n ", source: nil) }
        #expect(throws: ClipboardError.imageDimensionsRejected(width: 20_000, height: 20_000)) {
            try store.insert(.image(pngData: Data([1]), thumbnailData: Data([1]), width: 20_000, height: 20_000), source: nil)
        }
        #expect(throws: ClipboardError.imageTooLarge(store.quota.maxImageBytes + 1)) {
            try store.insert(
                .image(pngData: Data([1]), thumbnailData: Data(count: store.quota.maxImageBytes + 1), width: 1, height: 1),
                source: nil)
        }
        store.close()
    }

    @Test func opensUnderNestedMissingParentDirectories() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let nested = dir.url.appending(path: "missing/Noema/clipboard", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: nested.deletingLastPathComponent().path))
        let store = try ClipboardStore(directory: nested, keyStore: InMemoryClipboardKeyStore())
        let item = try store.insertText("fresh install", source: Self.source)
        #expect(store.items().map(\.id) == [item.id])
        #expect(RawDisk.mode(nested) == 0o700 && RawDisk.mode(store.blobs.directory) == 0o700)
        store.close()
    }

    @Test func recopyingCorruptedRowHealsIt() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let keys = InMemoryClipboardKeyStore()
        let store = try Self.open(dir, keys: keys)
        let original = try store.insertText("healable secret phrase", source: Self.source)
        let dbURL = store.databaseURL
        store.close()

        // Corrupt `encrypted_payload` while keeping `dedup_hmac` intact.
        _ = Self.rawSQL(dbURL, "UPDATE clipboard_items SET encrypted_payload = X'00112233' WHERE id = '\(original.id)'")
        let reopened = try Self.open(dir, keys: keys)
        #expect(reopened.diagnostics.undecryptableRows == 1 && reopened.items().isEmpty)

        // Re-copying identical text replaces the corrupted row and restores search + decryption.
        let healed = try reopened.insertText("healable secret phrase", source: Self.source)
        #expect(healed.id != original.id && reopened.itemCount == 1)
        #expect(reopened.diagnostics.undecryptableRows == 0)
        #expect(reopened.items(query: "healable").map(\.id) == [healed.id])
        #expect(try reopened.content(id: healed.id) == .text("healable secret phrase"))
        reopened.close()
    }

    @Test func imagesDedupAndShareBlobsUntilTheLastReference() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let store = try Self.open(dir, keys: InMemoryClipboardKeyStore())
        let image = try ClipboardImageProcessor.process(TestImages.png(seed: 5))
        let first = try store.insertImage(image, source: Self.source)
        let again = try store.insertImage(image, source: Self.source)
        #expect(first.id == again.id && store.itemCount == 1)
        let encFiles = { RawDisk.files(under: store.blobs.directory).map(\.lastPathComponent).sorted() }
        #expect(encFiles() == ["\(first.blobDigest!).enc", "\(first.blobDigest!).thumb.enc"])
        #expect(store.items(filter: .image).count == 1 && store.items(filter: .text).isEmpty)

        // A blob still referenced is never unlinked (ON DELETE RESTRICT holds the row too).
        #expect(Self.rawSQL(store.databaseURL, "DELETE FROM image_blobs").isEmpty)
        #expect(Self.rawSQL(store.databaseURL, "SELECT COUNT(*) FROM image_blobs") == [["1"]])

        try store.setPinned(id: first.id, pinned: true)
        #expect(try store.clearUnpinned() == 0 && encFiles().count == 2)
        try store.delete(id: first.id)
        #expect(encFiles().isEmpty && store.totalImageBytes == 0)
        store.close()
    }

    @Test func imageByteQuotaEvictsOldestUnpinnedImages() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let images = try (1...4).map { try ClipboardImageProcessor.process(TestImages.png(width: 64, height: 64, seed: UInt8($0), noise: true)) }
        let perImage = images.map { $0.pngData.count + $0.thumbnailData.count }.max()!
        let quota = ClipboardStorageQuota(maxTotalImageBytes: perImage * 2 + perImage / 2)
        let store = try Self.open(dir, keys: InMemoryClipboardKeyStore(), quota: quota)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try store.insertImage(images[0], source: Self.source, now: t0)
        try store.setPinned(id: a.id, pinned: true, now: t0)
        let b = try store.insertImage(images[1], source: Self.source, now: t0 + 1)
        let c = try store.insertImage(images[2], source: Self.source, now: t0 + 2)
        #expect(Set(store.items(now: t0 + 3).map(\.id)) == [a.id, c.id], "b is the oldest unpinned image")
        let d = try store.insertImage(images[3], source: Self.source, now: t0 + 3)
        #expect(Set(store.items(now: t0 + 4).map(\.id)) == [a.id, d.id], "the pinned image survives LRU")
        #expect(store.totalImageBytes <= quota.maxTotalImageBytes)
        let names = Set(RawDisk.files(under: store.blobs.directory).map(\.lastPathComponent))
        #expect(names == [a.blobDigest!, d.blobDigest!].reduce(into: Set<String>()) { $0.insert("\($1).enc"); $0.insert("\($1).thumb.enc") })
        #expect(!names.contains("\(b.blobDigest!).enc") && !names.contains("\(c.blobDigest!).enc"))
        store.close()
    }

    @Test func itemQuotaEvictsOldestUnpinnedAndDropsThemFromSearch() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let store = try Self.open(dir, keys: InMemoryClipboardKeyStore(), quota: ClipboardStorageQuota(maxItems: 3))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let oldest = try store.insertText("oldest pinned", source: nil, now: t0)
        try store.setPinned(id: oldest.id, pinned: true, now: t0)
        let evicted = try store.insertText("evicted entry zulu", source: nil, now: t0 + 1)
        for index in 2...4 { try store.insertText("entry \(index)", source: nil, now: t0 + Double(index)) }
        #expect(store.itemCount == 3)
        let ids = store.items(now: t0 + 10).map(\.id)
        #expect(ids.contains(oldest.id) && !ids.contains(evicted.id))
        #expect(try store.searchIDs("zulu").isEmpty)
        #expect(throws: ClipboardError.textTooLarge(store.quota.maxTextBytes + 1)) {
            try store.insertText(String(repeating: "x", count: store.quota.maxTextBytes + 1), source: nil)
        }
        store.close()
    }

    @Test func ttlExpiresUnpinnedAndSensitiveSooner() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let store = try Self.open(dir, keys: InMemoryClipboardKeyStore())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let standard = try store.insertText("ordinary note", source: nil, now: t0)
        let syntheticToken = "token " + "ghp" + "_" + String(repeating: "a", count: 24)
        let secret = try store.insertText(syntheticToken, source: nil, now: t0)
        let pinned = try store.insertText("keep me", source: nil, now: t0)
        try store.setPinned(id: pinned.id, pinned: true, now: t0)
        #expect(secret.sensitivity == .sensitive && standard.sensitivity == .standard)
        #expect(secret.expiresAt == t0 + 15 * 60 && standard.expiresAt == t0 + 30 * 86_400)

        #expect(try store.purgeExpired(now: t0 + 14 * 60) == 0)
        // Expired secrets disappear from `items(now:)` immediately, even before `purgeExpired`.
        #expect(Set(store.items(now: t0 + 16 * 60).map(\.id)) == [standard.id, pinned.id])
        #expect(try store.purgeExpired(now: t0 + 16 * 60) == 1)
        #expect(Set(store.items(now: t0 + 16 * 60).map(\.id)) == [standard.id, pinned.id])
        #expect(try store.searchIDs("ghp").isEmpty)
        #expect(try store.purgeExpired(now: t0 + 31 * 86_400) == 1)
        #expect(store.items(now: t0 + 31 * 86_400).map(\.id) == [pinned.id], "pinned entries never expire")
        // Using an entry restarts its TTL; unpinning restores one.
        try store.setPinned(id: pinned.id, pinned: false, now: t0 + 31 * 86_400)
        #expect(try store.metadata(id: pinned.id).expiresAt == t0 + 61 * 86_400)
        store.close()

        // Expired rows are also purged when the store opens.
        let reopened = try ClipboardStore(directory: dir.store, keyStore: InMemoryClipboardKeyStore(), now: t0 + 400 * 86_400)
        #expect(reopened.itemCount == 0)
        reopened.close()
    }

    /// Codex PR #23 round 2: an expired unpinned row cannot be read, pasted, marked used, or
    /// pinned even before periodic `purgeExpired` runs.
    @Test func expiredEntryCannotBeReadOrRevivedBeforePurge() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let store = try Self.open(dir, keys: InMemoryClipboardKeyStore())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredAt = t0 + 16 * 60
        let tokenA = "token " + "sk" + "-" + String(repeating: "m", count: 20)
        let tokenB = "token " + "sk" + "-" + String(repeating: "n", count: 20)
        let tokenC = "token " + "sk" + "-" + String(repeating: "p", count: 20)
        let tokenD = "token " + "sk" + "-" + String(repeating: "q", count: 20)
        let a = try store.insertText(tokenA, source: nil, now: t0)
        let b = try store.insertText(tokenB, source: nil, now: t0)
        let c = try store.insertText(tokenC, source: nil, now: t0)
        let d = try store.insertText(tokenD, source: nil, now: t0)

        #expect(throws: ClipboardError.notFound(a.id)) { _ = try store.content(id: a.id, now: expiredAt) }
        #expect(throws: ClipboardError.notFound(b.id)) { try store.markUsed(id: b.id, now: expiredAt) }
        #expect(throws: ClipboardError.notFound(c.id)) { try store.setPinned(id: c.id, pinned: true, now: expiredAt) }
        #expect(throws: ClipboardError.notFound(d.id)) { _ = try store.useContent(id: d.id, now: expiredAt) }
        #expect(store.itemCount == 0, "rejected expired rows are deleted rather than left revivable")
        store.close()
    }

    // MARK: Files

    @Test func startupCollectsOrphanBlobs() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let keys = InMemoryClipboardKeyStore()
        let store = try Self.open(dir, keys: keys)
        let kept = try store.insertImage(try ClipboardImageProcessor.process(TestImages.png(seed: 11)), source: nil)
        let blobs = store.blobs.directory
        store.close()
        let orphan = String(repeating: "c", count: 64)
        try Data("x".utf8).write(to: blobs.appending(path: "\(orphan).enc"))
        try Data("x".utf8).write(to: blobs.appending(path: "\(orphan).thumb.enc"))
        try Data("x".utf8).write(to: blobs.appending(path: ".tmp.leftover"))
        try Data("x".utf8).write(to: blobs.appending(path: "NOTHEX.enc"))
        let reopened = try Self.open(dir, keys: keys)
        #expect(reopened.diagnostics.orphansRemoved == 4)
        #expect(Set(RawDisk.files(under: blobs).map(\.lastPathComponent)) == ["\(kept.blobDigest!).enc", "\(kept.blobDigest!).thumb.enc"])
        #expect(reopened.items().count == 1)
        reopened.close()
    }

    @Test func symlinksAreRefused() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let elsewhere = dir.url.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        // The store directory itself.
        try FileManager.default.createSymbolicLink(at: dir.store, withDestinationURL: elsewhere)
        #expect(throws: ClipboardError.notPrivateDirectory(dir.store.path)) { try Self.open(dir, keys: InMemoryClipboardKeyStore()) }
        try FileManager.default.removeItem(at: dir.store)

        // The database file.
        try FileManager.default.createDirectory(at: dir.store, withIntermediateDirectories: true)
        let target = elsewhere.appending(path: "target.sqlite")
        try Data().write(to: target)
        let resolvedPath = try #require(realpath(dir.store.path, nil))
        let resolved = URL(filePath: String(cString: resolvedPath))
        free(resolvedPath)
        try FileManager.default.createSymbolicLink(at: dir.store.appending(path: "clipboard.sqlite"), withDestinationURL: target)
        #expect(throws: ClipboardError.notRegularFile(resolved.appending(path: "clipboard.sqlite").path)) {
            try Self.open(dir, keys: InMemoryClipboardKeyStore())
        }
        try FileManager.default.removeItem(at: dir.store.appending(path: "clipboard.sqlite"))

        // A WAL sidecar.
        try FileManager.default.createSymbolicLink(at: dir.store.appending(path: "clipboard.sqlite-wal"), withDestinationURL: target)
        #expect(throws: ClipboardError.notRegularFile(resolved.appending(path: "clipboard.sqlite-wal").path)) {
            try Self.open(dir, keys: InMemoryClipboardKeyStore())
        }
        try FileManager.default.removeItem(at: dir.store.appending(path: "clipboard.sqlite-wal"))

        // The blobs directory.
        try? FileManager.default.removeItem(at: dir.store.appending(path: "blobs"))
        try FileManager.default.createSymbolicLink(at: dir.store.appending(path: "blobs"), withDestinationURL: elsewhere)
        #expect(throws: ClipboardError.self) { try Self.open(dir, keys: InMemoryClipboardKeyStore()) }
        try FileManager.default.removeItem(at: dir.store.appending(path: "blobs"))

        // A blob file planted as a symlink is never followed on read.
        let store = try Self.open(dir, keys: InMemoryClipboardKeyStore())
        let digest = String(repeating: "d", count: 64)
        try FileManager.default.createSymbolicLink(at: store.blobs.directory.appending(path: "\(digest).enc"), withDestinationURL: target)
        #expect(throws: ClipboardError.self) { try store.blobs.read(digest: digest, thumbnail: false) }
        #expect(throws: ClipboardError.invalidDigest("../escape")) { try store.blobs.url(digest: "../escape", thumbnail: false) }
        #expect(!ClipboardBlobStore.isValidDigest(String(repeating: "A", count: 64)))
        store.close()
        #expect(RawDisk.mode(dir.store) == 0o700)
    }
}
