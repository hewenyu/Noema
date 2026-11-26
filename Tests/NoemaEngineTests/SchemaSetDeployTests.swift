import Darwin
import Foundation
import NoemaCore
@testable import NoemaEngine
import Testing

/// `DeployManifest` prisms and schema sets, the deployer's schema patch, staging locks, the
/// `RENAME_SWAP` build switch, and `.gram` linking, on real files; never initializes librime.
@Suite struct SchemaSetDeployTests {
    let root: URL
    var build: URL { root.appending(path: "build") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "noema-schemaset-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        for name in ["default.yaml", "s.schema.yaml", "d.table.bin", "d.prism.bin", "e.table.bin", "p.prism.bin"] {
            try Data("compiled \(name)\n".utf8).write(to: build.appending(path: name))
        }
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private func writeManifest(_ json: (inout [String: Any]) -> Void) throws {
        let outputs = try DeployManifest.outputs(buildDir: build).map {
            ["relativePath": $0.relativePath, "size": $0.size, "sha256": $0.sha256] as [String: Any]
        }
        var object: [String: Any] = [
            "version": 1, "schemaID": "s", "inputs": [], "outputs": outputs, "requiredDictionaries": ["d"],
        ]
        json(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: build.appending(path: DeployManifest.fileName))
    }

    @Test func versionOneManifestWithoutPrismsStillRequiresEachDictionaryPrism() throws {
        defer { cleanUp() }
        try writeManifest { _ in }
        let manifest = try #require(DeployManifest.validated(buildDir: build, schemaID: "s"))
        #expect(manifest.requiredPrisms == nil && manifest.schemaSetID == nil)
        #expect(manifest.effectivePrisms == ["d"])
        try FileManager.default.removeItem(at: build.appending(path: "d.prism.bin"))
        try writeManifest { _ in }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil, "v1 fallback: d.prism.bin is required")
    }

    @Test func explicitPrismsReplaceTheDictionaryPrismRequirement() throws {
        defer { cleanUp() }
        // A translator with `prism: p` over dictionary `d` compiles d.table.bin and p.prism.bin.
        try FileManager.default.removeItem(at: build.appending(path: "d.prism.bin"))
        try writeManifest { $0["requiredPrisms"] = ["p"]; $0["schemaSetID"] = "rime-ice" }
        let manifest = try #require(DeployManifest.validated(buildDir: build, schemaID: "s"))
        #expect(manifest.requiredPrisms == ["p"] && manifest.schemaSetID == "rime-ice")
        // Negative control: the declared prism must exist.
        try FileManager.default.removeItem(at: build.appending(path: "p.prism.bin"))
        try writeManifest { $0["requiredPrisms"] = ["p"] }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
        try writeManifest { $0["requiredPrisms"] = ["../p"] }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil, "unsafe prism name")
        try writeManifest { $0["requiredPrisms"] = []; $0["schemaSetID"] = "a/b" }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil, "unsafe schema set")
    }

    @Test func tableTranslatorDictionariesNeedTheirTables() throws {
        defer { cleanUp() }
        try writeManifest { $0["requiredDictionaries"] = ["d", "e"]; $0["requiredPrisms"] = ["d", "p"] }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") != nil)
        try FileManager.default.removeItem(at: build.appending(path: "e.table.bin"))
        try writeManifest { $0["requiredDictionaries"] = ["d", "e"]; $0["requiredPrisms"] = ["d", "p"] }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
    }

    @Test func encodingOmitsTheOptionalFieldsAndRoundTrips() throws {
        defer { cleanUp() }
        let plain = DeployManifest(schemaID: "s", inputs: [], outputs: [], requiredDictionaries: ["d"])
        let text = String(decoding: try plain.encoded(), as: UTF8.self)
        #expect(!text.contains("requiredPrisms") && !text.contains("schemaSetID"), "a v1 reader sees a v1 manifest")
        let full = DeployManifest(
            schemaID: "s", inputs: [], outputs: [], requiredDictionaries: ["d"], requiredPrisms: ["p"], schemaSetID: "mint")
        #expect(try JSONDecoder().decode(DeployManifest.self, from: try full.encoded()) == full)
    }

    @Test func requiredOutputPathsSplitTablesAndPrisms() {
        defer { cleanUp() }
        #expect(DeployManifest.requiredOutputPaths(schemaID: "s", dictionaries: ["d"]) ==
                ["default.yaml", "s.schema.yaml", "d.table.bin", "d.prism.bin"])
        #expect(DeployManifest.requiredOutputPaths(schemaID: "s", dictionaries: ["d", "e"], prisms: ["d", "d"]) ==
                ["default.yaml", "s.schema.yaml", "d.table.bin", "e.table.bin", "d.prism.bin"])
    }

    @Test func theLuaTranslatorIsADeployInput() throws {
        defer { cleanUp() }
        let shared = root.appending(path: "shared"), user = root.appending(path: "user")
        for directory in [shared, user] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("schema_list: []\n".utf8).write(to: shared.appending(path: "default.yaml"))
        let lua = root.appending(path: "noema_learned.lua")
        try Data("return {}\n".utf8).write(to: lua)
        let without = try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user, luaFile: nil)
        let with = try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user, luaFile: lua)
        #expect(without == (try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user)))
        #expect(with.map(\.relativePath) == ["noema/lua/noema_learned.lua", "shared/default.yaml"])
        try Data("return { }\n".utf8).write(to: lua)
        #expect(try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user, luaFile: lua) != with)
        let link = root.appending(path: "link.lua")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: lua)
        #expect(throws: DeployManifest.Failure.notRegular(link.path)) {
            try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user, luaFile: link)
        }
    }

    // MARK: Schema patch

    /// No user patch: a fresh one. A user patch is never edited: the wrapper includes it
    /// and appends with a key it does not use (never one ending in `/+`, which `__include`
    /// treats as a merge operator). Every patch, with or without a translator, nulls the
    /// `v` recognizers.
    @Test func translatorPatchWrapsTheUserPatchWithAnUnusedAppendKey() {
        defer { cleanUp() }
        let component = "lua_translator@*noema_learned"
        let disabled = "  \"recognizer/patterns/v\": \"\"\n  \"recognizer/patterns/v_mode\": \"\"\n"
        #expect(SchemaPatch.freshPatch(appending: component) == "patch:\n  \"engine/translators/+\":\n    - \"\(component)\"\n" + disabled)
        #expect(SchemaPatch.freshPatch() == "patch:\n" + disabled)
        #expect(SchemaPatch.userPatchConfigID(schemaID: "rime_ice") == "rime_ice.noema-user-custom")
        let wrapper = SchemaPatch.wrapper(appending: component, userConfigID: "s.noema-user-custom", userPatchKeys: ["menu/page_size"])
        #expect(wrapper == """
            # Generated by noema-rime-deployer: the user's own patch, then Noema's keys.
            patch:
              __include: "s.noema-user-custom:/patch?"
              "engine/translators/@next": "\(component)"
              "recognizer/patterns/v": ""
              "recognizer/patterns/v_mode": ""

            """ + "\n")
        // A user patch that names the translator, or no translator: only the recognizers.
        #expect(SchemaPatch.wrapper(appending: nil, userConfigID: "s", userPatchKeys: SchemaPatch.wrapperAppendKeys) == """
            # Generated by noema-rime-deployer: the user's own patch, then Noema's keys.
            patch:
              __include: "s:/patch?"
              "recognizer/patterns/v": ""
              "recognizer/patterns/v_mode": ""

            """ + "\n")
        #expect(SchemaPatch.appendKey(avoiding: []) == "engine/translators/@next")
        #expect(SchemaPatch.appendKey(avoiding: ["engine/translators/+", "engine/translators/@next"]) == "engine/translators/@after last")
        #expect(SchemaPatch.appendKey(avoiding: SchemaPatch.wrapperAppendKeys) == nil)
        #expect(SchemaPatch.wrapper(appending: component, userConfigID: "s", userPatchKeys: SchemaPatch.wrapperAppendKeys) == nil)
        #expect(!SchemaPatch.wrapperAppendKeys.contains { $0.hasSuffix("/+") })
        // Sorted after every user key on `recognizer` or `recognizer/patterns`.
        #expect(SchemaPatch.disabledRecognizerKeys.allSatisfy { $0 > "recognizer/patterns" && $0 > "recognizer/patterns/+" })
        #expect(SchemaPatch.names(component, in: "patch: {\"engine/translators/+\": [\(component)]}\n"))
        #expect(SchemaPatch.names(component, in: "patch:\r\n  engine/translators/+:\r\n    - \(component)\r\n"))
        #expect(!SchemaPatch.names(component, in: "# \(component)\n\t# \(component)\npatch: {}\n"), "a comment names nothing")
    }

    // MARK: Staging locks and the build switch

    @Test func recoveryKeepsALockedStagingDirectoryAndRemovesAnUnlockedOne() throws {
        defer { cleanUp() }
        let configuration = RimeEngineConfiguration(sharedDataDir: root, userDataDir: root, logDir: root)
        let live = root.appending(path: RimeEngine.stagingPrefix + "live")
        let dead = root.appending(path: RimeEngine.stagingPrefix + "dead")
        let legacy = root.appending(path: RimeEngine.stagingPrefix + "legacy")
        for directory in [live, dead, legacy] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        let lock = try #require(RimeEngine.StagingLock.acquire(in: live))
        let deadLock = try #require(RimeEngine.StagingLock.acquire(in: dead))
        deadLock.release()
        #expect(RimeEngine.StagingLock.isHeld(in: live) && !RimeEngine.StagingLock.isHeld(in: dead))

        #expect(RimeEngine.recoverInterruptedDeployments(configuration))
        #expect(FileManager.default.fileExists(atPath: live.path), "a held .deploy.lock protects its staging directory")
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "pre-lock leftovers are still cleaned up")
        lock.release()
        // Negative control: once released, the same directory is a leftover.
        #expect(RimeEngine.recoverInterruptedDeployments(configuration))
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

    @Test func switchBuildSwapsAtomicallyAndKeepsTheOldBuildForCleanup() throws {
        defer { cleanUp() }
        let configuration = RimeEngineConfiguration(sharedDataDir: root, userDataDir: root, logDir: root)
        let staging = root.appending(path: RimeEngine.stagingPrefix + "x")
        let staged = staging.appending(path: "build")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new\n".utf8).write(to: staged.appending(path: "default.yaml"))
        var before = stat()
        #expect(lstat(staged.path, &before) == 0)
        #expect(RimeEngine.switchBuild(configuration, to: staged, replacing: build, tag: "t"))
        var after = stat()
        #expect(lstat(build.path, &after) == 0 && after.st_ino == before.st_ino, "the staged directory is now build/")
        #expect(try String(contentsOf: build.appending(path: "default.yaml"), encoding: .utf8) == "new\n")
        #expect(FileManager.default.fileExists(atPath: staged.appending(path: "s.schema.yaml").path),
                "the old build was swapped into the staging directory, which its owner removes")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [RimeEngine.stagingPrefix + "x", "build"])
    }

    @Test func schemaSetsGetIsolatedUserDataDirsUnderOneRoot() {
        defer { cleanUp() }
        var configuration = RimeEngineConfiguration(sharedDataDir: root, userDataDir: root, logDir: root)
        #expect(configuration.rimeUserDataDir == root)
        configuration.schemaSetID = .rimeIce
        #expect(configuration.rimeUserDataDir == root.appending(path: "sets/rime-ice", directoryHint: .isDirectory))
        configuration.schemaSetID = .wanxiang
        #expect(configuration.rimeUserDataDir.lastPathComponent == "wanxiang")
    }

    @Test func gramIsHardLinkedIntoTheSetAndRelinkedWhenItChanges() throws {
        defer { cleanUp() }
        let models = root.appending(path: "models"), set = root.appending(path: "sets/wanxiang")
        for directory in [models, set] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let gram = models.appending(path: "wanxiang-lts-zh-hans.gram")
        try Data("v1".utf8).write(to: gram)
        let linked = try #require(RimeEngine.linkGram(gram, into: set))
        var source = stat(), target = stat()
        #expect(lstat(gram.path, &source) == 0 && lstat(linked.path, &target) == 0)
        #expect(source.st_ino == target.st_ino && target.st_mode & S_IFMT == S_IFREG)
        #expect(RimeEngine.linkGram(gram, into: set) == linked, "idempotent")
        try FileManager.default.removeItem(at: gram)
        try Data("v2".utf8).write(to: gram)
        _ = try #require(RimeEngine.linkGram(gram, into: set))
        #expect(try Data(contentsOf: linked) == Data("v2".utf8))
        let symlink = models.appending(path: "evil.gram")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: "/etc/hosts")
        #expect(RimeEngine.linkGram(symlink, into: set) == nil)
        #expect(RimeEngine.linkGram(models.appending(path: "missing.gram"), into: set) == nil)
    }

    /// librime's `Language::get_language_component`: a `translator/dictionary` without a
    /// `translator/user_dict` names the userdb up to its first `.` past index 0.
    @Test func defaultUserDictNameIsTheDictionaryLanguageComponent() {
        #expect(RimeEngine.defaultUserDictName(fromDictionary: "noema_pinyin.extra") == "noema_pinyin")
        #expect(RimeEngine.defaultUserDictName(fromDictionary: "rime_ice.extended") == "rime_ice")
        #expect(RimeEngine.defaultUserDictName(fromDictionary: "a.b.c") == "a")
        #expect(RimeEngine.defaultUserDictName(fromDictionary: "noema_pinyin") == "noema_pinyin")
        #expect(RimeEngine.defaultUserDictName(fromDictionary: ".hidden") == ".hidden")
    }

    /// Prefixes claim input at its start; a recognizer pattern only with a match that ends
    /// at the input's end (薄荷's unanchored `Uw[a-z]*'?$` also after confirmed text).
    @Test func secondaryInputRulesClaimPrefixesAndEndAnchoredPatterns() throws {
        let rules = SecondaryInputRules(prefixes: ["Uw", "`"], patterns: [
            try NSRegularExpression(pattern: "Uw[a-z]*'?$"),
            try NSRegularExpression(pattern: "^R[0-9]+[.]?[0-9]*"),
            try NSRegularExpression(pattern: "^[a-z]+[.].+$"),
        ])
        for claimed in ["Uwwo", "`wo", "nihaoUwwo", "R12", "R1.5", "www.a"] { #expect(rules.claims(claimed), "\(claimed)") }
        for pinyin in ["nihao", "ni'hao", "nh", "uijx", "shij", "R12x"] { #expect(!rules.claims(pinyin), "\(pinyin)") }
        #expect(!SecondaryInputRules().claims("Uwwo"))
    }
}
