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
        #expect(entries[1].pinyinNorm == "shijie" && entries[1].frequency == 1)
        #expect(try store.latestRevision() == 3)
        #expect(entries[0].revision == 2 && entries[1].revision == 3)
        #expect(try store.entriesSince(revision: 2).map(\.text) == ["世界"])
    }

    @Test func normalizationPrefersThePreeditOnlyWhenItSpellsTheRawInput() {
        #expect(event("nihao", "你好", preedit: "ni hao").normalized()?.pinyinNorm == "ni hao")
        #expect(event("nihao", "你好", preedit: "你 hao").normalized()?.pinyinNorm == "nihao")
        #expect(event("xian", "西安", preedit: "xi'an").normalized()?.pinyinNorm == "xi an")
        #expect(event("lv", "绿", preedit: "lü").normalized()?.pinyinNorm == "lv")
        #expect(event("nihao", String(repeating: "好", count: 33)).normalized() == nil)
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
        let entries = (0..<10).map { index in
            LearnedEntry(id: Int64(index), pinyinNorm: "a", pinyinCompact: "a\(index)", text: "字", frequency: Int64(10 - index),
                         isUserPhrase: false, updatedAt: Date(), revision: Int64(index))
        }
        #expect(LearnedSnapshotExporter.lines(for: entries, maximumEntries: 3).map(\.pinyinCompact) == ["a0", "a1", "a2"])
    }
}
