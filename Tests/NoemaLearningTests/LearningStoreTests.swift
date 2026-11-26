import Darwin
import Foundation
import NoemaCore
import NoemaLearning
import NoemaText
import SQLite3
import Testing

/// A throwaway directory; removed when the test's value goes out of scope.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "noema-learning-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var store: URL { url.appending(path: "learning.sqlite") }
}

func event(_ raw: String, _ text: String, preedit: String = "", at seconds: TimeInterval = 1_000) -> LearningCommitEvent {
    LearningCommitEvent(rawInput: raw, preedit: preedit, text: text, timestamp: Date(timeIntervalSince1970: seconds))
}

func permissions(_ url: URL) -> mode_t {
    var info = stat()
    _ = lstat(url.path, &info)
    return info.st_mode & 0o777
}

@Suite struct LearningStoreTests {
    @Test func opensInWALModeWithPrivatePermissionsAndSchemaVersion1() throws {
        let directory = try TemporaryDirectory()
        let store = try LearningStore(url: directory.store)
        #expect(try store.journalMode() == "wal")
        #expect(permissions(store.url) == 0o600)
        try store.recordBatch([event("nihao", "你好")])
        #expect(FileSafety.isRegularFile(URL(filePath: store.url.path + "-wal")))
        store.close()

        var db: OpaquePointer?
        #expect(sqlite3_open_v2(directory.store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 1)
    }

    @Test func recordBatchUpsertsFrequencyAndAssignsRevisions() throws {
        let directory = try TemporaryDirectory()
        let store = try LearningStore(url: directory.store)
        let recorded = try store.recordBatch([
            event("nihao", "你好", preedit: "ni hao", at: 10),
            event("nihao", "你好", preedit: "ni hao", at: 20),
            event("shijie", "世界", at: 15),
            event("hello", "hello"),          // no Han character
            event("tab", "你\t好"),            // control character
            event("", "你好"),                // no spelling
            event("1234", "你好"),             // digits only: empty key
        ])
        #expect(recorded == 3)
        let entries = try store.allEntries()
        #expect(entries.map(\.text) == ["你好", "世界"])
        #expect(entries[0].pinyinNorm == "ni hao" && entries[0].pinyinCompact == "nihao" && entries[0].frequency == 2)
        #expect(entries[0].updatedAt == Date(timeIntervalSince1970: 20))
        #expect(entries[1].pinyinNorm == "shi jie" && entries[1].frequency == 1)
        #expect(try store.latestRevision() == 3)
        #expect(entries[0].revision == 2 && entries[1].revision == 3)
        #expect(try store.entriesSince(revision: 2).map(\.text) == ["世界"])
    }

    /// `nihao,` commits `你好，`: the learned phrase is `你好`. Edge punctuation, symbols, and
    /// spaces are trimmed; what is left must hold a Han character.
    @Test func normalizationTrimsEdgePunctuationSymbolsAndSpaces() {
        #expect(event("nihao", "你好，", preedit: "ni hao").normalized()?.text == "你好")
        #expect(event("nihao", "「你好」。", preedit: "ni hao").normalized()?.text == "你好")
        #expect(event("nihao", "  你好! ", preedit: "ni hao").normalized()?.text == "你好")
        #expect(event("nihao", "\u{3000}你好¥", preedit: "ni hao").normalized()?.text == "你好")
        #expect(event("nihao", "你，好", preedit: "ni hao").normalized()?.text == "你，好")
        #expect(event("nihao", "，。！").normalized() == nil)
        #expect(event("nihao", "，abc。").normalized() == nil)
        #expect(event("nihao", "你\t好").normalized() == nil)
    }

    @Test func normalizationKeysFullPinyinFromThePreeditOrTheReading() {
        #expect(event("nihao", "你好", preedit: "ni hao").normalized()?.pinyinNorm == "ni hao")
        // A preedit holding Han text: the raw input spells the reading; never pair tail
        // syllables alone against a trimmed Han prefix (`你xiao` for `你😄` must not learn `xiao -> 你`).
        #expect(event("nihao", "你好", preedit: "你 hao").normalized()?.pinyinNorm == "ni hao")
        #expect(event("nixiao", "你😄", preedit: "你xiao").normalized() == nil)
        #expect(event("nime", "你me", preedit: "你me").normalized() == nil)
        #expect(event("nihaoshijian", "你好时间", preedit: "你好shi jian").normalized()?.pinyinNorm == "ni hao shi jian")
        #expect(event("xian", "西安", preedit: "xi'an").normalized()?.pinyinNorm == "xi an")
        #expect(event("xian", "西安").normalized()?.pinyinNorm == "xi an")
        #expect(event("lv", "绿", preedit: "lü").normalized()?.pinyinNorm == "lv")
        #expect(event("lue", "略", preedit: "lue").normalized()?.pinyinNorm == "lve")
        // Out-of-dictionary text and the user's own polyphone reading are kept as typed.
        #expect(event("nihao", "霓昊", preedit: "ni hao").normalized()?.pinyinNorm == "ni hao")
        #expect(event("yinhang", "银行", preedit: "yin hang").normalized()?.pinyinNorm == "yin hang")
        #expect(event("hangy", "行业", preedit: "hang y").normalized()?.pinyinNorm == "hang ye")
        #expect(event("nihao", String(repeating: "好", count: 33)).normalized() == nil)
    }

    /// Double pinyin: the preedit spells full pinyin, never the raw keys.
    @Test func doublePinyinIsLearnedUnderTheFullPinyinPreedit() {
        let shuangpin = event("uijx", "施加", preedit: "shi jia").normalized()
        #expect(shuangpin?.pinyinNorm == "shi jia" && shuangpin?.pinyinCompact == "shijia")
        // Raw double-pinyin keys alone never become a key.
        #expect(event("uijx", "施加").normalized() == nil)
    }

    /// Jianpin: abbreviated initials resolve to the full reading; a spelling that does not
    /// abbreviate the reading is not learned.
    @Test func abbreviatedPinyinIsLearnedUnderTheFullReading() {
        #expect(event("nh", "女孩", preedit: "n h").normalized()?.pinyinNorm == "nv hai")
        #expect(event("shij", "时间", preedit: "shi j").normalized()?.pinyinNorm == "shi jian")
        #expect(event("nh", "女孩").normalized()?.pinyinNorm == "nv hai")
        #expect(event("shij", "时间", preedit: "shij").normalized()?.pinyinNorm == "shi jian")
        #expect(event("ax", "爱心", preedit: "a x").normalized()?.pinyinNorm == "ai xin")
        #expect(event("xy", "你好", preedit: "x y").normalized() == nil)
        #expect(event("xy", "你好").normalized() == nil)
        #expect(event("yh", "银行", preedit: "y h").normalized() == nil)
    }

    @Test(arguments: [
        ("女孩", ["nv", "hai"]), ("旅游", ["lv", "you"]), ("绿茶", ["lv", "cha"]), ("时间", ["shi", "jian"]),
        ("施加", ["shi", "jia"]), ("略", ["lve"]), ("虐", ["nve"]), ("儿", ["er"]), ("哦", ["o"]),
    ])
    func mandarinReading(_ text: String, _ expected: [String]) {
        #expect(TextNormalization.mandarinPinyinSyllables(for: text) == expected)
    }

    @Test func mandarinReadingNeedsAllHanTextAndStandardSyllables() {
        #expect(TextNormalization.mandarinPinyinSyllables(for: "") == nil)
        #expect(TextNormalization.mandarinPinyinSyllables(for: "你好a") == nil)
        #expect(TextNormalization.mandarinPinyinSyllables(for: "嗯") == nil) // `ng`, a syllabic nasal
        for syllable in ["ni", "lv", "lve", "nv", "nve", "er", "a", "zhuang", "o"] {
            #expect(TextNormalization.isStandardMandarinSyllable(syllable), "\(syllable)")
        }
        for initial in ["b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "zh", "ch", "sh", "r", "z", "c", "s", "y", "w", "ng", "lue", "uijx"] {
            #expect(!TextNormalization.isStandardMandarinSyllable(initial), "\(initial)")
        }
    }

    @Test(arguments: [
        ("Nǐ hǎo", "ni hao"), ("xi'an", "xi an"), ("lü4", "lv"), ("LU:E", "lve"), ("nu\u{308}", "nv"),
        ("  zhong   guo  ", "zhong guo"), ("你好", ""), ("ni3hao3", "ni hao"), ("ḿ", "m"), ("ǹg", "ng"),
    ])
    func tonelessPinyinKey(_ input: String, _ expected: String) {
        #expect(TextNormalization.tonelessPinyinKey(input) == expected)
        #expect(TextNormalization.compactPinyinKey(input) == expected.replacingOccurrences(of: " ", with: ""))
    }

    @Test func readOnlyAndReadWriteConnectionsWorkConcurrently() async throws {
        let directory = try TemporaryDirectory()
        let writer = try LearningStore(url: directory.store)
        try writer.recordBatch([event("a", "啊")])
        let reader = try LearningStore(url: directory.store, mode: .readOnly)
        #expect(throws: LearningStoreError.notWritable) { try reader.recordBatch([event("ni", "你")]) }
        #expect(throws: LearningStoreError.notWritable) { try reader.setWatermark(for: .wanxiang, lastRevision: 1, projectedCount: 1) }

        let syllables = ["ba", "pa", "ma", "fa", "da", "ta", "na", "la", "ga", "ka"]
        let texts = ["八", "怕", "马", "发", "大", "他", "那", "拉", "嘎", "卡"]
        async let writes: Void = Task.detached {
            for round in 0..<20 {
                try writer.recordBatch(zip(syllables, texts).map { event($0.0, $0.1, at: Double(round)) })
            }
        }.value
        async let reads: [Int64] = Task.detached {
            var counts: [Int64] = []
            for _ in 0..<50 { counts.append(try reader.stats().entryCount) }
            return counts
        }.value
        try await writes
        let counts = try await reads
        // Every read saw a committed snapshot: counts never go down.
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(try reader.stats().entryCount == 11)
        #expect(try reader.stats().totalFrequency == 201)
    }

    @Test func readOnlyNeedsAnExistingStore() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: LearningStoreError.self) { try LearningStore(url: directory.store, mode: .readOnly) }
        #expect(!FileManager.default.fileExists(atPath: directory.store.path))
    }

    @Test(arguments: ["", "-wal", "-shm"])
    func refusesASymlinkedDatabaseOrSidecar(_ suffix: String) throws {
        let directory = try TemporaryDirectory()
        if !suffix.isEmpty {
            let store = try LearningStore(url: directory.store)
            try store.recordBatch([event("ni", "你")])
            store.close()
            try? FileManager.default.removeItem(atPath: directory.store.path + suffix)
        }
        let decoy = directory.url.appending(path: "decoy")
        try Data().write(to: decoy)
        try FileManager.default.createSymbolicLink(atPath: directory.store.path + suffix, withDestinationPath: decoy.path)
        let resolved = try #require(realpath(directory.url.path, nil))
        defer { free(resolved) }
        let refused = String(cString: resolved) + "/learning.sqlite" + suffix
        #expect(throws: LearningStoreError.notRegularFile(refused)) { try LearningStore(url: directory.store) }
        #expect(throws: LearningStoreError.notRegularFile(refused)) { try LearningStore(url: directory.store, mode: .readOnly) }
        #expect(try Data(contentsOf: decoy).isEmpty, "the link target was never written")
    }

    @Test func refusesAnUnknownSchemaVersion() throws {
        let directory = try TemporaryDirectory()
        try LearningStore(url: directory.store).close()
        var db: OpaquePointer?
        sqlite3_open(directory.store.path, &db)
        sqlite3_exec(db, "PRAGMA user_version = 2", nil, nil, nil)
        sqlite3_close(db)
        #expect(throws: LearningStoreError.unsupportedSchemaVersion(2)) { try LearningStore(url: directory.store) }
    }

    @Test func watermarksTrackIncrementalProjection() throws {
        let directory = try TemporaryDirectory()
        let store = try LearningStore(url: directory.store)
        try store.recordBatch([event("ni", "你"), event("hao", "好")])
        #expect(try store.watermark(for: .rimeIce) == nil)
        try store.setWatermark(for: .rimeIce, lastRevision: try store.latestRevision(), projectedCount: 2,
                               at: Date(timeIntervalSince1970: 5))
        try store.recordBatch([event("ma", "吗"), event("ni", "你")])
        let mark = try #require(try store.watermark(for: .rimeIce))
        #expect(mark.lastRevision == 2 && mark.projectedCount == 2 && mark.updatedAt == Date(timeIntervalSince1970: 5))
        // Only the changes after the watermark replay: the new 吗 and the re-learned 你.
        #expect(try store.entriesSince(revision: mark.lastRevision).map(\.text) == ["吗", "你"])
        #expect(try store.watermark(for: .mint) == nil, "watermarks are per set")
        try store.resetWatermark(for: .rimeIce)
        #expect(try store.watermark(for: .rimeIce) == nil)
        let stats = try store.stats()
        #expect(stats.entryCount == 3 && stats.totalFrequency == 4 && stats.latestRevision == 4 && stats.watermarks.isEmpty)
    }
}

@Suite struct LearningStoreWriterTests {
    @Test @MainActor func enqueueIsNonBlockingAndCoalescesIntoFewTransactions() throws {
        let directory = try TemporaryDirectory()
        let store = try LearningStore(url: directory.store)
        let writer = LearningStoreWriter(store: store, capacity: 10_000, coalescingDelay: .milliseconds(200))
        let observation = CommitObservation(rawInput: "nihao", preedit: "ni hao", committedText: "你好", schemaID: "s")
        let clock = ContinuousClock()
        let began = clock.now
        for _ in 0..<1000 { writer.enqueue(LearningCommitEvent(observation: observation)) }
        let elapsed = clock.now - began
        // 5 µs per enqueue on the main actor, debug build included.
        #expect(elapsed < .milliseconds(5), "1000 enqueues took \(elapsed)")
        writer.flush()
        let statistics = writer.statistics
        #expect(statistics.enqueued == 1000 && statistics.recorded == 1000 && statistics.dropped == 0)
        #expect(statistics.batches <= 2, "coalesced into \(statistics.batches) transactions")
        #expect(try store.allEntries().first?.frequency == 1000)
        #expect(writer.pendingCount == 0)
    }

    @Test func boundedQueueDropsInsteadOfGrowing() throws {
        let directory = try TemporaryDirectory()
        let store = try LearningStore(url: directory.store)
        let writer = LearningStoreWriter(store: store, capacity: 3, coalescingDelay: .seconds(10))
        #expect(writer.enqueue(event("a", "啊")) && writer.enqueue(event("ba", "吧")) && writer.enqueue(event("ma", "吗")))
        #expect(!writer.enqueue(event("ni", "你")))
        writer.flush()
        #expect(writer.statistics.dropped == 1 && writer.statistics.recorded == 3)
        #expect(try store.stats().entryCount == 3)
    }

    @Test func failedBatchIsReportedNotFatal() throws {
        let directory = try TemporaryDirectory()
        let store = try LearningStore(url: directory.store)
        let writer = LearningStoreWriter(store: store)
        store.close()
        writer.enqueue(event("ni", "你"))
        writer.flush()
        #expect(writer.statistics.failedBatches == 1 && writer.statistics.lastError == .notWritable)
    }
}

@Suite struct LearnedSnapshotExporterTests {
    @Test func exportsSortedMergedTSVAtomicallyWithPrivatePermissions() throws {
        let directory = try TemporaryDirectory()
        let store = try LearningStore(url: directory.store)
        try store.recordBatch([
            event("shijie", "世界", at: 1),
            event("xian", "西安", preedit: "xi an", at: 2),
            event("xian", "西安", at: 3),
            event("nihao", "你好", at: 4), event("nihao", "你好", at: 5), event("nihao", "你好", at: 6),
            event("shijie", "视界", at: 7),
        ])
        let tsv = directory.url.appending(path: NoemaPaths.learnedTSVFileName)
        try "stale".write(to: tsv, atomically: true, encoding: .utf8)
        #expect(try LearnedSnapshotExporter.export(from: store, to: tsv) == 4)
        // 你好 (3), then 西安 merged from `xi an` and `xian` (2), then equal counts newest first.
        #expect(try String(contentsOf: tsv, encoding: .utf8) == "nihao\t你好\t3\nxian\t西安\t2\nshijie\t视界\t1\nshijie\t世界\t1\n")
        #expect(permissions(tsv) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).filter { $0.contains(".tmp.") }
        #expect(leftovers.isEmpty)
    }

    @Test func capsTheNumberOfLines() throws {
        let entries = (0..<10).map { (index: Int) -> LearnedEntry in
            let compact = "a" + String(Character(Unicode.Scalar(UInt8(0x61 + index))))
            return LearnedEntry(id: Int64(index), pinyinNorm: "a", pinyinCompact: compact, text: "字", frequency: Int64(10 - index),
                                isUserPhrase: false, updatedAt: Date(), revision: Int64(index))
        }
        #expect(LearnedSnapshotExporter.lines(for: entries, maximumEntries: 3).map(\.pinyinCompact) == ["aa", "ab", "ac"])
    }

    /// An entry written into the store behind `normalized()`'s back cannot add a line: a tab,
    /// newline, CR, or NUL in any field, a `#` comment, an empty field, or a compact key that
    /// is not plain `a`-`z` is skipped.
    @Test func skipsEntriesThatWouldInjectTSVLines() {
        func entry(_ norm: String, _ compact: String, _ text: String) -> LearnedEntry {
            LearnedEntry(id: 1, pinyinNorm: norm, pinyinCompact: compact, text: text, frequency: 1,
                         isUserPhrase: false, updatedAt: Date(), revision: 1)
        }
        let hostile = [
            entry("ni hao", "nihao", "你好\nevil\t坏\t999"), entry("ni hao", "nihao", "你\t好"),
            entry("ni hao", "nihao", "你好\r"), entry("ni hao", "nihao", "你\u{0}好"),
            entry("ni hao", "nihao", "#你好"), entry("ni hao", "nihao", ""),
            entry("ni hao", "ni\nhao", "你好"), entry("ni hao", "ni\thao", "你好"),
            entry("ni hao", "ni hao", "你好"), entry("ni hao", "NIHAO", "你好"), entry("ni hao", "", "你好"),
            entry("ni\nhao", "nihao", "你好"), entry("", "nihao", "你好"),
        ]
        let lines = LearnedSnapshotExporter.lines(for: hostile + [entry("shi jie", "shijie", "世界")])
        #expect(lines.map(\.text) == ["世界"], "\(lines)")
        #expect(LearnedSnapshotExporter.render(lines) == Data("shijie\t世界\t1\n".utf8))
    }
}
