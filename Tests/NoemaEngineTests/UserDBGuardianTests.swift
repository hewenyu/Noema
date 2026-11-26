import Darwin
import Foundation
import NoemaCore
import NoemaEngine
import NoemaLearning
import Testing

/// Stands in for librime's levers API (the external boundary): each `<dict>.userdb/` holds a
/// `rows.tsv` of `<text>\t<code>\t<weight>`; import merges by keeping the larger weight, as
/// librime's `UserDbImporter` does. Real-librime coverage lives in CRimeTests.
final class FakeLevers: UserDictLevers {
    let userDataDir: URL
    var failingExports: Set<String> = []
    var failingImports: Set<String> = []
    private(set) var imports: [(String, String)] = []

    init(userDataDir: URL) { self.userDataDir = userDataDir }

    func rowsURL(_ name: String) -> URL { userDataDir.appending(path: "\(name).userdb/rows.tsv") }

    func rows(_ name: String) -> [String: Int] {
        guard let text = try? String(contentsOf: rowsURL(name), encoding: .utf8) else { return [:] }
        var rows: [String: Int] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let weight = Int(fields[2]) else { continue }
            rows["\(fields[0])\t\(fields[1])"] = weight
        }
        return rows
    }

    func userDictNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: userDataDir.path)) ?? [])
            .filter { $0.hasSuffix(".userdb") }.map { String($0.dropLast(".userdb".count)) }
    }

    func exportUserDict(_ name: String, to file: URL) -> Int {
        guard !failingExports.contains(name), FileSafety.isRealDirectory(userDataDir.appending(path: "\(name).userdb")) else {
            return -1
        }
        let rows = rows(name)
        let text = "# Rime user dictionary\n" + rows.keys.sorted().map { "\($0)\t\(rows[$0]!)\n" }.joined()
        guard (try? Data(text.utf8).write(to: file)) != nil else { return -1 }
        return rows.count
    }

    func importUserDict(_ name: String, from file: URL) -> Int {
        guard !failingImports.contains(name), let text = try? String(contentsOf: file, encoding: .utf8) else { return -1 }
        imports.append((name, text))
        try? FileManager.default.createDirectory(
            at: userDataDir.appending(path: "\(name).userdb"), withIntermediateDirectories: true)
        var rows = rows(name)
        var count = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let weight = Int(fields[2]) else { continue }
            let key = "\(fields[0])\t\(fields[1])"
            rows[key] = max(rows[key] ?? 0, weight)
            count += 1
        }
        let output = rows.keys.sorted().map { "\($0)\t\(rows[$0]!)\n" }.joined()
        guard (try? Data(output.utf8).write(to: rowsURL(name))) != nil else { return -1 }
        return count
    }
}

@Suite struct UserDBGuardianTests {
    let root: URL
    let levers: FakeLevers
    let store: LearningStore
    var setDir: URL { NoemaPaths.schemaSetUserDataDir(.rimeIce, root: root) }
    var snapshots: URL { NoemaPaths.userDBSnapshotsDir(.rimeIce, root: root) }
    var guardian: UserDBGuardian {
        UserDBGuardian(schemaSet: .rimeIce, userDataDir: setDir, snapshotsDir: snapshots, levers: levers)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "noema-guardian-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: NoemaPaths.schemaSetUserDataDir(.rimeIce, root: root), withIntermediateDirectories: true)
        levers = FakeLevers(userDataDir: NoemaPaths.schemaSetUserDataDir(.rimeIce, root: root))
        store = try LearningStore(url: NoemaPaths.learningStoreURL(root: root))
    }

    private func cleanUp() {
        store.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func learn(_ pairs: [(String, String)]) throws {
        try store.recordBatch(pairs.map { LearningCommitEvent(rawInput: $0.0.replacingOccurrences(of: " ", with: ""), preedit: $0.0, text: $0.1) })
    }

    // MARK: Snapshots

    @Test func snapshotIsWrittenOnlyFromASuccessfulExportAndVerifiedBySHA256() throws {
        defer { cleanUp() }
        try learn([("ni hao", "你好"), ("shi jie", "世界")])
        _ = try guardian.project("rime_ice", store: store)
        let metadata = try guardian.writeSnapshot("rime_ice", learningRevision: 2)
        #expect(metadata.entryCount == 2 && metadata.learningRevision == 2 && metadata.schemaSetID == "rime-ice")
        let (url, verified) = try #require(UserDBGuardian.verifiedSnapshot("rime_ice", schemaSet: .rimeIce, in: snapshots))
        #expect(verified == metadata)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("你好\tni hao\t1"))
        for file in [url, UserDBGuardian.snapshotMetadataURL("rime_ice", in: snapshots)] {
            var info = stat()
            #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        }
        #expect(UserDBGuardian.verifiedSnapshot("rime_ice", schemaSet: .mint, in: snapshots) == nil, "another set's snapshot")

        // A failing export never replaces the good snapshot.
        levers.failingExports = ["rime_ice"]
        #expect(throws: UserDBGuardian.Failure.exportFailed("rime_ice")) { try guardian.writeSnapshot("rime_ice", learningRevision: 9) }
        #expect(UserDBGuardian.verifiedSnapshot("rime_ice", schemaSet: .rimeIce, in: snapshots)?.1 == metadata)
        let probes = try FileManager.default.contentsOfDirectory(atPath: snapshots.path).filter { $0.hasPrefix(".probe.") }
        #expect(probes.isEmpty)
    }

    @Test func tamperedOrSymlinkedSnapshotsFailVerification() throws {
        defer { cleanUp() }
        try learn([("ni hao", "你好")])
        _ = try guardian.project("rime_ice", store: store)
        try guardian.writeSnapshot("rime_ice", learningRevision: 1)
        let tsv = UserDBGuardian.snapshotURL("rime_ice", in: snapshots)
        let meta = UserDBGuardian.snapshotMetadataURL("rime_ice", in: snapshots)
        let original = try Data(contentsOf: tsv)

        var flipped = original
        flipped[flipped.count - 2] ^= 0x01
        try flipped.write(to: tsv)
        #expect(UserDBGuardian.verifiedSnapshot("rime_ice", schemaSet: .rimeIce, in: snapshots) == nil, "same size, other bytes")
        try original.write(to: tsv)
        #expect(UserDBGuardian.verifiedSnapshot("rime_ice", schemaSet: .rimeIce, in: snapshots) != nil, "negative control")

        let metaData = try Data(contentsOf: meta)
        var object = try #require(try JSONSerialization.jsonObject(with: metaData) as? [String: Any])
        object["sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object).write(to: meta)
        #expect(UserDBGuardian.verifiedSnapshot("rime_ice", schemaSet: .rimeIce, in: snapshots) == nil, "sidecar digest")
        try metaData.write(to: meta)

        let elsewhere = root.appending(path: "elsewhere.tsv")
        try FileManager.default.moveItem(at: tsv, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: tsv, withDestinationURL: elsewhere)
        #expect(UserDBGuardian.verifiedSnapshot("rime_ice", schemaSet: .rimeIce, in: snapshots) == nil, "symlinked snapshot")
    }

    // MARK: Health

    @Test func healthCheckDetectsMissingSymlinkedLostAndUnexportableUserDBs() throws {
        defer { cleanUp() }
        #expect(try guardian.checkHealth("rime_ice") == .missing)
        let userdb = setDir.appending(path: "rime_ice.userdb")
        let decoy = root.appending(path: "decoy.userdb")
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: userdb, withDestinationURL: decoy)
        #expect(try guardian.checkHealth("rime_ice") == .corrupted(.notADirectory))
        try FileManager.default.removeItem(at: userdb)

        try FileManager.default.createDirectory(at: userdb, withIntermediateDirectories: true)
        #expect(try guardian.checkHealth("rime_ice") == .healthy(exported: 0))
        try FileManager.default.createDirectory(at: userdb.appending(path: "lost"), withIntermediateDirectories: true)
        #expect(try guardian.checkHealth("rime_ice") == .corrupted(.lostDirectory))
        try FileManager.default.removeItem(at: userdb.appending(path: "lost"))
        levers.failingExports = ["rime_ice"]
        #expect(try guardian.checkHealth("rime_ice") == .corrupted(.exportFailed))
        #expect(throws: UserDBGuardian.Failure.self) { try guardian.checkHealth("../x") }
    }

    @Test func healthCheckFlagsAUserDBThatLostMostProjectedEntries() throws {
        defer { cleanUp() }
        try learn([("a", "啊"), ("ba", "吧"), ("ma", "吗"), ("ni", "你")])
        _ = try guardian.project("rime_ice", store: store)
        #expect(try guardian.checkHealth("rime_ice", store: store) == .healthy(exported: 4))
        try Data("啊\ta\t1\n".utf8).write(to: levers.rowsURL("rime_ice"))
        #expect(try guardian.checkHealth("rime_ice", store: store) == .diverged(exported: 1, projected: 4))
        #expect(try guardian.maintain("rime_ice", store: store) == .reprojected(imported: 4))
        #expect(levers.rows("rime_ice").count == 4)
    }

    // MARK: Projection and recovery

    @Test func projectionIsIncrementalAndAdvancesTheWatermark() throws {
        defer { cleanUp() }
        try learn([("ni hao", "你好"), ("shi jie", "世界")])
        #expect(try guardian.project("rime_ice", store: store) == 2)
        #expect(try store.watermark(for: .rimeIce)?.lastRevision == 2)
        #expect(try guardian.project("rime_ice", store: store) == 0, "nothing new")
        try learn([("ni hao", "你好"), ("zai jian", "再见")])
        #expect(try guardian.project("rime_ice", store: store) == 2)
        #expect(levers.imports.last?.1 == "你好\tni hao\t2\n再见\tzai jian\t1\n", "only the changes, as <text>\\t<code>\\t<weight>")
        #expect(levers.rows("rime_ice")["你好\tni hao"] == 2)
        let mark = try #require(try store.watermark(for: .rimeIce))
        #expect(mark.lastRevision == 4 && mark.projectedCount == 3)
        #expect(try store.watermark(for: .mint) == nil)
    }

    @Test func corruptUserDBIsQuarantinedAndRestoredFromSnapshotPlusReplay() throws {
        defer { cleanUp() }
        try learn([("ni hao", "你好"), ("shi jie", "世界")])
        #expect(try guardian.maintain("rime_ice", store: store) == .recovered(.init(
            method: .fullRebuild, quarantined: nil, imported: 2, exported: 2)))
        let snapshotRevision = try #require(UserDBGuardian.verifiedSnapshot("rime_ice", schemaSet: .rimeIce, in: snapshots)).1.learningRevision
        #expect(snapshotRevision == 2)
        // A phrase Rime learned natively lives only in the userdb (and so in the snapshot).
        _ = levers.importUserDict("rime_ice", from: try tsv("原生\tyuan sheng\t5\n"))
        try guardian.writeSnapshot("rime_ice", learningRevision: 2)
        // Newer store entries the snapshot predates.
        try learn([("zai jian", "再见")])

        let userdb = setDir.appending(path: "rime_ice.userdb")
        try FileManager.default.createDirectory(at: userdb.appending(path: "lost"), withIntermediateDirectories: true)
        guard case .recovered(let report) = try guardian.maintain("rime_ice", store: store) else {
            Issue.record("expected recovery")
            return
        }
        #expect(report.method == .snapshotAndReplay)
        let quarantined = try #require(report.quarantined)
        #expect(quarantined.deletingLastPathComponent().lastPathComponent == UserDBGuardian.quarantineDirectoryName)
        #expect(FileManager.default.fileExists(atPath: quarantined.appending(path: "lost").path), "the corrupt db is kept aside")
        #expect(!FileManager.default.fileExists(atPath: userdb.appending(path: "lost").path))
        let rows = levers.rows("rime_ice")
        #expect(rows["原生\tyuan sheng"] == 5, "restored from the snapshot")
        #expect(rows["再见\tzai jian"] == 1, "replayed from learning.sqlite")
        #expect(levers.imports.last?.1 == "再见\tzai jian\t1\n", "only entries newer than the snapshot are replayed")
        #expect(try store.watermark(for: .rimeIce)?.lastRevision == 3)
    }

    @Test func withoutAUsableSnapshotTheUserDBIsRebuiltFromTheStore() throws {
        defer { cleanUp() }
        try learn([("ni hao", "你好"), ("ni hao", "你好"), ("shi jie", "世界")])
        let userdb = setDir.appending(path: "rime_ice.userdb")
        try FileManager.default.createDirectory(at: userdb, withIntermediateDirectories: true)
        levers.failingExports = ["rime_ice"]
        #expect(try guardian.checkHealth("rime_ice") == .corrupted(.exportFailed))
        levers.failingExports = []
        // The snapshot on disk is corrupt, so the ladder skips it.
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: UserDBGuardian.snapshotURL("rime_ice", in: snapshots))
        try Data("{}".utf8).write(to: UserDBGuardian.snapshotMetadataURL("rime_ice", in: snapshots))
        let report = try guardian.recover("rime_ice", store: store)
        #expect(report.method == .fullRebuild && report.quarantined != nil && report.exported == 2)
        #expect(levers.rows("rime_ice") == ["你好\tni hao": 2, "世界\tshi jie": 1])
        #expect(UserDBGuardian.verifiedSnapshot("rime_ice", schemaSet: .rimeIce, in: snapshots)?.1.learningRevision == 3)
    }

    @Test func recoveryFailsLoudlyWhenTheRebuiltUserDBStillCannotExport() throws {
        defer { cleanUp() }
        try learn([("ni hao", "你好")])
        levers.failingExports = ["rime_ice"]
        #expect(throws: UserDBGuardian.Failure.exportFailed("rime_ice still fails to export after recovery")) {
            try guardian.recover("rime_ice", store: store)
        }
    }

    private func tsv(_ text: String) throws -> URL {
        let url = root.appending(path: "import-\(UUID().uuidString).tsv")
        try Data(text.utf8).write(to: url)
        return url
    }
}
