import Darwin
import Foundation
import NoemaCore
import NoemaText
import Testing

@Suite struct SchemaSetTests {
    @Test func setsHaveStableDirectoriesAndDefaultSchemas() {
        #expect(SchemaSetID.allCases.map(\.directoryName) == ["builtin", "wanxiang", "rime-ice", "mint"])
        #expect(SchemaSetID.allCases.map(\.defaultSchemaID) == ["noema_pinyin", "wanxiang", "rime_ice", "rime_mint"])
        #expect(SchemaSetID(rawValue: "rime-ice") == .rimeIce)
    }

    @Test func pathsStayUnderTheOneRoot() {
        let root = URL(filePath: "/tmp/noema-root", directoryHint: .isDirectory)
        #expect(NoemaPaths.schemaSetUserDataDir(.mint, root: root).path == "/tmp/noema-root/sets/mint")
        #expect(NoemaPaths.downloadedSchemaDir(.wanxiang, root: root).path == "/tmp/noema-root/schemas/wanxiang")
        #expect(NoemaPaths.userDBSnapshotsDir(.rimeIce, root: root).path == "/tmp/noema-root/snapshots/rime-ice")
        #expect(NoemaPaths.modelsDir(root: root).path == "/tmp/noema-root/models")
        #expect(NoemaPaths.learningStoreURL(root: root).path == "/tmp/noema-root/learning.sqlite")
        #expect(NoemaPaths.activeSchemaSetURL(root: root).path == "/tmp/noema-root/active-schema-set.json")
    }

    @Test func learnedLuaResolvesFromTheSourceCheckout() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lua = try #require(NoemaPaths.resolveLearnedLua(
            bundle: Bundle(for: BundleToken.self), workingDirectory: repository,
            installedBundle: URL(filePath: "/nonexistent")))
        #expect(lua.lastPathComponent == "noema_learned.lua")
        let source = try String(contentsOf: lua, encoding: .utf8)
        #expect(source.contains("noema_learned.tsv") && !source.contains("require(\"sqlite"), "pure Lua, reads the TSV")
    }

    @Test func activeRecordRoundTripsAtomicallyAndRefusesSymlinksAndBadSchemas() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "noema-active-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ActiveSchemaSetRecord.fileName)
        let record = ActiveSchemaSetRecord(schemaSetID: .rimeIce, schemaID: "rime_ice", updatedAt: Date(timeIntervalSince1970: 100))
        try record.save(to: url)
        #expect(ActiveSchemaSetRecord.load(from: url) == record)
        var info = stat()
        #expect(lstat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)

        let bad = #"{"schemaSetID":"mint","schemaID":"../x","updatedAt":"2026-01-01T00:00:00Z"}"#
        try Data(bad.utf8).write(to: url)
        #expect(ActiveSchemaSetRecord.load(from: url) == nil, "schema ID must be a plain name")
        try FileManager.default.removeItem(at: url)
        let target = directory.appending(path: "target.json")
        try record.save(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(ActiveSchemaSetRecord.load(from: url) == nil, "a symlinked record is refused")
        #expect(ActiveSchemaSetRecord.load(from: directory.appending(path: "missing.json")) == nil)
    }

    @Test(arguments: [("a", true), ("rime_ice.extended", true), ("", false), ("a/b", false), ("..", false), ("a\u{0}", false)])
    func plainNames(_ name: String, _ plain: Bool) {
        #expect(FileSafety.isPlainName(name) == plain)
    }

    @Test func textHelpersForLearning() {
        #expect(TextNormalization.containsHanCharacters("ok你"))
        #expect(!TextNormalization.containsHanCharacters("ok，。"))
        #expect(TextNormalization.syllableCount(ofPinyinKey: "ni hao") == 2)
        #expect(TextNormalization.syllableCount(ofPinyinKey: "") == 0)
        #expect(TextNormalization.compactPinyinKey("Zhōng Guó") == "zhongguo")
    }
}

private final class BundleToken {}
