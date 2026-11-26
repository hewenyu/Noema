import Darwin
import Foundation
import NoemaCore
import NoemaText
import SQLite3

/// One commit to learn, as captured on the main actor. Raw on purpose: `enqueue` only
/// copies it, and `LearningStore.recordBatch` normalizes it off the hot path.
public struct LearningCommitEvent: Sendable, Hashable {
    /// The engine's raw input before the commit (e.g. `nihao`).
    public var rawInput: String
    /// The preedit before the commit (e.g. `ni hao`); its separators give the syllables.
    public var preedit: String
    public var text: String
    /// True for a phrase the user added explicitly rather than one learned from typing.
    public var isUserPhrase: Bool
    public var timestamp: Date
    /// False when the commit came from a schema that does not spell Mandarin pinyin (Wubi,
    /// Cangjie, Zhuyin, Jyutping; see `CommitObservation.isMandarinPinyinSchema`): its raw
    /// codes may look like syllables (Wubi 98 `wo` for 伙) but are not readings, so
    /// `normalized()` refuses it.
    public var isMandarinPinyinSchema: Bool

    public init(
        rawInput: String, preedit: String = "", text: String, isUserPhrase: Bool = false, timestamp: Date = Date(),
        isMandarinPinyinSchema: Bool = true
    ) {
        self.rawInput = rawInput
        self.preedit = preedit
        self.text = text
        self.isUserPhrase = isUserPhrase
        self.timestamp = timestamp
        self.isMandarinPinyinSchema = isMandarinPinyinSchema
    }

    public init(observation: CommitObservation, timestamp: Date = Date()) {
        self.init(
            rawInput: observation.rawInput, preedit: observation.preedit, text: observation.committedText,
            timestamp: timestamp, isMandarinPinyinSchema: observation.isMandarinPinyinSchema)
    }

    /// Longest phrase and spelling the store learns; longer commits are pastes, not words.
    public static let maximumTextScalars = 32
    public static let maximumPinyinScalars = 256

    /// The canonical `(pinyin_norm, pinyin_compact, text)` of this event, or nil when it is
    /// not learnable: committed on a non-Mandarin-pinyin schema, no Han character, a control character (tab, newline) in the text, an
    /// oversized text, or a spelling that is not verifiably full Mandarin pinyin. Leading
    /// and trailing punctuation, symbols, and spaces are trimmed first (`nihao,` commits
    /// `你好，`; `你好` is learned). `pinyinNorm` is always one standard Mandarin syllable
    /// (`TextNormalization.standardMandarinSyllables`) per Han character, never abbreviated
    /// initials or raw double-pinyin keys; see `canonicalSyllables`.
    public func normalized() -> (pinyinNorm: String, pinyinCompact: String, text: String)? {
        guard isMandarinPinyinSchema else { return nil }
        let text = Self.trimmingEdgePunctuation(self.text)
        guard !text.isEmpty, text.unicodeScalars.count <= Self.maximumTextScalars,
              TextNormalization.containsHanCharacters(text),
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              let syllables = Self.canonicalSyllables(text: text, preedit: preedit, rawInput: rawInput)
        else { return nil }
        let key = syllables.joined(separator: " ")
        guard !key.isEmpty, key.unicodeScalars.count <= Self.maximumPinyinScalars else { return nil }
        return (key, syllables.joined(), text)
    }

    /// The full-pinyin syllables of the Han characters of `text`, one per character, or nil.
    /// The preedit's syllables (`tonelessPinyinKey`; a double-pinyin schema's preedit
    /// already spells full pinyin, `uijx` shows `shi jia`) are checked one by one against
    /// the system's Mandarin reading of `text` (`mandarinPinyinSyllables`):
    /// - equal to the reading, or a standard syllable the reading does not start with (the
    ///   user's own polyphone reading, `hang` in `hang ye` for 行业): kept as typed;
    /// - a proper prefix of the reading (jianpin: `n h` for 女孩, `shi j` for 时间): the
    ///   reading (`nv hai`, `shi jian`);
    /// - anything else (`x y` for 你好): nil, the commit is not learned.
    /// Without a reading (a character the transform does not know), every preedit syllable
    /// must be standard. When the preedit does not give one syllable per Han character (it
    /// held Han text, or was empty), the raw input must spell the reading as consecutive
    /// prefixes (`nihao`, `nh` for 你好 and 女孩), and the reading is used.
    static func canonicalSyllables(text: String, preedit: String, rawInput: String) -> [String]? {
        var han = String.UnicodeScalarView()
        han.append(contentsOf: text.unicodeScalars.filter(TextNormalization.isHanIdeograph))
        let count = han.count
        let reading = TextNormalization.mandarinPinyinSyllables(for: String(han))
        let typed = TextNormalization.containsHanCharacters(preedit)
            ? []
            : TextNormalization.tonelessPinyinKey(preedit).split(separator: " ").map { syllable in
                // `lue`/`nue` is how many schemas spell `lve`/`nve`.
                syllable == "lue" || syllable == "nue" ? String(syllable.prefix(1)) + "ve" : String(syllable)
            }
        if typed.count == count {
            var result: [String] = []
            for (index, observed) in typed.enumerated() {
                if let full = reading?[index], full != observed, full.hasPrefix(observed) {
                    result.append(full)
                } else if reading?[index] == observed || TextNormalization.isStandardMandarinSyllable(observed) {
                    result.append(observed)
                } else {
                    return nil
                }
            }
            return result
        }
        guard let reading else { return nil }
        let raw = Array(TextNormalization.compactPinyinKey(rawInput).utf8)
        return spellsAsPrefixes(raw, of: reading.map { Array($0.utf8) }) ? reading : nil
    }

    /// Whether `raw` splits into `syllables.count` non-empty runs, each a prefix of its
    /// syllable in order (`shij` of `shi jian`, `nihao` of `ni hao`).
    static func spellsAsPrefixes(_ raw: [UInt8], of syllables: [[UInt8]]) -> Bool {
        // reachable[i]: the first i bytes of `raw` are consumed by the syllables so far.
        var reachable = [Bool](repeating: false, count: raw.count + 1)
        reachable[0] = true
        for syllable in syllables {
            var next = [Bool](repeating: false, count: raw.count + 1)
            for start in 0..<raw.count where reachable[start] {
                var length = 0
                while length < syllable.count, start + length < raw.count, raw[start + length] == syllable[length] {
                    length += 1
                    next[start + length] = true
                }
            }
            reachable = next
        }
        return !raw.isEmpty && reachable[raw.count]
    }

    /// `text` without leading and trailing Unicode punctuation (`P*`), symbols (`S*`),
    /// separators (`Z*`), and whitespace.
    static func trimmingEdgePunctuation(_ text: String) -> String {
        func isEdge(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
                 .spaceSeparator, .lineSeparator, .paragraphSeparator:
                true
            default:
                scalar.properties.isWhitespace
            }
        }
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isEdge($0) }),
              let last = scalars.lastIndex(where: { !isEdge($0) })
        else { return "" }
        var trimmed = String.UnicodeScalarView()
        trimmed.append(contentsOf: scalars[first...last])
        return String(trimmed)
    }
}

/// A learned phrase in `learning.sqlite`.
public struct LearnedEntry: Sendable, Hashable {
    public var id: Int64
    /// Toneless syllables separated by one space (`ni hao`).
    public var pinyinNorm: String
    /// `pinyinNorm` without spaces (`nihao`): what `noema_learned.lua` looks typed input up by.
    public var pinyinCompact: String
    public var text: String
    public var frequency: Int64
    public var isUserPhrase: Bool
    public var updatedAt: Date
    /// Monotonic store revision of the last change to this entry.
    public var revision: Int64

    public init(
        id: Int64, pinyinNorm: String, pinyinCompact: String, text: String, frequency: Int64,
        isUserPhrase: Bool, updatedAt: Date, revision: Int64
    ) {
        self.id = id
        self.pinyinNorm = pinyinNorm
        self.pinyinCompact = pinyinCompact
        self.text = text
        self.frequency = frequency
        self.isUserPhrase = isUserPhrase
        self.updatedAt = updatedAt
        self.revision = revision
    }
}

extension LearnedEntry {
    /// Whether the entry can be written as one tab-separated line: `text`, `pinyinNorm`, and
    /// `pinyinCompact` are non-empty and free of control characters (tab, newline, CR, NUL),
    /// and `text` does not start with `#` (a comment line). `normalized()` never stores
    /// anything else; this guards every TSV writer against a store edited behind its back.
    public var isSafeForTSV: Bool {
        func clean(_ field: String) -> Bool {
            !field.isEmpty && !field.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        return clean(text) && clean(pinyinNorm) && clean(pinyinCompact) && !text.hasPrefix("#")
    }
}

/// How far `learning.sqlite` has been projected into one userdb of one schema set. Keyed by
/// `(schemaSet, dictName)`: two schemas of one set with their own user dicts each keep their
/// own watermark, and schemas sharing a user dict share one.
public struct ProjectionWatermark: Sendable, Hashable, Codable {
    public var schemaSet: String
    /// The userdb (`<dictName>.userdb`) the watermark belongs to.
    public var dictName: String
    public var lastRevision: Int64
    public var projectedCount: Int64
    public var updatedAt: Date
    /// How the projected codes are spelled (`NoemaEngine.UserDictCodeFormat`: `toneless`
    /// `ni hao`, `unicodeToned` `ní hào`). A guardian projecting another spelling replays
    /// every entry instead of trusting `lastRevision`.
    public var codeFormat: String
}

public struct LearningStoreStats: Sendable, Hashable, Codable {
    public var entryCount: Int64
    public var userPhraseCount: Int64
    public var totalFrequency: Int64
    public var latestRevision: Int64
    public var watermarks: [ProjectionWatermark]
}

public enum LearningStoreError: Error, Hashable, Sendable {
    /// `learning.sqlite`, `-wal`, or `-shm` is a symlink or another non-regular file.
    case notRegularFile(String)
    case openFailed(String, code: Int32)
    case sqlite(String, code: Int32)
    /// The database's `user_version` is one this build does not know.
    case unsupportedSchemaVersion(Int32)
    /// A write was attempted on a `.readOnly` store, or the store is closed.
    case notWritable
}

/// The canonical learning store, `learning.sqlite` (WAL). Each schema set's userdb is a
/// projection of it and can be rebuilt from it.
///
/// - The database and its `-wal`/`-shm` must be regular files: each is `lstat`ed before
///   opening and the main file is opened with `SQLITE_OPEN_NOFOLLOW`, so a planted symlink
///   is refused. A newly created database is `0600`.
/// - `.readWrite` sets `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=500`,
///   `foreign_keys=ON`, `temp_store=MEMORY` and creates schema version 1; `.readOnly`
///   (`SQLITE_OPEN_READONLY`, `query_only`) never writes and needs an existing version-1 file.
///
/// Thread-safe: one connection, serialized by a lock.
public final class LearningStore: @unchecked Sendable {
    public enum Mode: Sendable, Hashable {
        case readWrite
        case readOnly
    }

    public static let schemaVersion: Int32 = 1

    /// The database file, with its directory's symlinks resolved.
    public let url: URL
    public let mode: Mode
    private let lock = NSLock()
    private var db: OpaquePointer?

    /// Opens (`.readWrite`: creates) the store at `url`. Symlinked ancestor directories
    /// (`/var` -> `/private/var`) are resolved first, because `SQLITE_OPEN_NOFOLLOW` refuses a
    /// symlink anywhere in the path; the database file and its sidecars themselves must
    /// never be symlinks.
    public init(url: URL, mode: Mode = .readWrite) throws(LearningStoreError) {
        let parent = url.deletingLastPathComponent()
        guard let resolved = realpath(parent.path, nil) else { throw .openFailed(parent.path, code: errno) }
        let url = URL(filePath: String(cString: resolved), directoryHint: .isDirectory).appending(path: url.lastPathComponent)
        free(resolved)
        self.url = url
        self.mode = mode
        try Self.refuseNonRegularFiles(at: url)
        if mode == .readWrite { try Self.createPrivateFile(at: url) }
        var handle: OpaquePointer?
        let flags = (mode == .readWrite ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY)
            | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2"
            sqlite3_close_v2(handle)
            throw .openFailed("\(url.path): \(message)", code: status)
        }
        db = handle
        do {
            try configure()
            // The sidecars exist now; refuse them too if something raced a link in.
            try Self.refuseNonRegularFiles(at: url)
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    /// Closes the connection; later calls throw `.notWritable` or return nothing.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: Writing

    /// Records each learnable event in one `BEGIN IMMEDIATE` transaction: a new phrase is
    /// inserted with frequency 1, a known one gains 1 and the newest timestamp. Every changed
    /// entry gets the next store revision. Returns how many events were recorded.
    @discardableResult
    public func recordBatch(_ events: [LearningCommitEvent]) throws(LearningStoreError) -> Int {
        let rows = events.compactMap { event -> (String, String, String, Bool, Date)? in
            guard let key = event.normalized() else { return nil }
            return (key.pinyinNorm, key.pinyinCompact, key.text, event.isUserPhrase, event.timestamp)
        }
        guard !rows.isEmpty else { return 0 }
        return try withWriteTransaction { db throws(LearningStoreError) in
            var revision = try Self.metaValue(db, "revision") ?? 0
            let sql = """
                INSERT INTO entries(pinyin_norm, pinyin_compact, text, frequency, is_user_phrase, updated_at, revision)
                VALUES(?1, ?2, ?3, 1, ?4, ?5, ?6)
                ON CONFLICT(pinyin_norm, text) DO UPDATE SET
                  frequency = frequency + 1,
                  is_user_phrase = max(is_user_phrase, excluded.is_user_phrase),
                  updated_at = max(updated_at, excluded.updated_at),
                  revision = excluded.revision
                """
            let statement = try Self.prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            for (norm, compact, text, isUserPhrase, timestamp) in rows {
                revision += 1
                sqlite3_reset(statement)
                Self.bind(statement, 1, norm)
                Self.bind(statement, 2, compact)
                Self.bind(statement, 3, text)
                sqlite3_bind_int64(statement, 4, isUserPhrase ? 1 : 0)
                sqlite3_bind_double(statement, 5, timestamp.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 6, revision)
                try Self.stepDone(db, statement)
            }
            try Self.setMetaValue(db, "revision", revision)
            return rows.count
        }
    }

    /// Merges entries carried over from another store (a legacy userdb) in one `BEGIN
    /// IMMEDIATE` transaction: a new phrase is inserted with `frequency` (at least 1), a known
    /// one keeps the larger of its own and `frequency`. Only a changed row gets the next store
    /// revision, so importing the same entries again changes nothing. Events that do not
    /// normalize are skipped. Returns how many rows were inserted or raised.
    @discardableResult
    public func importMigratedEntries(_ entries: [(event: LearningCommitEvent, frequency: Int64)]) throws(LearningStoreError) -> Int {
        let rows = entries.compactMap { entry -> (String, String, String, Int64, Bool, Date)? in
            guard let key = entry.event.normalized() else { return nil }
            return (key.pinyinNorm, key.pinyinCompact, key.text, max(entry.frequency, 1), entry.event.isUserPhrase, entry.event.timestamp)
        }
        guard !rows.isEmpty else { return 0 }
        return try withWriteTransaction { db throws(LearningStoreError) in
            var revision = try Self.metaValue(db, "revision") ?? 0
            let sql = """
                INSERT INTO entries(pinyin_norm, pinyin_compact, text, frequency, is_user_phrase, updated_at, revision)
                VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT(pinyin_norm, text) DO UPDATE SET
                  frequency = excluded.frequency,
                  updated_at = max(updated_at, excluded.updated_at),
                  revision = excluded.revision
                WHERE excluded.frequency > entries.frequency
                """
            let statement = try Self.prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            var changed = 0
            for (norm, compact, text, frequency, isUserPhrase, timestamp) in rows {
                sqlite3_reset(statement)
                Self.bind(statement, 1, norm)
                Self.bind(statement, 2, compact)
                Self.bind(statement, 3, text)
                sqlite3_bind_int64(statement, 4, frequency)
                sqlite3_bind_int64(statement, 5, isUserPhrase ? 1 : 0)
                sqlite3_bind_double(statement, 6, timestamp.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 7, revision + 1)
                try Self.stepDone(db, statement)
                if sqlite3_changes(db) > 0 {
                    revision += 1
                    changed += 1
                }
            }
            try Self.setMetaValue(db, "revision", revision)
            return changed
        }
    }

    /// The `codeFormat` of a watermark written without one, and of every row that predates
    /// the `code_format` column (Noema projected only toneless codes then).
    public static let defaultCodeFormat = "toneless"

    /// Records that `<dictName>.userdb` of `schemaSet` holds every entry up to `lastRevision`,
    /// its codes spelled `codeFormat`.
    public func setWatermark(
        for schemaSet: SchemaSetID, dictName: String, lastRevision: Int64, projectedCount: Int64,
        codeFormat: String = LearningStore.defaultCodeFormat, at date: Date = Date()
    ) throws(LearningStoreError) {
        try withWriteTransaction { db throws(LearningStoreError) in
            let statement = try Self.prepare(db, """
                INSERT INTO projection_watermarks(schema_set, dict_name, last_revision, projected_count, updated_at, code_format)
                VALUES(?1, ?2, ?3, ?4, ?5, ?6)
                ON CONFLICT(schema_set, dict_name) DO UPDATE SET last_revision = excluded.last_revision,
                  projected_count = excluded.projected_count, updated_at = excluded.updated_at,
                  code_format = excluded.code_format
                """)
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, 1, schemaSet.rawValue)
            Self.bind(statement, 2, dictName)
            sqlite3_bind_int64(statement, 3, lastRevision)
            sqlite3_bind_int64(statement, 4, projectedCount)
            sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
            Self.bind(statement, 6, codeFormat)
            try Self.stepDone(db, statement)
        }
    }

    /// Forgets the watermark of `<dictName>.userdb` (nil: of every userdb of the set), so its
    /// next projection replays every entry. Other userdbs of the set keep theirs.
    public func resetWatermark(for schemaSet: SchemaSetID, dictName: String? = nil) throws(LearningStoreError) {
        try withWriteTransaction { db throws(LearningStoreError) in
            let statement = try Self.prepare(
                db, "DELETE FROM projection_watermarks WHERE schema_set = ?1 AND (?2 IS NULL OR dict_name = ?2)")
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, 1, schemaSet.rawValue)
            if let dictName { Self.bind(statement, 2, dictName) } else { sqlite3_bind_null(statement, 2) }
            try Self.stepDone(db, statement)
        }
    }

    // MARK: Reading

    /// Entries changed after `revision`, oldest change first.
    public func entriesSince(revision: Int64) throws(LearningStoreError) -> [LearnedEntry] {
        try queryEntries("WHERE revision > ?1 ORDER BY revision ASC", revision)
    }

    /// Every entry, most frequent first, then most recent.
    public func allEntries() throws(LearningStoreError) -> [LearnedEntry] {
        try queryEntries("ORDER BY frequency DESC, updated_at DESC, id ASC", nil)
    }

    /// The watermark of `<dictName>.userdb` in `schemaSet`; nil when it was never projected.
    public func watermark(for schemaSet: SchemaSetID, dictName: String) throws(LearningStoreError) -> ProjectionWatermark? {
        try watermarks().first { $0.schemaSet == schemaSet.rawValue && $0.dictName == dictName }
    }

    public func latestRevision() throws(LearningStoreError) -> Int64 {
        try withConnection { db throws(LearningStoreError) in try Self.metaValue(db, "revision") ?? 0 }
    }

    public func stats() throws(LearningStoreError) -> LearningStoreStats {
        let marks = try watermarks()
        return try withConnection { db throws(LearningStoreError) in
            let statement = try Self.prepare(
                db, "SELECT count(*), coalesce(sum(is_user_phrase), 0), coalesce(sum(frequency), 0) FROM entries")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.error(db, "stats") }
            return LearningStoreStats(
                entryCount: sqlite3_column_int64(statement, 0),
                userPhraseCount: sqlite3_column_int64(statement, 1),
                totalFrequency: sqlite3_column_int64(statement, 2),
                latestRevision: try Self.metaValue(db, "revision") ?? 0,
                watermarks: marks)
        }
    }

    /// The connection's `journal_mode` (`wal` once opened read-write).
    public func journalMode() throws(LearningStoreError) -> String {
        try withConnection { db throws(LearningStoreError) in
            let statement = try Self.prepare(db, "PRAGMA journal_mode")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                throw Self.error(db, "journal_mode")
            }
            return String(cString: text)
        }
    }

    /// Every watermark, by set then userdb. A `.readOnly` connection to a store whose
    /// `projection_watermarks` predates `dict_name` (a read-write open migrates it) reads none.
    private func watermarks() throws(LearningStoreError) -> [ProjectionWatermark] {
        try withConnection { db throws(LearningStoreError) in
            guard try Self.hasPerDictWatermarks(db) else { return [] }
            // A `.readOnly` connection may see a table that predates `code_format`.
            let format = try Self.hasWatermarkColumn(db, "code_format") ? "code_format" : "'\(Self.defaultCodeFormat)'"
            let statement = try Self.prepare(db, """
                SELECT schema_set, dict_name, last_revision, projected_count, updated_at, \(format)
                FROM projection_watermarks ORDER BY schema_set, dict_name
                """)
            defer { sqlite3_finalize(statement) }
            var result: [ProjectionWatermark] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw Self.error(db, "watermarks") }
                result.append(ProjectionWatermark(
                    schemaSet: Self.columnString(statement, 0),
                    dictName: Self.columnString(statement, 1),
                    lastRevision: sqlite3_column_int64(statement, 2),
                    projectedCount: sqlite3_column_int64(statement, 3),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    codeFormat: Self.columnString(statement, 5)))
            }
        }
    }

    private func queryEntries(_ clause: String, _ revision: Int64?) throws(LearningStoreError) -> [LearnedEntry] {
        try withConnection { db throws(LearningStoreError) in
            let statement = try Self.prepare(db, """
                SELECT id, pinyin_norm, pinyin_compact, text, frequency, is_user_phrase, updated_at, revision
                FROM entries \(clause)
                """)
            defer { sqlite3_finalize(statement) }
            if let revision { sqlite3_bind_int64(statement, 1, revision) }
            var result: [LearnedEntry] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw Self.error(db, "entries") }
                result.append(LearnedEntry(
                    id: sqlite3_column_int64(statement, 0),
                    pinyinNorm: Self.columnString(statement, 1),
                    pinyinCompact: Self.columnString(statement, 2),
                    text: Self.columnString(statement, 3),
                    frequency: sqlite3_column_int64(statement, 4),
                    isUserPhrase: sqlite3_column_int64(statement, 5) != 0,
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    revision: sqlite3_column_int64(statement, 7)))
            }
        }
    }

    // MARK: Connection

    private func configure() throws(LearningStoreError) {
        try withConnection { db throws(LearningStoreError) in
            sqlite3_busy_timeout(db, 500)
            if mode == .readWrite {
                try Self.exec(db, """
                    PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=500;
                    PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;
                    """)
            } else {
                try Self.exec(db, "PRAGMA busy_timeout=500; PRAGMA temp_store=MEMORY; PRAGMA query_only=ON;")
            }
            let version = try Self.userVersion(db)
            switch (version, mode) {
            case (Self.schemaVersion, .readWrite):
                try Self.migrateWatermarksToPerDict(db)
                try Self.addWatermarkCodeFormat(db)
            case (Self.schemaVersion, .readOnly):
                return
            case (0, .readWrite):
                try Self.exec(db, """
                    BEGIN IMMEDIATE;
                    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
                    CREATE TABLE IF NOT EXISTS entries(
                      id INTEGER PRIMARY KEY,
                      pinyin_norm TEXT NOT NULL,
                      pinyin_compact TEXT NOT NULL,
                      text TEXT NOT NULL,
                      frequency INTEGER NOT NULL DEFAULT 1,
                      is_user_phrase INTEGER NOT NULL DEFAULT 0,
                      updated_at REAL NOT NULL,
                      revision INTEGER NOT NULL,
                      UNIQUE(pinyin_norm, text));
                    CREATE INDEX IF NOT EXISTS entries_revision ON entries(revision);
                    \(Self.watermarksTableSQL)
                    INSERT OR IGNORE INTO meta(key, value) VALUES('revision', 0);
                    PRAGMA user_version = 1;
                    COMMIT;
                    """)
            default:
                throw .unsupportedSchemaVersion(version)
            }
        }
    }

    /// `projection_watermarks`, one row per `(schema_set, dict_name)`.
    static let watermarksTableSQL = """
        CREATE TABLE IF NOT EXISTS projection_watermarks(
          schema_set TEXT NOT NULL,
          dict_name TEXT NOT NULL,
          last_revision INTEGER NOT NULL,
          projected_count INTEGER NOT NULL,
          updated_at REAL NOT NULL,
          code_format TEXT NOT NULL DEFAULT '\(defaultCodeFormat)',
          PRIMARY KEY (schema_set, dict_name));
        """

    /// Whether `projection_watermarks` has its `dict_name` column.
    static func hasPerDictWatermarks(_ db: OpaquePointer) throws(LearningStoreError) -> Bool {
        try hasWatermarkColumn(db, "dict_name")
    }

    /// Whether `projection_watermarks` has the column `name` (a fixed identifier).
    static func hasWatermarkColumn(_ db: OpaquePointer, _ name: String) throws(LearningStoreError) -> Bool {
        let statement = try prepare(db, "SELECT count(*) FROM pragma_table_info('projection_watermarks') WHERE name = ?1")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, name)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error(db, "table_info") }
        return sqlite3_column_int64(statement, 0) > 0
    }

    /// Adds `code_format` to a pre-release per-userdb `projection_watermarks`. Its rows keep
    /// their revisions as `toneless`, the only spelling Noema projected before the column.
    static func addWatermarkCodeFormat(_ db: OpaquePointer) throws(LearningStoreError) {
        guard try !hasWatermarkColumn(db, "code_format") else { return }
        try exec(db, "BEGIN IMMEDIATE")
        do throws(LearningStoreError) {
            if try !hasWatermarkColumn(db, "code_format") {
                try exec(db, "ALTER TABLE projection_watermarks ADD COLUMN code_format TEXT NOT NULL DEFAULT '\(defaultCodeFormat)'")
            }
            try exec(db, "COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Replaces a pre-release `projection_watermarks` keyed by set alone (no `dict_name`)
    /// with the per-userdb table. Its rows are dropped, not carried over: a per-set row
    /// cannot say which userdb it covered, so every userdb conservatively replays every
    /// entry on its next projection. `entries` and `meta` are untouched.
    static func migrateWatermarksToPerDict(_ db: OpaquePointer) throws(LearningStoreError) {
        guard try !hasPerDictWatermarks(db) else { return }
        try exec(db, "BEGIN IMMEDIATE")
        do throws(LearningStoreError) {
            // Re-checked under the write lock: another writer may have migrated meanwhile.
            if try !hasPerDictWatermarks(db) {
                try exec(db, "DROP TABLE IF EXISTS projection_watermarks;\n\(watermarksTableSQL)")
            }
            try exec(db, "COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func withConnection<T>(_ body: (OpaquePointer) throws(LearningStoreError) -> T) throws(LearningStoreError) -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw .notWritable }
        return try body(db)
    }

    private func withWriteTransaction<T>(_ body: (OpaquePointer) throws(LearningStoreError) -> T) throws(LearningStoreError) -> T {
        guard mode == .readWrite else { throw .notWritable }
        return try withConnection { db throws(LearningStoreError) in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do throws(LearningStoreError) {
                let result = try body(db)
                try Self.exec(db, "COMMIT")
                return result
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    // MARK: Files

    /// The database and its WAL sidecars, each of which must be absent or a regular file.
    static func refuseNonRegularFiles(at url: URL) throws(LearningStoreError) {
        for path in [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"] {
            var info = stat()
            if lstat(path, &info) != 0 {
                if errno == ENOENT { continue }
                throw .openFailed(path, code: errno)
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile(path) }
        }
    }

    /// Creates the database file `0600` with `O_NOFOLLOW` if it does not exist yet.
    static func createPrivateFile(at url: URL) throws(LearningStoreError) {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? .notRegularFile(url.path) : .openFailed(url.path, code: errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile(url.path) }
    }

    // MARK: SQLite helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    static func columnString(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    static func error(_ db: OpaquePointer, _ what: String) -> LearningStoreError {
        .sqlite("\(what): \(String(cString: sqlite3_errmsg(db)))", code: sqlite3_extended_errcode(db))
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws(LearningStoreError) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db, sql.prefix(40).description) }
    }

    static func prepare(_ db: OpaquePointer, _ sql: String) throws(LearningStoreError) -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error(db, "prepare")
        }
        return statement
    }

    static func stepDone(_ db: OpaquePointer, _ statement: OpaquePointer) throws(LearningStoreError) {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(db, "step") }
    }

    static func userVersion(_ db: OpaquePointer) throws(LearningStoreError) -> Int32 {
        let statement = try prepare(db, "PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error(db, "user_version") }
        return sqlite3_column_int(statement, 0)
    }

    static func metaValue(_ db: OpaquePointer, _ key: String) throws(LearningStoreError) -> Int64? {
        let statement = try prepare(db, "SELECT value FROM meta WHERE key = ?1")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return sqlite3_column_int64(statement, 0)
        case SQLITE_DONE: return nil
        default: throw error(db, "meta")
        }
    }

    static func setMetaValue(_ db: OpaquePointer, _ key: String, _ value: Int64) throws(LearningStoreError) {
        let statement = try prepare(
            db, "INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        sqlite3_bind_int64(statement, 2, value)
        try stepDone(db, statement)
    }
}
