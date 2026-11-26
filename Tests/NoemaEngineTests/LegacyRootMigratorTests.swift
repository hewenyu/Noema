import Darwin
import Foundation
import NoemaCore
import NoemaEngine
import NoemaLearning
import Testing

/// The pure parts of `LegacyRootMigrator`: the userdb export parser and the file phase.
/// The whole upgrade on the real librime is `legacyRootUserDataMigratesIntoTheBuiltinSet`.
struct LegacyRootMigratorTests {
    private func parsed(_ text: String) -> [String] {
        LegacyRootMigrator.parseExportedUserDB(text).map { "\($0.event.text)|\($0.event.preedit)|\($0.frequency)" }
    }

    @Test func parsesPlainCountsAndRawUserDBValues() {
        #expect(parsed("霓昊\tni hao\t100\n") == ["霓昊|ni hao|100"])
        #expect(parsed("霓昊\tni hao \tc=100 d=0.5 t=1\n") == ["霓昊|ni hao|100"])
        #expect(parsed("霓昊\tni hao\n") == ["霓昊|ni hao|1"])
        #expect(parsed("霓昊\tni hao\t99999999\r\n") == ["霓昊|ni hao|\(LegacyRootMigrator.maximumImportedFrequency)"])
    }

    @Test func skipsCommentsDeletedAndUnlearnableEntries() {
        let text = """
            # Rime user dictionary export
            #@/db_name\tnoema_pinyin.userdb

            霓昊\tni hao\tc=-1 d=0.1 t=5
            泥嚎\tni hao\t0
            你好\tni hao\tc=0
            hello\the llo\t3
            你\tni hao\t3
            霓\u{7}昊\tni hao\t3
            霓昊\tni\u{7} hao\t3
            霓昊\tx y\t3
            霓昊\tni hao\tbogus
            好
            时间\tshi jian\t2
            """
        #expect(parsed(text) == ["时间|shi jian|2"])
    }

    @Test func freshRootIsMarkedAndSymlinksAreNeverCopied() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "noema-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let builtin = NoemaPaths.schemaSetUserDataDir(.builtin, root: root)
        try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)

        // Only symlinks: nothing legacy, marked at once.
        let outside = root.appending(path: "outside.yaml")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "a.custom.yaml"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "user.yaml"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "b.userdb"), withDestinationURL: builtin)
        #expect(LegacyRootMigrator.migrateFilesIfNeeded(root: root, builtinDir: builtin) == nil)
        #expect(LegacyRootMigrator.isMigrated(builtinDir: builtin))
        #expect(try FileManager.default.contentsOfDirectory(atPath: builtin.path) == [LegacyRootMigrator.markerFileName])

        // Real legacy files are copied, never overwriting, and the userdb's symlinks skipped.
        try FileManager.default.removeItem(at: LegacyRootMigrator.markerURL(builtinDir: builtin))
        try "patch: {}\n".write(to: root.appending(path: "noema_pinyin.custom.yaml"), atomically: true, encoding: .utf8)
        try "mine\n".write(to: builtin.appending(path: "user.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "user.yaml"))
        try "legacy\n".write(to: root.appending(path: "user.yaml"), atomically: true, encoding: .utf8)
        let userdb = root.appending(path: "noema_pinyin.userdb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: userdb, withIntermediateDirectories: true)
        try "db".write(to: userdb.appending(path: "000003.log"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: userdb.appending(path: "LINK"), withDestinationURL: outside)
        let pending = try #require(LegacyRootMigrator.migrateFilesIfNeeded(root: root, builtinDir: builtin))
        #expect(pending.userDBs == ["noema_pinyin"] && pending.filesComplete)
        #expect(!LegacyRootMigrator.isMigrated(builtinDir: builtin))
        #expect(try String(contentsOf: builtin.appending(path: "user.yaml"), encoding: .utf8) == "mine\n")
        #expect(FileSafety.isRegularFile(builtin.appending(path: "noema_pinyin.custom.yaml")))
        let copied = builtin.appending(path: "noema_pinyin.userdb")
        #expect(try FileManager.default.contentsOfDirectory(atPath: copied.path) == ["000003.log"])
        let names = try FileManager.default.contentsOfDirectory(atPath: builtin.path).sorted()
        #expect(names == ["noema_pinyin.custom.yaml", "noema_pinyin.userdb", "user.yaml"], "\(names)")
    }

    @Test func refusesASymlinkedBuiltinDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "noema-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "sets"), withIntermediateDirectories: true)
        let builtin = NoemaPaths.schemaSetUserDataDir(.builtin, root: root)
        try FileManager.default.createSymbolicLink(at: builtin, withDestinationURL: elsewhere)
        try "patch: {}\n".write(to: root.appending(path: "noema_pinyin.custom.yaml"), atomically: true, encoding: .utf8)
        #expect(LegacyRootMigrator.migrateFilesIfNeeded(root: root, builtinDir: builtin) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}
