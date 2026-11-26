import Darwin
import Foundation
import NoemaAgentCore
import NoemaCore
import NoemaEngine
import NoemaIMEShell
import NoemaIPC
import NoemaLearning
import Testing

/// Schema sets, the canonical learning store, and the userdb guardian on the real path:
/// the real `RimeEngine` and librime (with librime-lua), the real `noema-rime-deployer`
/// subprocess, the real `learning.sqlite`, `SchemaSetSwitcher` wired as `EngineHost` wires
/// it, and the real IPC manager and agent coordinator. Three fixture schema sets stand in
/// for 万象, 雾凇, and 薄荷: copies of the shipped pinyin schema under their own schema IDs,
/// `rime_ice_fixture` with `translator/prism` distinct from `translator/dictionary`.
extension LibrimeSerializedTests {
    @MainActor
    @Suite struct LexiconAndLearningTests {
        /// All three sets deploy through the real deployer and hot-switch; every set keeps its
        /// own `build/` and LevelDB userdb under `sets/<set>/`; switching back reuses the
        /// build without recompiling it.
        @Test func threeSchemaSetsSwitchWithIsolatedUserDBsAndNoRecompile() async throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            try #require(!engine.isSafeMode && engine.configuration.schemaSetID == .builtin)
            let host = SwitcherHost(workspace: workspace, engine: engine)

            var builds: [SchemaSetID: (inode: UInt64, manifest: Data)] = [:]
            for fixture in LexiconWorkspace.fixtures {
                let event = try await host.switchAndWait(fixture.set, fixture.schemaID)
                #expect(event.phase == .ready, "\(fixture.set): \(event.detail ?? "")")
                #expect(engine.currentState.schemaID == fixture.schemaID && engine.configuration.schemaSetID == fixture.set)
                #expect(!candidates(engine, "nihao").isEmpty, "\(fixture.set) yields no candidates")
                let build = workspace.setDir(fixture.set).appending(path: "build")
                let manifest = try Data(contentsOf: build.appending(path: DeployManifest.fileName))
                builds[fixture.set] = (try inode(build), manifest)
                let decoded = try JSONDecoder().decode(DeployManifest.self, from: manifest)
                #expect(decoded.schemaSetID == fixture.set.rawValue && decoded.schemaID == fixture.schemaID)
                if let prism = fixture.prism {
                    #expect(decoded.requiredPrisms == [prism])
                    #expect(FileManager.default.fileExists(atPath: build.appending(path: "\(prism).prism.bin").path))
                    #expect(FileManager.default.fileExists(atPath: build.appending(path: "\(fixture.schemaID).table.bin").path))
                }
            }
            // Physical isolation: each userdb lives only in its own set; none in the root.
            let rootNames = try FileManager.default.contentsOfDirectory(atPath: workspace.user.path)
            #expect(!rootNames.contains { $0.hasSuffix(".userdb") || $0 == "build" }, "root holds \(rootNames)")
            for set in [SchemaSetID.builtin] + LexiconWorkspace.fixtures.map(\.set) {
                let names = try FileManager.default.contentsOfDirectory(atPath: workspace.setDir(set).path)
                let userdbs = names.filter { $0.hasSuffix(".userdb") }
                let expected = set == .builtin ? "noema_pinyin" : LexiconWorkspace.fixture(set).schemaID
                #expect(userdbs == ["\(expected).userdb"], "\(set): \(userdbs)")
                #expect(FileSafety.isRealDirectory(workspace.setDir(set).appending(path: "\(expected).userdb")))
            }
            // Back to each set: the build is reused as is (no deployer run, same directory).
            for fixture in LexiconWorkspace.fixtures {
                let clock = ContinuousClock()
                let started = clock.now
                let event = try await host.switchAndWait(fixture.set, fixture.schemaID)
                let elapsed = clock.now - started
                #expect(event.phase == .ready)
                let build = workspace.setDir(fixture.set).appending(path: "build")
                #expect(try inode(build) == builds[fixture.set]?.inode, "\(fixture.set) was recompiled")
                #expect(try Data(contentsOf: build.appending(path: DeployManifest.fileName)) == builds[fixture.set]?.manifest)
                print("[schema-set switch] \(fixture.set.rawValue) second switch: \(elapsed)")
                #expect(elapsed < .seconds(3))
            }
            #expect(host.events.allSatisfy { $0.phase != .failed })
        }

        /// A phrase committed in one set reaches the others through `learning.sqlite`: as a
        /// userdb entry the guardian imports (`import_user_dict`) on the switch, and through
        /// `lua_translator@*noema_learned` reading the exported `noema_learned.tsv`. Each path
        /// is shown alone: 雾凇 sees a phrase only the TSV holds, 薄荷 runs without the Lua
        /// translator and still sees the phrase from its projected userdb.
        @Test func learnedPhrasesCrossSchemaSetsThroughUserDBAndLua() async throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)
            let host = SwitcherHost(workspace: workspace, engine: engine, store: store, writer: writer)

            #expect(try await host.switchAndWait(.wanxiang, "wanxiang_fixture").phase == .ready)
            engine.type("nihao")
            let index = try #require(engine.currentState.candidates.firstIndex { $0.text == "泥嚎" }, "\(engine.currentState.candidates)")
            #expect(engine.selectCandidate(at: index).committedText == "泥嚎")
            writer.flush()
            let learned = try store.allEntries()
            #expect(learned.map(\.text) == ["泥嚎"] && learned.first?.pinyinNorm == "ni hao", "\(learned)")

            // 雾凇: projected into its userdb and exported to its TSV.
            #expect(!LexiconWorkspace.dictionary(of: .rimeIce).contains("泥嚎"))
            #expect(try await host.switchAndWait(.rimeIce, "rime_ice_fixture").phase == .ready)
            let report = try #require(host.switcher.lastReport)
            #expect(report.userDictName == "rime_ice_fixture")
            switch report.userDBOutcome {
            case .recovered(let recovery): #expect(recovery.imported >= 1 && recovery.method == .fullRebuild)
            case .healthy(let projected): #expect(projected >= 1)
            default: Issue.record("unexpected guardian outcome \(String(describing: report.userDBOutcome))")
            }
            #expect(report.learnedLines == 1)
            let tsv = try String(contentsOf: workspace.setDir(.rimeIce).appending(path: NoemaPaths.learnedTSVFileName), encoding: .utf8)
            #expect(tsv == "nihao\t泥嚎\t1\n")
            #expect(candidates(engine, "nihao").contains("泥嚎"))

            // The Lua translator alone: a phrase only the TSV holds (never projected).
            #expect(writer.enqueue(LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "霓昊")))
            writer.flush()
            #expect(!candidates(engine, "nihao").contains("霓昊"))
            #expect(engine.refreshLearnedPhrases(from: store) == 2)
            engine.resetSession()
            #expect(candidates(engine, "nihao").contains("霓昊"), "noema_learned.lua did not serve the TSV phrase")

            // 薄荷 without the Lua translator: only its projected userdb serves the phrases.
            let mint = try await engine.switchSchemaSet(
                to: .mint, sharedDataDir: workspace.schemaDir(.mint), schemaID: "mint_fixture",
                learningStore: store, learningWriter: writer, luaFile: nil)
            #expect(!FileManager.default.fileExists(atPath: workspace.setDir(.mint).appending(path: "lua").path))
            if case .recovered(let recovery) = mint.userDBOutcome { #expect(recovery.imported == 2) } else {
                Issue.record("mint: \(String(describing: mint.userDBOutcome))")
            }
            let fromUserDB = candidates(engine, "nihao")
            #expect(fromUserDB.contains("泥嚎") && fromUserDB.contains("霓昊"), "\(fromUserDB)")
            let watermarks = try store.stats().watermarks.map { "\($0.schemaSet)/\($0.dictName)" }
            #expect(watermarks == ["mint/mint_fixture", "rime-ice/rime_ice_fixture"], "\(watermarks)")
        }

        /// `nihao,` commits `你好，` (the punctuator commits the candidate plus the full-width
        /// comma): `learning.sqlite` learns `你好`, and the other set's TSV and userdb never
        /// carry the comma.
        @Test func trailingPunctuationIsTrimmedBeforeLearning() async throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)
            let host = SwitcherHost(workspace: workspace, engine: engine, store: store, writer: writer)

            var committed: [String] = []
            for character in "nihao," {
                if let text = engine.processKey(.text(character)).committedText { committed.append(text) }
            }
            #expect(committed == ["你好，"], "\(committed)")
            writer.flush()
            let learned = try store.allEntries()
            #expect(learned.map(\.text) == ["你好"] && learned.first?.pinyinNorm == "ni hao", "\(learned)")

            #expect(try await host.switchAndWait(.rimeIce, "rime_ice_fixture").phase == .ready)
            let tsv = try String(contentsOf: workspace.setDir(.rimeIce).appending(path: NoemaPaths.learnedTSVFileName), encoding: .utf8)
            #expect(tsv == "nihao\t你好\t1\n")
            #expect(!candidates(engine, "nihao").contains("你好，"))
        }

        /// `nihaoshijie`, select `你好` (preedit `你好shi jie`), then `世界`: the commit
        /// `你好世界` is learned under the syllables of the all-pinyin preedit, `ni hao shi
        /// jie`, not the unspaced raw input.
        @Test func partialSelectionCommitKeepsTheSyllableBreaks() throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)

            for character in "nihaoshijie" { _ = engine.processKey(.text(character)) }
            try #require(engine.currentState.preedit == "ni hao shi jie", "\(engine.currentState.preedit)")
            func select(_ text: String) throws -> KeyHandlingResult {
                for _ in 0..<8 {
                    if let index = engine.currentState.candidates.firstIndex(where: { $0.text == text }) {
                        return engine.selectCandidate(at: index)
                    }
                    engine.changePage(backward: false)
                }
                Issue.record("no candidate \(text) in \(engine.currentState.candidates.map(\.text))")
                throw CancellationError()
            }
            #expect(try select("你好").committedText == nil)
            #expect(engine.currentState.preedit.hasPrefix("你好"), "\(engine.currentState.preedit)")
            #expect(try select("世界").committedText == "你好世界")
            writer.flush()
            let learned = try store.allEntries()
            #expect(learned.map(\.text) == ["你好世界"] && learned.first?.pinyinNorm == "ni hao shi jie", "\(learned)")
        }

        /// Codex's sequence: `nihaoshijie`, select `你好` (preedit `你好shi jie`), then End,
        /// Left, three forward Deletes, and `jian` (preedit `你好shi jian`, raw input
        /// `nihaoshijian`), select `时间`. The all-pinyin preedit `ni hao shi jie` spelled the
        /// old raw input, so it is not reused: `你好时间` is learned as `ni hao shi jian`, and
        /// another set's rebuilt userdb serves it for `nihaoshijian`, never for `nihaoshijie`.
        @Test func partialSelectionThenEditLearnsTheEditedSpelling() async throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)

            try typeSelectAndEditTail(engine, replacingThreeKeysWith: "jian")
            #expect(engine.currentState.preedit == "你好shi jian", "\(engine.currentState.preedit)")
            #expect(try selectCandidate(engine, "时间").committedText == "你好时间")
            writer.flush()
            let learned = try store.allEntries()
            #expect(learned.map(\.text) == ["你好时间"] && learned.first?.pinyinNorm == "ni hao shi jian", "\(learned)")
            #expect(!learned.contains { $0.pinyinNorm == "ni hao shi jie" })

            // 薄荷 (no Lua translator): only its rebuilt userdb serves the phrase.
            let mint = try await engine.switchSchemaSet(
                to: .mint, sharedDataDir: workspace.schemaDir(.mint), schemaID: "mint_fixture",
                learningStore: store, learningWriter: writer, luaFile: nil)
            if case .recovered(let recovery) = mint.userDBOutcome { #expect(recovery.imported == 1) } else {
                Issue.record("mint: \(String(describing: mint.userDBOutcome))")
            }
            #expect(candidates(engine, "nihaoshijian").first == "你好时间")
            let old = candidates(engine, "nihaoshijie")
            #expect(old.first == "你好世界" && !old.contains("你好时间"), "\(old)")
        }

        /// The same edit to `chang` and the sentence `是长`: 长 reads `zhang`, the raw input
        /// `nihaoshichang` does not spell `ni hao shi zhang`, and the stale `ni hao shi jie`
        /// is not reused, so `你好是长` is not learned at all.
        @Test func partialSelectionThenUnverifiableEditIsNotLearned() throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)

            try typeSelectAndEditTail(engine, replacingThreeKeysWith: "chang")
            #expect(engine.currentState.preedit == "你好shi chang", "\(engine.currentState.preedit)")
            #expect(try selectCandidate(engine, "是长").committedText == "你好是长")
            writer.flush()
            let learned = try store.allEntries()
            #expect(learned.isEmpty, "\(learned)")
        }

        /// Xiaohe double pinyin under a name with no double-pinyin marker (`wanxiang_fixture`,
        /// `custom_sp`) and as `double_pinyin_flypy`: `noema_learned.lua` stays off, since
        /// its keys are full pinyin and Xiaohe `shui` is `sang shi`. With `(shui, 水)` and
        /// `(shui, 税)` imported into the userdb and exported to the TSV, `shui` offers `丧失`
        /// and neither phrase; `uv` (Xiaohe for `shui`) offers both, 税 only from the
        /// userdb. A phrase only the TSV holds is served for neither.
        @Test(arguments: ["wanxiang_fixture", "custom_sp", "double_pinyin_flypy"])
        func learnedTranslatorStaysOffOnDoublePinyin(_ schemaID: String) async throws {
            let workspace = try LexiconWorkspace()
            try workspace.useDoublePinyinFlypy(in: .wanxiang, appending: "丧\tsang\t500\n失\tshi\t500\n丧失\tsang shi\t100000\n")
            try workspace.addSchema(schemaID, copying: "wanxiang_fixture", in: .wanxiang)
            #expect(!LexiconWorkspace.dictionary(of: .wanxiang).contains("税"))
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let learned = ["水", "税"].map { LearningCommitEvent(rawInput: "shui", preedit: "shui", text: $0) }
            #expect(try store.recordBatch(learned) == 2)

            let report = try await engine.switchSchemaSet(
                to: .wanxiang, sharedDataDir: workspace.schemaDir(.wanxiang), schemaID: schemaID,
                learningStore: store, luaFile: LexiconWorkspace.lua)
            #expect(engine.currentState.schemaID == schemaID && report.learnedLines == 2 && report.userDictCodeFormat == .toneless)
            let live = try String(
                contentsOf: workspace.setDir(.wanxiang).appending(path: "build/\(schemaID).schema.yaml"), encoding: .utf8)
            #expect(live.contains("lua_translator@*noema_learned"), "the deployer dropped the translator")
            let tsv = try String(contentsOf: workspace.setDir(.wanxiang).appending(path: NoemaPaths.learnedTSVFileName), encoding: .utf8)
            #expect(tsv.contains("shui\t水\t") && tsv.contains("shui\t税\t"), "\(tsv)")

            let sangShi = candidates(engine, "shui")
            #expect(sangShi.contains("丧失") && !sangShi.contains("水") && !sangShi.contains("税"), "\(sangShi)")
            let shui = candidates(engine, "uv")
            #expect(shui.contains("水") && shui.contains("税"), "\(shui)")

            // A phrase only the TSV holds: no Lua lookup serves it under the raw keys.
            #expect(try store.recordBatch([LearningCommitEvent(rawInput: "shui", preedit: "shui", text: "睡")]) == 1)
            #expect(engine.refreshLearnedPhrases(from: store) == 3)
            engine.resetSession()
            let after = candidates(engine, "shui")
            #expect(!after.contains("睡") && !after.contains("水"), "noema_learned.lua served a full-pinyin key: \(after)")
        }

        /// A full-pinyin speller with fuzzy `derive`, jianpin `abbrev`, `erase`, and a tone
        /// `xform` (rime_ice's shape) keeps every full-pinyin syllable as typed, so
        /// `noema_learned.lua` stays on: a phrase only the TSV holds is served for `nihao`
        /// and `ni'hao`.
        @Test func learnedTranslatorStaysOnForFullPinyinWithDerivedSpellings() async throws {
            let workspace = try LexiconWorkspace()
            try workspace.useJianpinAbbreviations(in: .rimeIce, appending: "")
            try workspace.replace(in: .rimeIce, "rime_ice_fixture.schema.yaml", "    - abbrev/^([a-z]).+$/$1/\n", with: """
                    - abbrev/^([a-z]).+$/$1/
                    - derive/^([zcs])h/$1/
                    - derive/([dtngkhrzcs])o(u|ng)$/$1o/
                    - erase/^hm$/
                    - erase/^ng$/
                    - xform/[1-5]$//
                    - xform/^([nl])ue$/$1ve/

                """)
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let host = SwitcherHost(workspace: workspace, engine: engine)
            #expect(try await host.switchAndWait(.rimeIce, "rime_ice_fixture").phase == .ready)
            let store = try workspace.openStore()
            defer { store.close() }
            #expect(try store.recordBatch([LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "霓昊")]) == 1)
            #expect(!candidates(engine, "nihao").contains("霓昊"))
            #expect(engine.refreshLearnedPhrases(from: store) == 1)
            engine.resetSession()
            #expect(candidates(engine, "nihao").contains("霓昊"), "noema_learned.lua is off on a full-pinyin schema")
            #expect(candidates(engine, "ni'hao").contains("霓昊"))
        }

        /// A schema whose dictionary spells codes with Unicode tone marks, as 万象 v18.2.1's
        /// does (Codex #4709690149): the guardian detects `.unicodeToned` from the compiled
        /// `speller/algebra` and imports `learning.sqlite`'s toneless `pinyin_norm` spelled
        /// that way (`ni hao` + 霓昊 -> `ní hào`; the polyphone 昊行 typed `hao hang` ->
        /// `hào hāng`; `lve`/`nv` -> `lüè`/`nǚ`), so with no Lua translator real librime
        /// serves each phrase on page 1, again after the userdb is corrupted and rebuilt from
        /// the store. A toneless code (`ni hao`) is imported but never found.
        @Test func tonedDictionaryUserDBServesLearnedPhrasesWithoutLua() async throws {
            let workspace = try LexiconWorkspace()
            try workspace.addTonedWanxiangSchema("wanxiang_toned", in: .wanxiang)
            let engine = try workspace.engine(luaFile: nil)
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let learned = [("ni hao", "霓昊"), ("ni nv", "霓女"), ("hao hang", "昊行"), ("lve hao", "略昊"), ("chong hao", "重昊")]
            #expect(try store.recordBatch(learned.map { pinyin, text in
                LearningCommitEvent(rawInput: pinyin.replacingOccurrences(of: " ", with: ""), preedit: pinyin, text: text)
            }) == learned.count)
            func switchToToned() async throws -> SchemaSetSwitchReport {
                try await engine.switchSchemaSet(
                    to: .wanxiang, sharedDataDir: workspace.schemaDir(.wanxiang), schemaID: "wanxiang_toned",
                    learningStore: store, luaFile: nil)
            }
            func expectPageOne(_ label: String) {
                for (pinyin, text) in learned {
                    let page = candidates(engine, pinyin.replacingOccurrences(of: " ", with: ""), pages: 1)
                    #expect(page.contains(text), "\(label): \(text) is not on page 1 of \(pinyin): \(page)")
                }
            }

            let report = try await switchToToned()
            #expect(report.userDictCodeFormat == .unicodeToned && report.userDictName == "wanxiang_toned")
            guard case .recovered(let rebuilt) = report.userDBOutcome else {
                Issue.record("\(String(describing: report.userDBOutcome)), \(String(describing: report.userDBFailure))")
                return
            }
            #expect(rebuilt.imported == learned.count)
            #expect(try store.watermark(for: .wanxiang, dictName: "wanxiang_toned")?.codeFormat == "unicodeToned")
            expectPageOne("projected")
            let snapshot = try String(contentsOf: UserDBGuardian.snapshotURL(
                "wanxiang_toned", in: NoemaPaths.userDBSnapshotsDir(.wanxiang, root: workspace.user)), encoding: .utf8)
            for line in ["霓昊\tní hào\t", "霓女\tní nǚ\t", "昊行\thào hāng\t", "略昊\tlüè hào\t", "重昊\tchōng hào\t"] {
                #expect(snapshot.contains(line), "\(line) is not in the userdb: \(snapshot)")
            }

            // Corrupt the userdb (and drop its snapshot): the rebuild from the store serves them again.
            try await engine.switchSchemaSet(to: .builtin, sharedDataDir: LexiconWorkspace.builtin, learningStore: store)
            try FileManager.default.removeItem(at: NoemaPaths.userDBSnapshotsDir(.wanxiang, root: workspace.user))
            try #require(!LevelDBCorruption.current.apply(to: workspace.setDir(.wanxiang).appending(path: "wanxiang_toned.userdb")).isEmpty)
            let again = try await switchToToned()
            guard case .recovered(let recovery) = again.userDBOutcome else {
                Issue.record("\(String(describing: again.userDBOutcome)), \(String(describing: again.userDBFailure))")
                return
            }
            #expect(recovery.method == .fullRebuild && recovery.quarantined != nil && recovery.imported == learned.count)
            expectPageOne("rebuilt")

            // The toneless fixtures of the other sets keep toneless codes.
            let ice = try await engine.switchSchemaSet(
                to: .rimeIce, sharedDataDir: workspace.schemaDir(.rimeIce), schemaID: "rime_ice_fixture", learningStore: store, luaFile: nil)
            #expect(ice.userDictCodeFormat == .toneless && candidates(engine, "nihao", pages: 1).contains("霓昊"))
        }

        /// A healthy userdb projected with toneless codes, as before Noema matched the
        /// dictionary's spelling (its watermark `toneless` at the latest revision; 万象 never
        /// finds `ni hao`), is replayed in full, toned, once the schema's speller shows a toned
        /// dictionary, though the store has not changed since.
        @Test func userDBProjectedTonelessIsReprojectedToned() async throws {
            let workspace = try LexiconWorkspace()
            try workspace.addTonedWanxiangSchema("wanxiang_toned", algebra: nil, in: .wanxiang)
            let engine = try workspace.engine(luaFile: nil)
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            #expect(try store.recordBatch([LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "霓昊")]) == 1)
            func switchToToned() async throws -> SchemaSetSwitchReport {
                try await engine.switchSchemaSet(
                    to: .wanxiang, sharedDataDir: workspace.schemaDir(.wanxiang), schemaID: "wanxiang_toned",
                    learningStore: store, luaFile: nil)
            }
            let toneless = try await switchToToned()
            #expect(toneless.userDictCodeFormat == .toneless)
            let mark = try #require(try store.watermark(for: .wanxiang, dictName: "wanxiang_toned"))
            let latest = try store.latestRevision()
            #expect(mark.codeFormat == "toneless" && mark.lastRevision == latest)
            try await engine.switchSchemaSet(to: .builtin, sharedDataDir: LexiconWorkspace.builtin, learningStore: store)

            try workspace.useAlgebra(LexiconWorkspace.wanxiangFullPinyinAlgebra, in: .wanxiang, schema: "wanxiang_toned")
            let report = try await switchToToned()
            #expect(report.userDictCodeFormat == .unicodeToned)
            #expect(report.userDBOutcome == .healthy(projected: 1), "\(String(describing: report.userDBOutcome))")
            #expect(try store.watermark(for: .wanxiang, dictName: "wanxiang_toned")?.codeFormat == "unicodeToned")
            #expect(candidates(engine, "nihao", pages: 1).contains("霓昊"))
        }

        /// `noema_learned.lua` on 万象's toned full-pinyin algebra, where `ni` passes through
        /// `ni0` and only a later `derive` restores it, stays on and serves a phrase only the
        /// TSV holds for `nihao` and `ni'hao`; the same toned dictionary under 万象's 小鹤双拼
        /// rules (a schema name with no double-pinyin marker) keeps it off: `shui` (`sang shi`)
        /// offers 丧失 and never the TSV's 水, while `uv` offers 水 from the dictionary.
        @Test func learnedTranslatorFollowsTonedSpellerAlgebra() async throws {
            let workspace = try LexiconWorkspace()
            try workspace.addTonedWanxiangSchema("wanxiang_toned", in: .wanxiang)
            try workspace.addTonedWanxiangSchema("wanxiang_toned_custom", algebra: LexiconWorkspace.wanxiangXiaoheAlgebra, in: .wanxiang)
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let full = try await engine.switchSchemaSet(
                to: .wanxiang, sharedDataDir: workspace.schemaDir(.wanxiang), schemaID: "wanxiang_toned", luaFile: LexiconWorkspace.lua)
            #expect(full.userDictCodeFormat == .unicodeToned)
            #expect(try store.recordBatch([
                LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "霓昊"),
                LearningCommitEvent(rawInput: "shui", preedit: "shui", text: "水"),
            ]) == 2)
            #expect(!candidates(engine, "nihao").contains("霓昊"))
            #expect(engine.refreshLearnedPhrases(from: store) == 2)
            engine.resetSession()
            #expect(candidates(engine, "nihao", pages: 1).contains("霓昊"), "noema_learned.lua is off on toned full pinyin")
            #expect(candidates(engine, "ni'hao", pages: 1).contains("霓昊"))

            let xiaohe = try await engine.switchSchemaSet(
                to: .wanxiang, sharedDataDir: workspace.schemaDir(.wanxiang), schemaID: "wanxiang_toned_custom", luaFile: LexiconWorkspace.lua)
            #expect(xiaohe.userDictCodeFormat == .unicodeToned)
            let sangShi = candidates(engine, "shui")
            #expect(sangShi.contains("丧失") && !sangShi.contains("水"), "noema_learned.lua served a full-pinyin key: \(sangShi)")
            #expect(candidates(engine, "uv").contains("水"))
            #expect(!candidates(engine, "nihao").contains("霓昊"))
        }

        /// Double pinyin and jianpin through real librime: 万象 runs `double_pinyin_flypy`'s
        /// speller (`uijx` shows the preedit `shi jia`), 雾凇 adds jianpin abbreviations (`nh`
        /// shows `n h`, `shij` shows `shi j`). `learning.sqlite` stores full pinyin, never the
        /// raw keys or the initials, and 薄荷 (full pinyin, no Lua translator) serves the phrases
        /// from its rebuilt userdb and TSV under full pinyin.
        @Test func doublePinyinAndJianpinCommitsAreLearnedUnderFullPinyin() async throws {
            let workspace = try LexiconWorkspace()
            try workspace.useDoublePinyinFlypy(in: .wanxiang, appending: "施加\tshi jia\t100000\n")
            try workspace.useJianpinAbbreviations(in: .rimeIce, appending: "女孩\tnv hai\t100000\n")
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)
            let host = SwitcherHost(workspace: workspace, engine: engine, store: store, writer: writer)

            #expect(try await host.switchAndWait(.wanxiang, "wanxiang_fixture").phase == .ready)
            let shuangpin = try commit(engine, "uijx", "施加")
            #expect(shuangpin.preedit == "shi jia" && shuangpin.committed == "施加", "\(shuangpin)")
            #expect(try await host.switchAndWait(.rimeIce, "rime_ice_fixture").phase == .ready)
            let girl = try commit(engine, "nh", "女孩")
            #expect(girl.preedit == "n h" && girl.committed == "女孩", "\(girl)")
            let time = try commit(engine, "shij", "时间")
            #expect(time.preedit == "shi j" && time.committed == "时间", "\(time)")
            writer.flush()
            let learned = Dictionary(uniqueKeysWithValues: try store.allEntries().map { ($0.text, $0.pinyinNorm) })
            #expect(learned == ["施加": "shi jia", "女孩": "nv hai", "时间": "shi jian"], "\(learned)")

            // 薄荷: no abbreviations, no double pinyin, no Lua; 施 is not in its dictionary.
            #expect(!LexiconWorkspace.dictionary(of: .mint).contains("施"))
            let mint = try await engine.switchSchemaSet(
                to: .mint, sharedDataDir: workspace.schemaDir(.mint), schemaID: "mint_fixture",
                learningStore: store, learningWriter: writer, luaFile: nil)
            if case .recovered(let recovery) = mint.userDBOutcome { #expect(recovery.imported == 3) } else {
                Issue.record("mint: \(String(describing: mint.userDBOutcome))")
            }
            #expect(candidates(engine, "shijia").contains("施加"), "the userdb lacks shi jia")
            #expect(candidates(engine, "nvhai").first == "女孩")
            #expect(candidates(engine, "shijian").first == "时间")
            let tsv = try String(contentsOf: workspace.setDir(.mint).appending(path: NoemaPaths.learnedTSVFileName), encoding: .utf8)
            #expect(Set(tsv.split(separator: "\n").map { $0.split(separator: "\t").prefix(2).joined(separator: "\t") })
                    == ["shijia\t施加", "nvhai\t女孩", "shijian\t时间"], "\(tsv)")
        }

        /// Shape and non-Mandarin schemas never feed or take full-pinyin learning (Codex
        /// #4707351661): `wubi98_mint` (Wubi 98 shape codes, `table_translator` plus a
        /// tagged `script_translator@pinyin` reverse lookup), `mint_shape` (the same under a
        /// neutral name, so only the translator check guards it), and `jyutping_fixture`
        /// (an untagged `script_translator`, so only the name check guards it). Their codes
        /// `wo` (伙) and `shi` (椒) are valid Mandarin syllables, yet nothing is learned; the
        /// guardian checks the schema's userdb but projects no `learning.sqlite` entry
        /// (`霓昊`) into it and records no watermark; `noema_learned.lua` stays off; and the
        /// full-pinyin 雾凇 set never offers 伙 for `wo` or 椒 for `shi`.
        @Test(arguments: ["wubi98_mint", "mint_shape", "jyutping_fixture"])
        func nonMandarinPinyinSchemasNeitherLearnNorReceiveProjection(_ schemaID: String) async throws {
            let workspace = try LexiconWorkspace()
            try workspace.addNonMandarinFixtures(in: .mint)
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(engine.currentSchemaIsMandarinPinyin, "noema_pinyin is full pinyin")
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)
            #expect(try store.recordBatch([LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "霓昊")]) == 1)

            let report = try await engine.switchSchemaSet(
                to: .mint, sharedDataDir: workspace.schemaDir(.mint), schemaID: schemaID,
                learningStore: store, learningWriter: writer, luaFile: LexiconWorkspace.lua)
            #expect(engine.currentState.schemaID == schemaID)
            #expect(!report.isMandarinPinyinSchema && !engine.currentSchemaIsMandarinPinyin)
            #expect(report.userDictName == schemaID)
            #expect(report.userDBOutcome == .nothingToDo, "\(String(describing: report.userDBOutcome))")
            #expect(try store.stats().watermarks.isEmpty, "a non-pinyin userdb got a watermark")
            #expect(!candidates(engine, "nihao").contains("霓昊"), "the learned phrase reached \(schemaID)")

            #expect(try commit(engine, "wo", "伙").committed == "伙")
            #expect(try commit(engine, "shi", "椒").committed == "椒")
            writer.flush()
            #expect(writer.statistics.enqueued == 2, "the commits were not observed")
            let learned = try store.allEntries()
            #expect(learned.map(\.text) == ["霓昊"], "\(schemaID) commits were learned: \(learned)")

            let ice = try await engine.switchSchemaSet(
                to: .rimeIce, sharedDataDir: workspace.schemaDir(.rimeIce), schemaID: "rime_ice_fixture",
                learningStore: store, learningWriter: writer, luaFile: LexiconWorkspace.lua)
            #expect(ice.isMandarinPinyinSchema && engine.currentSchemaIsMandarinPinyin)
            let wo = candidates(engine, "wo")
            let shi = candidates(engine, "shi")
            #expect(wo.first == "我" && !wo.contains("伙"), "\(wo)")
            #expect(!shi.contains("椒"), "\(shi)")
            #expect(candidates(engine, "nihao").contains("霓昊"))
            #expect(try store.stats().watermarks.map(\.dictName) == ["rime_ice_fixture"])
        }

        /// A reverse lookup inside a full-pinyin schema is never learned (Codex #4710447100):
        /// in `mint_reverse` (薄荷's `Uw` Wubi 98 lookup), `Uwwo` commits 伙, whose Wubi code
        /// `wo` is a valid syllable, yet `learning.sqlite` stays empty and 雾凇 never offers 伙
        /// for `wo`; ordinary pinyin in the same schema (`nihao`, `ni'hao`) is still learned.
        @Test func reverseLookupCommitsInAPinyinSchemaAreNotLearned() async throws {
            let workspace = try LexiconWorkspace()
            try workspace.addReverseLookupSchema(in: .mint)
            let engine = try workspace.engine(luaFile: nil)
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)

            let report = try await engine.switchSchemaSet(
                to: .mint, sharedDataDir: workspace.schemaDir(.mint), schemaID: "mint_reverse",
                learningStore: store, learningWriter: writer, luaFile: nil)
            #expect(engine.currentState.schemaID == "mint_reverse" && report.isMandarinPinyinSchema)
            #expect(!engine.isPrimaryPinyinInput("Uwwo") && !engine.isPrimaryPinyinInput("nihao`wo") && engine.isPrimaryPinyinInput("nihao"))
            #expect(try commit(engine, "Uwwo", "伙").committed == "伙")
            #expect(try commit(engine, "Uwshi", "椒").committed == "椒")
            // Mid-composition reverse lookup after a pinyin prefix (`nihao` + `` `wo ``):
            // commits `你好伙` in one composition, yet must never learn `("ni hao wo", "你好伙")`.
            for character in "nihao`wo" { _ = engine.processKey(.text(character)) }
            #expect(engine.processKey(.key(VirtualKeyCode.space, " ")).committedText == nil)
            let mixedCommit = engine.processKey(.key(VirtualKeyCode.space, " "))
            #expect(mixedCommit.committedText == "你好伙", "\(mixedCommit)")
            writer.flush()
            #expect(writer.statistics.enqueued == 3, "the reverse-lookup commits were not observed")
            let afterLookup = try store.allEntries()
            #expect(afterLookup.isEmpty, "reverse lookup was learned: \(afterLookup)")

            #expect(try commit(engine, "nihao", "你好").committed == "你好")
            #expect(try commit(engine, "ni'hao", "你好").committed == "你好")
            writer.flush()
            let learned = try store.allEntries()
            #expect(learned.map(\.text) == ["你好"] && learned.first?.pinyinNorm == "ni hao", "\(learned)")

            _ = try await engine.switchSchemaSet(
                to: .rimeIce, sharedDataDir: workspace.schemaDir(.rimeIce), schemaID: "rime_ice_fixture",
                learningStore: store, learningWriter: writer, luaFile: nil)
            let wo = candidates(engine, "wo")
            #expect(wo.first == "我" && !wo.contains("伙"), "\(wo)")
            #expect(!candidates(engine, "shi").contains("椒"))
        }

        /// A `translator/dictionary` with a dot and no `translator/user_dict` names the userdb
        /// by its language component, as librime does (Codex #4710447107): `dotted_dict` over
        /// `noema_pinyin.extra` opens `noema_pinyin.userdb`, which the guardian fills, checks,
        /// and restores after corruption; `explicit_user_dict` keeps `custom.user` verbatim.
        @Test func dottedDictionaryUsesItsLanguageComponentAsTheUserDB() async throws {
            let workspace = try LexiconWorkspace()
            try workspace.addSchema("dotted_dict", dictionary: "noema_pinyin.extra", in: .mint)
            try workspace.addSchema("explicit_user_dict", dictionary: "noema_pinyin.extra", userDict: "custom.user", in: .mint)
            let engine = try workspace.engine(luaFile: nil)
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            #expect(try store.recordBatch([LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "霓昊")]) == 1)
            #expect(!LexiconWorkspace.dictionary(of: .mint).contains("霓昊"))
            func to(_ schemaID: String) async throws -> SchemaSetSwitchReport {
                let report = try await engine.switchSchemaSet(
                    to: .mint, sharedDataDir: workspace.schemaDir(.mint), schemaID: schemaID, learningStore: store, luaFile: nil)
                #expect(engine.currentState.schemaID == schemaID && report.userDBFailure == nil)
                return report
            }
            func toBuiltin() async throws {
                try await engine.switchSchemaSet(to: .builtin, sharedDataDir: LexiconWorkspace.builtin, learningStore: store)
            }
            // librime's session also opens the set's first schema (`mint_fixture`) before selecting.
            func userdbs() throws -> Set<String> {
                Set(try FileManager.default.contentsOfDirectory(atPath: workspace.setDir(.mint).path)
                    .filter { $0.hasSuffix(".userdb") && $0 != "mint_fixture.userdb" })
            }

            let first = try await to("dotted_dict")
            #expect(first.userDictName == "noema_pinyin")
            let created = try userdbs()
            #expect(created == ["noema_pinyin.userdb"], "\(created)")
            #expect(candidates(engine, "nihao").contains("霓昊"), "librime's userdb lacks the projected phrase")
            try await toBuiltin()
            #expect(try await to("dotted_dict").userDBOutcome == .healthy(projected: 0))
            try await toBuiltin()

            let userdb = workspace.setDir(.mint).appending(path: "noema_pinyin.userdb")
            #expect(try !LevelDBCorruption.current.apply(to: userdb).isEmpty)
            let recovered = try await to("dotted_dict")
            guard case .recovered = recovered.userDBOutcome else {
                Issue.record("the guardian missed the corrupt userdb: \(String(describing: recovered.userDBOutcome))")
                return
            }
            #expect(candidates(engine, "nihao").contains("霓昊"), "the restored userdb lacks the phrase")
            #expect(try userdbs() == ["noema_pinyin.userdb"])

            #expect(try await to("explicit_user_dict").userDictName == "custom.user")
            let both = try userdbs()
            #expect(both == ["custom.user.userdb", "noema_pinyin.userdb"], "\(both)")
            #expect(candidates(engine, "nihao").contains("霓昊"))
        }

        /// Standard OpenCC configs resolve from `openccDataDir` when the set's `opencc/` lacks
        /// them (Codex #4710447111), while the set's own `opencc/` files keep precedence:
        /// `opencc_s2t` (`s2t.json`) turns `hanyu` into 漢語; `opencc_std` uses a config that
        /// exists only in `openccDataDir`; `opencc_custom`'s config exists in both, and the
        /// set's copy wins. `scripts/dev/test.sh` under `sandbox-exec` denying librime's
        /// build-time OpenCC prefix reproduces a clean machine.
        @Test func standardOpenCCDataResolvesFromOpenCCDataDirWithoutShadowingPackFiles() async throws {
            let workspace = try LexiconWorkspace()
            let standard = Tool.repository.appending(path: "vendor-out/librime/share/opencc", directoryHint: .isDirectory)
            let dataDir = workspace.root.appending(path: "opencc-data", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            for name in try FileManager.default.contentsOfDirectory(atPath: standard.path) {
                try FileManager.default.createSymbolicLink(at: dataDir.appending(path: name), withDestinationURL: standard.appending(path: name))
            }
            try LexiconWorkspace.writeOpenCCConfig("noema_std", mapping: "汉语标准", in: dataDir)
            try LexiconWorkspace.writeOpenCCConfig("noema_custom", mapping: "汉语乙", in: dataDir)
            let packOpenCC = workspace.schemaDir(.mint).appending(path: "opencc", directoryHint: .isDirectory)
            try LexiconWorkspace.writeOpenCCConfig("noema_custom", mapping: "汉语甲", in: packOpenCC)
            #expect(!FileManager.default.fileExists(atPath: packOpenCC.appending(path: "s2t.json").path))
            for (schemaID, config) in [("opencc_s2t", "s2t.json"), ("opencc_std", "noema_std.json"), ("opencc_custom", "noema_custom.json")] {
                try workspace.addOpenCCSchema(schemaID, config: config, dictionary: "opencc_dict", in: .mint)
            }

            let previous = getenv(RimeEngineConfiguration.openccDataDirVariable).map { String(cString: $0) }
            defer {
                if let previous { setenv(RimeEngineConfiguration.openccDataDirVariable, previous, 1) } else {
                    unsetenv(RimeEngineConfiguration.openccDataDirVariable)
                }
            }
            let engine = try workspace.engine(luaFile: nil, openccDataDir: dataDir)
            defer { engine.shutdown() }
            #expect(engine.configuration.openccDataDir == dataDir)
            var firsts: [String: String?] = [:]
            for schemaID in ["opencc_s2t", "opencc_std", "opencc_custom"] {
                _ = try await engine.switchSchemaSet(to: .mint, sharedDataDir: workspace.schemaDir(.mint), schemaID: schemaID, luaFile: nil)
                #expect(engine.currentState.schemaID == schemaID)
                #expect(engine.configuration.openccDataDir == dataDir, "the switch dropped openccDataDir")
                firsts[schemaID] = candidates(engine, "hanyu").first
            }
            #expect(getenv(RimeEngineConfiguration.openccDataDirVariable).map { String(cString: $0) } == dataDir.path)
            #expect(firsts == ["opencc_s2t": "漢語", "opencc_std": "汉语标准", "opencc_custom": "汉语甲"], "\(firsts)")
        }

        /// Two userdbs in one set keep their own projection watermarks (Codex #4707351680):
        /// `schema_a` (`dict_a`) and `schema_b` (`dict_b`) both hold revision 2; `时见` is
        /// learned at revision 3; `schema_b` takes it, and `schema_a`, switched to after, still
        /// receives it rather than reading `schema_b`'s watermark. `schema_a_alias` shares
        /// `dict_a` (`translator/user_dict`), so it shares its watermark and already has it.
        /// No Lua translator: only the userdbs can serve the phrase.
        @Test func userDBsOfOneSchemaSetKeepSeparateProjectionWatermarks() async throws {
            let workspace = try LexiconWorkspace()
            try workspace.addSchema("schema_a", dictionary: "dict_a", in: .mint)
            try workspace.addSchema("schema_b", dictionary: "dict_b", in: .mint)
            try workspace.addSchema("schema_a_alias", dictionary: "dict_a", userDict: "dict_a", in: .mint)
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            func to(_ schemaID: String) async throws -> SchemaSetSwitchReport {
                let report = try await engine.switchSchemaSet(
                    to: .mint, sharedDataDir: workspace.schemaDir(.mint), schemaID: schemaID, learningStore: store, luaFile: nil)
                #expect(engine.currentState.schemaID == schemaID && report.userDBFailure == nil)
                return report
            }
            func revision(_ dictName: String) throws -> Int64? { try store.watermark(for: .mint, dictName: dictName)?.lastRevision }
            #expect(try store.recordBatch([
                LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "霓昊"),
                LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "泥嚎"),
            ]) == 2)
            for (schemaID, dictName) in [("schema_a", "dict_a"), ("schema_b", "dict_b")] {
                let report = try await to(schemaID)
                #expect(report.userDictName == dictName)
                #expect(report.userDBOutcome == .recovered(.init(method: .fullRebuild, quarantined: nil, imported: 2, exported: 2)),
                        "\(schemaID): \(String(describing: report.userDBOutcome))")
            }
            #expect(try revision("dict_a") == 2 && revision("dict_b") == 2)

            #expect(try store.recordBatch([LearningCommitEvent(rawInput: "shijian", preedit: "shi jian", text: "时见")]) == 1)
            #expect(try await to("schema_b").userDBOutcome == .healthy(projected: 1))
            #expect(candidates(engine, "shijian").contains("时见"))
            #expect(try revision("dict_a") == 2 && revision("dict_b") == 3)

            let a = try await to("schema_a")
            #expect(a.userDBOutcome == .healthy(projected: 1), "dict_a missed 时见: \(String(describing: a.userDBOutcome))")
            #expect(candidates(engine, "shijian").contains("时见"), "schema_a never received 时见")
            #expect(try revision("dict_a") == 3)

            let alias = try await to("schema_a_alias")
            #expect(alias.userDictName == "dict_a" && alias.userDBOutcome == .healthy(projected: 0))
            #expect(candidates(engine, "shijian").contains("时见"))
            #expect(try store.stats().watermarks.map(\.dictName) == ["dict_a", "dict_b"])
        }

        /// A user `noema_pinyin.custom.yaml` that already appends `echo_translator` with
        /// `@after last`: the real `noema-rime-deployer` exits 0 with both translators in the
        /// compiled schema, and the engine booted on it serves the learned TSV phrase and
        /// echoes unmatched input.
        @Test func userAfterLastTranslatorPatchKeepsTheLearnedTranslator() throws {
            let workspace = try LexiconWorkspace()
            let patch = "patch:\n  \"engine/translators/@after last\": \"echo_translator\"\n"
            let deployerUser = workspace.root.appending(path: "deployer-user", directoryHint: .isDirectory)
            let staging = workspace.root.appending(path: "deployer-staging", directoryHint: .isDirectory)
            for directory in [deployerUser, staging, workspace.setDir(.builtin)] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for directory in [deployerUser, workspace.setDir(.builtin)] {
                try patch.write(to: directory.appending(path: "noema_pinyin.custom.yaml"), atomically: true, encoding: .utf8)
            }
            let deployer = try #require(RimeEngine.locateDeployer())
            let result = try Tool.run(deployer.path, [
                "--shared-dir", LexiconWorkspace.builtin.path, "--user-dir", deployerUser.path, "--staging-dir", staging.path,
                "--log-dir", workspace.logs.path, "--schema", "noema_pinyin", "--lua-file", LexiconWorkspace.lua.path,
            ])
            #expect(result.status == 0, "\(result)")
            let compiled = try String(contentsOf: staging.appending(path: "build/noema_pinyin.schema.yaml"), encoding: .utf8)
            #expect(compiled.contains("echo_translator") && compiled.contains("lua_translator@*noema_learned"), "\(compiled)")

            let engine = try workspace.engine()
            defer { engine.shutdown() }
            try #require(!engine.isSafeMode && engine.configuration.schemaSetID == .builtin)
            let live = try String(
                contentsOf: workspace.setDir(.builtin).appending(path: "build/noema_pinyin.schema.yaml"), encoding: .utf8)
            #expect(live.contains("echo_translator") && live.contains("lua_translator@*noema_learned"), "\(live)")
            let store = try workspace.openStore()
            defer { store.close() }
            #expect(try store.recordBatch([LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "霓昊")]) == 1)
            #expect(engine.refreshLearnedPhrases(from: store) == 1)
            engine.resetSession()
            let served = candidates(engine, "nihao")
            #expect(served.contains("霓昊"), "\(served)")
            // echo_translator echoes input no dictionary matches.
            #expect(candidates(engine, "zzzz") == ["zzzz"])
        }

        /// A user patch that overwrites the appended translator (`@last` replaces the last
        /// item after `engine/translators/+` added it): the compiled schema lacks
        /// `lua_translator@*noema_learned`, so the real deployer exits 1 and says so.
        @Test func deployerFailsWhenTheCompiledSchemaLacksTheLearnedTranslator() throws {
            let workspace = try LexiconWorkspace()
            let user = workspace.root.appending(path: "deployer-user", directoryHint: .isDirectory)
            let staging = workspace.root.appending(path: "deployer-staging", directoryHint: .isDirectory)
            for directory in [user, staging] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            try "patch:\n  \"engine/translators/@last\": \"echo_translator\"\n"
                .write(to: user.appending(path: "noema_pinyin.custom.yaml"), atomically: true, encoding: .utf8)
            let deployer = try #require(RimeEngine.locateDeployer())
            let arguments = [
                "--shared-dir", LexiconWorkspace.builtin.path, "--user-dir", user.path, "--staging-dir", staging.path,
                "--log-dir", workspace.logs.path, "--schema", "noema_pinyin",
            ]
            let result = try Tool.run(deployer.path, arguments + ["--lua-file", LexiconWorkspace.lua.path])
            #expect(result.status == 1 && result.stderr.contains("lacks lua_translator@*noema_learned"), "\(result)")
            #expect(!FileManager.default.fileExists(atPath: staging.appending(path: "build/\(DeployManifest.fileName)").path))
            // Without --lua-file the same patch deploys.
            try FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            #expect(try Tool.run(deployer.path, arguments).status == 0)
        }

        /// `noema_learned.lua` looks input up without the schema's `speller/delimiter`: a
        /// phrase only the TSV holds (never imported into the userdb) is served for `nihao`
        /// and for `ni'hao` alike.
        @Test func learnedTranslatorIgnoresSpellerDelimiters() throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            #expect(try store.recordBatch([LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "霓昊")]) == 1)
            #expect(!candidates(engine, "nihao").contains("霓昊"))
            #expect(engine.refreshLearnedPhrases(from: store) == 1)
            engine.resetSession()
            #expect(candidates(engine, "nihao").contains("霓昊"))
            engine.resetSession()
            #expect(candidates(engine, "ni'hao").contains("霓昊"), "noema_learned.lua missed ni'hao")
        }

        /// An agent `switchSchemaSet` arriving mid-composition over the real IPC manager is
        /// parked (`pendingIdle`), the preedit stays, nothing compiles; the commit that ends
        /// the composition starts it (`compiling`); a composition begun meanwhile holds the
        /// quiescent step back again (`pendingIdle`) until Escape, then `ready`.
        @Test func switchRequestedMidCompositionWaitsForTheIdleBoundary() async throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let host = SwitcherHost(workspace: workspace, engine: engine)
            let coordinator = InputSessionCoordinator(engineProvider: { [engine] in engine }, isSecureInputEnabled: { false })

            // The agent link, wired as EngineHost wires it.
            let server = InMemoryServerTransport()
            let agent = AgentServiceCoordinator(transport: server, agentVersion: "1.0.0-test")
            agent.start()
            defer { agent.stop() }
            let clock = ManualIPCClock()
            let manager = IPCConnectionManager(
                transport: InMemoryClientTransport(server: server, clock: clock),
                client: .init(bundleID: NoemaPaths.imeBundleID, version: "0.0.0-test"),
                policy: .init(heartbeatInterval: nil), clock: clock, readyNotificationName: nil)
            defer { manager.stop() }
            let reporter = CompositionIPCReporter(manager: manager, isSecureInputEnabled: { false })
            coordinator.onCompositionChange = { state in
                reporter.report(state)
                host.switcher.compositionDidChange(state)
            }
            let switcher = host.switcher
            host.forward = { event in
                manager.reportSchemaSwitch(SchemaSetSwitchStatus(
                    requestID: event.requestID, schemaSetID: event.schemaSetID, phase: event.phase, detail: event.detail))
            }
            manager.setMessageHandler { message in
                guard case .switchSchemaSet(_, let request) = message else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switcher.request(.init(requestID: request.requestID, schemaSetID: request.schemaSetID, schemaID: request.schemaID))
                    }
                }
            }
            manager.start()
            func settle() async {
                for _ in 0..<12 { manager.sync {} }
                try? await Task.sleep(for: .milliseconds(5))
            }
            await settle()
            try #require(manager.state == .healthy)

            let client = RecordingClient()
            let token = UUID()
            for key in "ni" { _ = coordinator.handleKey(.text(key), token: token, client: client) }
            try #require(engine.currentState.isComposing)
            let requestID = agent.requestSchemaSetSwitch(schemaSetID: .rimeIce, schemaID: "rime_ice_fixture")
            #expect(await eventually { await settle(); return agent.snapshot.lastSchemaSwitchStatus?.phase == .pendingIdle })
            #expect(agent.snapshot.lastSchemaSwitchStatus?.requestID == requestID)
            #expect(engine.currentState.isComposing && engine.currentState.preedit == "ni", "the preedit changed")
            #expect(engine.configuration.schemaSetID == .builtin)
            #expect(!FileManager.default.fileExists(atPath: workspace.setDir(.rimeIce).appending(path: "build").path))
            for key in "hao" { _ = coordinator.handleKey(.text(key), token: token, client: client) }
            await settle()
            #expect(switcher.parkedRequest?.requestID == requestID && engine.currentState.preedit == "ni hao")

            // The commit ends the composition and starts the switch; a new composition
            // begins before the build is ready.
            _ = coordinator.handleKey(.key(VirtualKeyCode.space, " "), token: token, client: client)
            #expect(client.inserts == ["你好"])
            #expect(host.events.last?.phase == .compiling)
            for key in "shi" { _ = coordinator.handleKey(.text(key), token: token, client: client) }
            #expect(await eventually { host.events.filter { $0.phase == .pendingIdle }.count == 2 })
            #expect(engine.currentState.isComposing && engine.configuration.schemaSetID == .builtin)
            _ = coordinator.handleKey(.key(VirtualKeyCode.escape, "\u{1B}"), token: token, client: client)
            #expect(await eventually { host.events.last?.phase == .ready })
            #expect(await eventually { await settle(); return agent.snapshot.lastSchemaSwitchStatus?.phase == .ready })
            #expect(host.events.map(\.phase) == [.pendingIdle, .compiling, .pendingIdle, .ready])
            #expect(host.events.allSatisfy { $0.requestID == requestID })
            #expect(engine.currentState.schemaID == "rime_ice_fixture")
            for key in "ni" { _ = coordinator.handleKey(.text(key), token: token, client: client) }
            #expect(!engine.currentState.candidates.isEmpty)
        }

        /// LevelDB corruption of a set's userdb, in `CURRENT`, a `MANIFEST-*`, or a `*.ldb`
        /// table: the guardian's export probe catches it before any session opens the userdb,
        /// quarantines it, restores the SHA-256-verified snapshot (plus a replay), and real
        /// librime still returns the learned phrase. 薄荷 runs without the Lua translator, so
        /// only the userdb can serve it.
        @Test(arguments: LevelDBCorruption.allCases)
        func corruptedUserDBIsDetectedQuarantinedAndRestored(_ corruption: LevelDBCorruption) async throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            #expect(try store.recordBatch([LearningCommitEvent(rawInput: "nihao", preedit: "ni hao", text: "泥嚎")]) == 1)
            func toMint() async throws -> SchemaSetSwitchReport {
                try await engine.switchSchemaSet(
                    to: .mint, sharedDataDir: workspace.schemaDir(.mint), schemaID: "mint_fixture", learningStore: store, luaFile: nil)
            }
            func toBuiltin() async throws {
                try await engine.switchSchemaSet(to: .builtin, sharedDataDir: LexiconWorkspace.builtin, learningStore: store)
            }
            _ = try await toMint()
            #expect(candidates(engine, "nihao").contains("泥嚎"))
            // Reopen once so LevelDB compacts its log into a table, then leave the set.
            try await toBuiltin()
            #expect(try await toMint().userDBOutcome == .healthy(projected: 0))
            try await toBuiltin()
            let userdb = workspace.setDir(.mint).appending(path: "mint_fixture.userdb")
            let snapshotsDir = NoemaPaths.userDBSnapshotsDir(.mint, root: workspace.user)
            try #require(UserDBGuardian.verifiedSnapshot("mint_fixture", schemaSet: .mint, in: snapshotsDir) != nil)

            let damaged = try corruption.apply(to: userdb)
            let present = (try? FileManager.default.contentsOfDirectory(atPath: userdb.path)) ?? []
            try #require(!damaged.isEmpty, "no \(corruption) file in \(present)")
            let report = try await toMint()
            guard case .recovered(let recovery) = report.userDBOutcome else {
                Issue.record("\(corruption): the guardian reported \(String(describing: report.userDBOutcome)), \(String(describing: report.userDBFailure))")
                return
            }
            #expect(recovery.method == .snapshotAndReplay && recovery.exported >= 1)
            let quarantined = try #require(recovery.quarantined)
            #expect(quarantined.deletingLastPathComponent().lastPathComponent == UserDBGuardian.quarantineDirectoryName)
            #expect(FileSafety.isRealDirectory(quarantined) && FileSafety.isRealDirectory(userdb))
            #expect(candidates(engine, "nihao").contains("泥嚎"), "\(corruption): the learned phrase is gone")
        }

        /// A deployment that fails (the set's schema now names a dictionary that does not
        /// exist) reports `failed`, keeps the engine on its current set, and leaves the
        /// target's live `build/` byte for byte unchanged, with no staging left over.
        @Test func failedDeployReportsFailedAndLeavesTheLiveBuildUnchanged() async throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let host = SwitcherHost(workspace: workspace, engine: engine)
            #expect(try await host.switchAndWait(.wanxiang, "wanxiang_fixture").phase == .ready)
            #expect(try await host.switchAndWait(.builtin, nil).phase == .ready)
            let build = workspace.setDir(.wanxiang).appending(path: "build")
            let before = try tree(build)

            try workspace.replace(in: .wanxiang, "wanxiang_fixture.schema.yaml", "  dictionary: wanxiang_fixture", with: "  dictionary: wanxiang_missing")
            let event = try await host.switchAndWait(.wanxiang, "wanxiang_fixture")
            #expect(event.phase == .failed && event.detail != nil)
            #expect(!engine.isSafeMode && engine.configuration.schemaSetID == .builtin && engine.currentState.schemaID == "noema_pinyin")
            #expect(!candidates(engine, "nihao").isEmpty)
            #expect(try tree(build) == before, "the failed deploy changed sets/wanxiang/build")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.setDir(.wanxiang).path)
                .filter { $0.hasPrefix(".deploy-staging.") || $0.hasPrefix(".build-old.") }
            #expect(leftovers.isEmpty, "\(leftovers)")
            #expect(ActiveSchemaSetRecord.load(from: NoemaPaths.activeSchemaSetURL(root: workspace.user))?.schemaSetID == .builtin)
        }

        /// One writer per root: while an engine holds `<root>/.noema-rime.lock`, a second
        /// process's engine (`noema-cli repl`) is `userDataDirLocked` and `noema-cli lexicon
        /// switch` refuses without touching anything. Once released, the offline switch
        /// deploys and saves the record, `verify` passes, and the boot configuration honors
        /// the record, falling back to the built-in set when the set is uninstalled.
        @Test func secondWriterIsRejectedAndOfflineSwitchHonorsTheLock() async throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            let common = ["--root", workspace.user.path, "--shared-dir", LexiconWorkspace.builtin.path,
                          "--log-dir", workspace.logs.path]
            let repl = try Tool.cli(["repl", "--user-dir", workspace.user.path, "--log-dir", workspace.logs.path], stdin: "ni\n")
            #expect(repl.stdout.split(separator: "\n").first == "[safe-mode: userDataDirLocked]", "\(repl.stdout)")
            let refused = try Tool.cli(
                ["lexicon", "switch", "rime-ice", "--schema", "rime_ice_fixture", "--lua-file", LexiconWorkspace.lua.path] + common, stdin: "")
            #expect(refused.status == 1 && refused.stderr.contains(BootGuard.lockFileName), "\(refused)")
            #expect(!FileManager.default.fileExists(atPath: workspace.setDir(.rimeIce).appending(path: "build").path))
            #expect(ActiveSchemaSetRecord.load(from: NoemaPaths.activeSchemaSetURL(root: workspace.user)) == nil)
            engine.shutdown()

            let switched = try Tool.cli(
                ["lexicon", "switch", "rime-ice", "--schema", "rime_ice_fixture", "--lua-file", LexiconWorkspace.lua.path] + common, stdin: "")
            #expect(switched.status == 0, "\(switched)")
            #expect(switched.stdout.contains("switched to rime-ice (rime_ice_fixture)"))
            let record = try #require(ActiveSchemaSetRecord.load(from: NoemaPaths.activeSchemaSetURL(root: workspace.user)))
            #expect(record.schemaSetID == .rimeIce && record.schemaID == "rime_ice_fixture")
            // The other fixtures name no `<defaultSchemaID>.schema.yaml`, which verify reports.
            for set in [SchemaSetID.wanxiang, .mint] { try FileManager.default.removeItem(at: workspace.schemaDir(set)) }
            let verify = try Tool.cli(["lexicon", "verify", "--lockfile", Tool.repository.appending(path: "vendor/dictionaries.lock.json").path] + common.prefix(4), stdin: "")
            #expect(verify.status == 0, "\(verify)")
            let list = try Tool.cli(["lexicon", "list"] + common.prefix(4), stdin: "")
            #expect(list.status == 0 && list.stdout.contains("active rime-ice (rime_ice_fixture)"), "\(list.stdout)")

            let boot = RimeEngineConfiguration.activeSchemaSet(
                root: workspace.user, builtinSharedDataDir: LexiconWorkspace.builtin, logDir: workspace.logs, luaFile: nil)
            #expect(boot.schemaSetID == .rimeIce && boot.schemaID == "rime_ice_fixture" && boot.sharedDataDir == workspace.schemaDir(.rimeIce))
            try FileManager.default.removeItem(at: workspace.schemaDir(.rimeIce))
            let fallback = RimeEngineConfiguration.activeSchemaSet(
                root: workspace.user, builtinSharedDataDir: LexiconWorkspace.builtin, logDir: workspace.logs, luaFile: nil)
            #expect(fallback.schemaSetID == .builtin && fallback.schemaID == "noema_pinyin" && fallback.sharedDataDir == LexiconWorkspace.builtin)
        }

        /// Under secure input nothing is learned: the shell passes every key through before
        /// the engine sees it, and the recorder drops commits on its own as well. The same
        /// keys with secure input off do write a row.
        @Test func secureInputWritesNoLearningRows() throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            let secure = SecureFlag()
            engine.recordCommits(to: writer, isSecureInputEnabled: { secure.isOn })
            let coordinator = InputSessionCoordinator(engineProvider: { [engine] in engine }, isSecureInputEnabled: { secure.isOn })
            let client = RecordingClient()
            let token = UUID()
            func typeAndCommit() {
                for key in "nihao" { _ = coordinator.handleKey(.text(key), token: token, client: client) }
                _ = coordinator.handleKey(.key(VirtualKeyCode.space, " "), token: token, client: client)
            }

            secure.isOn = true
            typeAndCommit()
            #expect(client.inserts.isEmpty)
            // The engine itself, bypassing the shell: it commits, the recorder drops it.
            engine.type("nihao")
            #expect(engine.processKey(.key(VirtualKeyCode.space, " ")).committedText == "你好")
            writer.flush()
            #expect(try store.stats().entryCount == 0, "a commit under secure input was learned")
            #expect(writer.statistics.enqueued == 0)

            secure.isOn = false
            typeAndCommit()
            #expect(client.inserts == ["你好"])
            writer.flush()
            #expect(try store.stats().entryCount == 1)
        }

        /// 500 mixed keys through the real engine (built-in set with the Lua translator) with
        /// the learning writer recording every commit: P95 stays under 2 ms.
        @Test func keyLatencyWithLearningStaysUnderTwoMilliseconds() throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)
            let keys = IMEAgentIPCTests.keys(500)
            for key in keys.prefix(50) { _ = engine.processKey(key) }
            engine.clearComposition()
            let clock = ContinuousClock()
            var samples: [Duration] = []
            var handled = 0
            for key in keys {
                let start = clock.now
                if engine.processKey(key).handled { handled += 1 }
                samples.append(clock.now - start)
            }
            writer.flush()
            samples.sort()
            let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
            print("[RimeEngine+learning latency] keys=500 handled=\(handled) P95=\(p95) max=\(samples.last!) recorded=\(writer.statistics.recorded)")
            #expect(handled > 400)
            #expect(writer.statistics.recorded > 0 && writer.statistics.dropped == 0)
            #expect(p95 < .milliseconds(2), "P95 \(p95) exceeds the 2 ms budget")
        }
    }
}

// MARK: - Fixtures

/// Three fixture schema sets installed under `<root>/schemas/<set>/`, derived from the
/// shipped `rime-default`, and the root `user_data_dir` they run in. Removed on deinit.
final class LexiconWorkspace {
    struct Fixture {
        let set: SchemaSetID
        let schemaID: String
        let prism: String?
        let appendix: String
    }

    static let builtin = EngineWorkspace.shippedSharedData
    static let lua = Tool.repository.appending(path: "Resources/rime-lua/noema_learned.lua")
    static let fixtures = [
        // 泥嚎 outranks 你好 only in the 万象 fixture; no other set's dictionary holds it.
        Fixture(set: .wanxiang, schemaID: "wanxiang_fixture", prism: nil, appendix: "泥嚎\tni hao\t100000\n"),
        Fixture(set: .rimeIce, schemaID: "rime_ice_fixture", prism: "rime_ice_fixture_prism", appendix: ""),
        Fixture(set: .mint, schemaID: "mint_fixture", prism: nil, appendix: ""),
    ]

    static func fixture(_ set: SchemaSetID) -> Fixture { fixtures.first { $0.set == set }! }

    /// The fixture dictionary text of `set`.
    static func dictionary(of set: SchemaSetID) -> String {
        let shipped = (try? String(contentsOf: builtin.appending(path: "noema_pinyin.dict.yaml"), encoding: .utf8)) ?? ""
        let fixture = fixture(set)
        return shipped.replacingOccurrences(of: "name: noema_pinyin", with: "name: \(fixture.schemaID)") + fixture.appendix
    }

    let root: URL
    var user: URL { root.appending(path: "user", directoryHint: .isDirectory) }
    var logs: URL { root.appending(path: "log", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "noema-lexicon-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        for fixture in Self.fixtures {
            let directory = schemaDir(fixture.set)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let defaults = try String(contentsOf: Self.builtin.appending(path: "default.yaml"), encoding: .utf8)
            try write(defaults.replacingOccurrences(of: "  - schema: noema_pinyin", with: "  - schema: \(fixture.schemaID)"), "default.yaml", in: fixture.set)
            var schema = try String(contentsOf: Self.builtin.appending(path: "noema_pinyin.schema.yaml"), encoding: .utf8)
            schema = schema.replacingOccurrences(of: "schema_id: noema_pinyin", with: "schema_id: \(fixture.schemaID)")
            var translator = "  dictionary: \(fixture.schemaID)"
            if let prism = fixture.prism { translator += "\n  prism: \(prism)" }
            schema = schema.replacingOccurrences(of: "  dictionary: noema_pinyin", with: translator)
            try write(schema, "\(fixture.schemaID).schema.yaml", in: fixture.set)
            try write(Self.dictionary(of: fixture.set), "\(fixture.schemaID).dict.yaml", in: fixture.set)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func schemaDir(_ set: SchemaSetID) -> URL {
        set == .builtin ? Self.builtin : NoemaPaths.downloadedSchemaDir(set, root: user)
    }

    func setDir(_ set: SchemaSetID) -> URL { NoemaPaths.schemaSetUserDataDir(set, root: user) }

    func write(_ text: String, _ name: String, in set: SchemaSetID) throws {
        try text.write(to: schemaDir(set).appending(path: name), atomically: true, encoding: .utf8)
    }

    func replace(in set: SchemaSetID, _ name: String, _ target: String, with replacement: String) throws {
        let url = schemaDir(set).appending(path: name)
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.contains(target))
        try text.replacingOccurrences(of: target, with: replacement).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Turns `set`'s fixture schema into double pinyin with `double_pinyin_flypy`'s speller
    /// algebra and preedit format (the preedit spells full pinyin), and appends `appendix`
    /// to its dictionary.
    func useDoublePinyinFlypy(in set: SchemaSetID, appending appendix: String) throws {
        let schemaID = Self.fixture(set).schemaID
        try replace(in: set, "\(schemaID).schema.yaml", "  algebra:\n    - derive/^([nl])ve$/$1ue/\n", with: """
              algebra:
                - erase/^xx$/
                - derive/^([jqxy])u$/$1v/
                - derive/^([aoe])([ioun])$/$1$1$2/
                - xform/^([aoe])(ng)?$/$1$1$2/
                - xform/iu$/Q/
                - xform/(.)ei$/$1W/
                - xform/uan$/R/
                - xform/[uv]e$/T/
                - xform/un$/Y/
                - xform/^sh/U/
                - xform/^ch/I/
                - xform/^zh/V/
                - xform/uo$/O/
                - xform/ie$/P/
                - xform/i?ong$/S/
                - xform/ing$|uai$/K/
                - xform/(.)ai$/$1D/
                - xform/(.)en$/$1F/
                - xform/(.)eng$/$1G/
                - xform/[iu]ang$/L/
                - xform/(.)ang$/$1H/
                - xform/ian$/M/
                - xform/(.)an$/$1J/
                - xform/(.)ou$/$1Z/
                - xform/[iu]a$/X/
                - xform/iao$/N/
                - xform/(.)ao$/$1C/
                - xform/ui$/V/
                - xform/in$/B/
                - xlit/QWRTYUIOPSDFGHJKLZXCVBNM/qwrtyuiopsdfghjklzxcvbnm/

            """)
        try replace(in: set, "\(schemaID).schema.yaml", "  preedit_format:\n    - xform/([nl])v/$1ü/\n", with: """
              preedit_format:
                - xform/([bpmfdtnljqx])n/$1iao/
                - xform/(\\w)g/$1eng/
                - xform/(\\w)q/$1iu/
                - xform/(\\w)w/$1ei/
                - xform/([dtnlgkhjqxyvuirzcs])r/$1uan/
                - xform/(\\w)t/$1ve/
                - xform/([gkhvuirzcs])y/$1uai/
                - xform/(\\w)y/$1un/
                - xform/([dtnlgkhvuirzcs])o/$1uo/
                - xform/(\\w)p/$1ie/
                - xform/([jqx])s/$1iong/
                - xform/(\\w)s/$1ong/
                - xform/(\\w)d/$1ai/
                - xform/(\\w)f/$1en/
                - xform/(\\w)h/$1ang/
                - xform/(\\w)j/$1an/
                - xform/([gkhvuirzcs])k/$1uai/
                - xform/(\\w)k/$1ing/
                - xform/([jqxnl])l/$1iang/
                - xform/(\\w)l/$1uang/
                - xform/(\\w)z/$1ou/
                - xform/([gkhvuirzcs])x/$1ua/
                - xform/(\\w)x/$1ia/
                - xform/(\\w)c/$1ao/
                - xform/([dtgkhvuirzcs])v/$1ui/
                - xform/(\\w)b/$1in/
                - xform/(\\w)m/$1ian/
                - xform/([aoe])\\1(\\w)/$1$2/
                - "xform/(^|[ '])v/$1zh/"
                - "xform/(^|[ '])i/$1ch/"
                - "xform/(^|[ '])u/$1sh/"
                - xform/([jqxy])v/$1u/
                - xform/([nl])v/$1ü/

            """)
        try appendToDictionary(of: set, appendix)
    }

    /// Adds jianpin to `set`'s fixture speller (`abbrev`: each syllable's first letter, and
    /// `zh`/`ch`/`sh`) and appends `appendix` to its dictionary.
    func useJianpinAbbreviations(in set: SchemaSetID, appending appendix: String) throws {
        let schemaID = Self.fixture(set).schemaID
        try replace(in: set, "\(schemaID).schema.yaml", "    - derive/^([nl])ve$/$1ue/\n", with: """
                - derive/^([nl])ve$/$1ue/
                - abbrev/^([a-z]).+$/$1/
                - abbrev/^([zcs]h).+$/$1/

            """)
        try appendToDictionary(of: set, appendix)
    }

    /// Copies `set`'s schema `source` to a new schema `schemaID` (same dictionary) and lists
    /// it in the set's `default.yaml`, so librime deploys it. A no-op for `source` itself.
    func addSchema(_ schemaID: String, copying source: String, in set: SchemaSetID) throws {
        guard schemaID != source else { return }
        let schema = try String(contentsOf: schemaDir(set).appending(path: "\(source).schema.yaml"), encoding: .utf8)
        try write(schema.replacingOccurrences(of: "schema_id: \(source)", with: "schema_id: \(schemaID)"), "\(schemaID).schema.yaml", in: set)
        try replace(in: set, "default.yaml", "  - schema: \(source)", with: "  - schema: \(source)\n  - schema: \(schemaID)")
    }

    /// Lists `schemaID` after the fixture schema in `set`'s `default.yaml`, so librime deploys it.
    func listSchema(_ schemaID: String, in set: SchemaSetID) throws {
        let fixture = Self.fixture(set).schemaID
        try replace(in: set, "default.yaml", "  - schema: \(fixture)\n", with: "  - schema: \(fixture)\n  - schema: \(schemaID)\n")
    }

    /// A copy of `set`'s fixture schema as `schemaID` over its own copy of the fixture
    /// dictionary, `dictionary`, with `translator/user_dict: userDict` when given.
    func addSchema(_ schemaID: String, dictionary: String, userDict: String? = nil, in set: SchemaSetID) throws {
        let fixture = Self.fixture(set).schemaID
        let schema = try String(contentsOf: schemaDir(set).appending(path: "\(fixture).schema.yaml"), encoding: .utf8)
        var translator = "  dictionary: \(dictionary)"
        if let userDict { translator += "\n  user_dict: \(userDict)" }
        try write(schema.replacingOccurrences(of: "schema_id: \(fixture)", with: "schema_id: \(schemaID)")
            .replacingOccurrences(of: "  dictionary: \(fixture)", with: translator), "\(schemaID).schema.yaml", in: set)
        let dictionaryURL = schemaDir(set).appending(path: "\(dictionary).dict.yaml")
        if !FileManager.default.fileExists(atPath: dictionaryURL.path) {
            try write(Self.dictionary(of: set).replacingOccurrences(of: "name: \(fixture)", with: "name: \(dictionary)"),
                      "\(dictionary).dict.yaml", in: set)
        }
        try listSchema(schemaID, in: set)
    }

    /// Three schemas whose codes are not Mandarin pinyin, each over its own dictionary
    /// mapping `wo` to 伙 and `shi` to 椒 (Wubi 98's codes for them): `wubi98_mint` and
    /// `mint_shape`, shape-code schemas (`table_translator`, plus a tagged
    /// `script_translator@pinyin` reverse lookup over the fixture dictionary), and
    /// `jyutping_fixture`, an untagged `script_translator` schema.
    func addNonMandarinFixtures(in set: SchemaSetID) throws {
        let fixture = Self.fixture(set).schemaID
        func dictionary(_ name: String) -> String {
            "---\nname: \(name)\nversion: \"1\"\nsort: by_weight\nuse_preset_vocabulary: false\n...\n伙\two\t1000\n椒\tshi\t1000\n"
        }
        for schemaID in ["wubi98_mint", "mint_shape"] {
            try write("""
                schema:
                  schema_id: \(schemaID)
                  name: \(schemaID)
                  version: "1"
                switches:
                  - name: ascii_mode
                    reset: 0
                    states: [ 中文, 西文 ]
                engine:
                  processors: [ ascii_composer, recognizer, key_binder, speller, punctuator, selector, navigator, express_editor ]
                  segmentors: [ ascii_segmentor, matcher, abc_segmentor, punct_segmentor, fallback_segmentor ]
                  translators: [ punct_translator, table_translator, "script_translator@pinyin" ]
                speller:
                  alphabet: zyxwvutsrqponmlkjihgfedcba
                  delimiter: " '"
                translator:
                  dictionary: \(schemaID)
                  enable_user_dict: true
                  enable_sentence: false
                pinyin:
                  tag: pinyin_lookup
                  dictionary: \(fixture)
                key_binder:
                  import_preset: default
                punctuator:
                  import_preset: default
                recognizer:
                  import_preset: default

                """, "\(schemaID).schema.yaml", in: set)
            try write(dictionary(schemaID), "\(schemaID).dict.yaml", in: set)
            try listSchema(schemaID, in: set)
        }
        let schema = try String(contentsOf: schemaDir(set).appending(path: "\(fixture).schema.yaml"), encoding: .utf8)
        try write(schema.replacingOccurrences(of: "schema_id: \(fixture)", with: "schema_id: jyutping_fixture")
            .replacingOccurrences(of: "  dictionary: \(fixture)", with: "  dictionary: jyutping_fixture"), "jyutping_fixture.schema.yaml", in: set)
        try write(dictionary("jyutping_fixture"), "jyutping_fixture.dict.yaml", in: set)
        try listSchema("jyutping_fixture", in: set)
    }

    /// 万象 v18.2.1's full-pinyin `speller/algebra` rules for its toned codes.
    static let wanxiangFullPinyinAlgebra = #"""
        - xform/^([a-z]+)$/$1④/
        - xform/(ā|ē|ī|ō|ū|ǖ)([a-z]*)$/$1$2①/
        - xform/(á|é|í|ó|ú|ǘ|ń|ḿ)([a-z]*)$/$1$2②/
        - xform/(ǎ|ě|ǐ|ǒ|ǔ|ǚ|ň)([a-z]*)$/$1$2③/
        - xform/(à|è|ì|ò|ù|ǜ|ǹ)([a-z]*)$/$1$2④/
        - xlit/āáǎàēéěèīíǐìōóǒòūúǔùüǖǘǚǜńňǹḿ/aaaaeeeeiiiioooouuuuvvvvvnnnm/
        - xlit/①②③④/7890
        - derive/([nl])ve(\d)/$1ue$2/
        - abbrev/^([qwrtypsdfghjklzxcbnm]).+$/$1/
        - derive/(.+)(\d)/$1/
        - derive/([zcs])h(a|e|i|u|ai|ei|an|en|ou|uo|ua|un|ui|uan|uai|uang|ang|eng|ong)$/h$1$2/
        - derive/ong$/on/
    """#
    /// 万象 v18.2.1's 小鹤双拼 `speller/algebra`, verbatim.
    static let wanxiangXiaoheAlgebra = #"""
        - xform/Ⅲ//
        - xform/^([a-z]+)$/$1④/
        - xform/(ā|ē|ī|ō|ū|ǖ)([a-z]*)$/$1$2①/
        - xform/(á|é|í|ó|ú|ǘ|ń|ḿ)([a-z]*)$/$1$2②/
        - xform/(ǎ|ě|ǐ|ǒ|ǔ|ǚ|ň)([a-z]*)$/$1$2③/
        - xform/(à|è|ì|ò|ù|ǜ|ǹ)([a-z]*)$/$1$2④/
        - xform/m̄([a-z]*)$/m$1①/
        - xform/m̀([a-z]*)$/m$1④/
        - xlit/āáǎàēéěèīíǐìōóǒòūúǔùüǖǘǚǜńňǹḿ/aaaaeeeeiiiioooouuuuvvvvvnnnm/
        - xlit/①②③④/7890
        - xform/^ng(\d)/eng$1/
        - xform/^n(\d)/en$1/
        - xform/^m(\d)/me$1/
        - derive/^([jqxy])u(\d)$/$1v$2/
        - derive/^([aoe])([ioun])(\d)$/$1$1$2$3/
        - xform/^([aoe])(ng)?(\d)$/$1$1$2$3/
        - xform/iu(\d)$/Ⓠ$1/
        - xform/(.)ei(\d)$/$1Ⓦ$2/
        - xform/uan(\d)$/Ⓡ$1/
        - xform/[uv]e(\d)$/Ⓣ$1/
        - xform/un(\d)$/Ⓨ$1/
        - xform/^sh/Ⓤ/
        - xform/^ch/Ⓘ/
        - xform/^zh/Ⓥ/
        - xform/uo(\d)$/Ⓞ$1/
        - xform/ie(\d)$/Ⓟ$1/
        - xform/(.)i?ong(\d)$/$1Ⓢ$2/
        - xform/(ing|uai)(\d)$/Ⓚ$2/
        - xform/(.)ai(\d)$/$1Ⓓ$2/
        - xform/(.)eng(\d)$/$1Ⓖ$2/
        - xform/(.)en(\d)$/$1Ⓕ$2/
        - xform/[iu]ang(\d)$/Ⓛ$1/
        - xform/(.)ang(\d)$/$1Ⓗ$2/
        - xform/ian(\d)$/Ⓜ$1/
        - xform/(.)an(\d)$/$1Ⓙ$2/
        - xform/(.)ou(\d)$/$1Ⓩ$2/
        - xform/[iu]a(\d)$/Ⓧ$1/
        - xform/iao(\d)$/Ⓝ$1/
        - xform/(.)ao(\d)$/$1Ⓒ$2/
        - xform/ui(\d)$/Ⓥ$1/
        - xform/in(\d)$/Ⓑ$1/
        - xlit/ⓆⓌⓇⓉⓎⓊⒾⓄⓅⓈⒹⒻⒼⒽⒿⓀⓁⓏⓍⒸⓋⒷⓃⓂ/qwrtyuiopsdfghjklzxcvbnm/
        - xform/^(aj|ac|ad|ew|ef|oz)(\d?)$//
        - derive/^(..)(\d)$/$1/
        - derive/^(.).+(\d)$/$1$2/
    """#

    /// A 万象-shaped schema `schemaID` in `set` over `wanxiang_toned`, a dictionary whose
    /// codes are spelled as 万象 v18.2.1's (`ní hào`, `nǚ hái`, `lüè`, the neutral tone
    /// unmarked), with 万象 v18.2.1's full-pinyin `speller/algebra` rules for the spelling
    /// (tone marks become digits, a toneless syllable becomes tone `0`, and only a later
    /// `derive` restores the toneless spelling: `ni` is `ni0` in between) or, with `xiaohe`,
    /// its 小鹤双拼 rules verbatim (`shuǐ` becomes `uv`); `algebra` nil keeps the fixture's
    /// toneless speller.
    func addTonedWanxiangSchema(
        _ schemaID: String, algebra: String? = LexiconWorkspace.wanxiangFullPinyinAlgebra, in set: SchemaSetID
    ) throws {
        let dictionary = schemaDir(set).appending(path: "wanxiang_toned.dict.yaml")
        if !FileManager.default.fileExists(atPath: dictionary.path) {
            try write("""
                ---
                name: wanxiang_toned
                version: "1"
                sort: by_weight
                use_preset_vocabulary: false
                ...
                你	nǐ	1000
                好	hǎo	1000
                霓	ní	100
                昊	hào	100
                泥	ní	500
                你好	nǐ hǎo	100000
                女	nǚ	1000
                孩	hái	1000
                女孩	nǚ hái	50000
                绿	lǜ	1000
                色	sè	1000
                绿色	lǜ sè	50000
                略	lüè	1000
                行	xíng	1000
                行	háng	800
                夯	hāng	100
                重	zhòng	1000
                重	chóng	800
                冲	chōng	1000
                庆	qìng	1000
                重庆	chóng qìng	50000
                水	shuǐ	1000
                丧	sāng	500
                失	shī	500
                丧失	sāng shī	100000
                的	de	100000

                """, "wanxiang_toned.dict.yaml", in: set)
        }
        try addSchema(schemaID, dictionary: "wanxiang_toned", in: set)
        // Its own prism: schemas sharing a dictionary would otherwise share one speller's spellings.
        try replace(in: set, "\(schemaID).schema.yaml", "  dictionary: wanxiang_toned\n",
                    with: "  dictionary: wanxiang_toned\n  prism: \(schemaID)\n")
        if let algebra { try useAlgebra(algebra, in: set, schema: schemaID) }
    }

    /// Replaces the fixture speller algebra of `schemaID` (`addTonedWanxiangSchema`) with `algebra`.
    func useAlgebra(_ algebra: String, in set: SchemaSetID, schema schemaID: String) throws {
        try replace(in: set, "\(schemaID).schema.yaml", "  algebra:\n    - derive/^([nl])ve$/$1ue/\n", with: "  algebra:\n" + algebra + "\n")
    }

    func appendToDictionary(of set: SchemaSetID, _ appendix: String) throws {
        let url = schemaDir(set).appending(path: "\(Self.fixture(set).schemaID).dict.yaml")
        try (try String(contentsOf: url, encoding: .utf8) + appendix).write(to: url, atomically: true, encoding: .utf8)
    }

    /// The input method's boot: `active-schema-set.json`, else the built-in set, with the Lua translator.
    @MainActor
    func engine(luaFile: URL? = LexiconWorkspace.lua, openccDataDir: URL? = nil) throws -> RimeEngine {
        try RimeEngine(configuration: .activeSchemaSet(
            root: user, builtinSharedDataDir: Self.builtin, logDir: logs, luaFile: luaFile, openccDataDir: openccDataDir))
    }

    /// `schemaID` in `set`, a copy of its fixture schema whose `translator/dictionary` is
    /// `dictionary` and whose candidates pass through `simplifier@cc` with `opencc_config:
    /// config` (switch `cc` on by default); `汉语 han yu` tops `dictionary`.
    func addOpenCCSchema(_ schemaID: String, config: String, dictionary: String, in set: SchemaSetID) throws {
        try addSchema(schemaID, dictionary: dictionary, in: set)
        let dictionaryURL = schemaDir(set).appending(path: "\(dictionary).dict.yaml")
        let text = try String(contentsOf: dictionaryURL, encoding: .utf8)
        if !text.contains("汉语\t") {
            try (text + "汉语\than yu\t100000\n").write(to: dictionaryURL, atomically: true, encoding: .utf8)
        }
        try replace(in: set, "\(schemaID).schema.yaml", "    - script_translator\n", with: """
                - script_translator
              filters:
                - simplifier@cc
                - uniquifier

            """)
        try replace(in: set, "\(schemaID).schema.yaml", "switches:\n", with: """
            switches:
              - name: cc
                reset: 1
                states: [ 简, 繁 ]

            """)
        let url = schemaDir(set).appending(path: "\(schemaID).schema.yaml")
        try (try String(contentsOf: url, encoding: .utf8) + "\ncc:\n  option_name: cc\n  opencc_config: \(config)\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes the OpenCC config `<name>.json` and its text dictionary mapping `汉语` to
    /// `replacement` into `directory`.
    static func writeOpenCCConfig(_ name: String, mapping replacement: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dict = #"{ "type": "text", "file": "\#(name).txt" }"#
        try #"{ "name": "\#(name)", "segmentation": { "type": "mmseg", "dict": \#(dict) }, "conversion_chain": [ { "dict": \#(dict) } ] }"#
            .write(to: directory.appending(path: "\(name).json"), atomically: true, encoding: .utf8)
        try "汉语\t\(replacement)\n".write(to: directory.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
    }

    /// A 薄荷-style reverse lookup inside `set`'s full-pinyin fixture: schema `mint_reverse`
    /// adds `affix_segmentor@wubi98_mint` and `table_translator@wubi98_mint` (`prefix: "Uw"`,
    /// over `wubi98_mint`'s `伙 wo`, `椒 shi`; `addNonMandarinFixtures`), 薄荷's
    /// `recognizer/patterns/wubi98_mint` and empty `uppercase` (the default one would tag
    /// `Uwwo` first), and upper-case letters in `speller/alphabet`.
    func addReverseLookupSchema(in set: SchemaSetID) throws {
        try addNonMandarinFixtures(in: set)
        try addSchema("mint_reverse", copying: Self.fixture(set).schemaID, in: set)
        let name = "mint_reverse.schema.yaml"
        try replace(in: set, name, "    - matcher\n", with: "    - matcher\n    - affix_segmentor@wubi98_mint\n    - affix_segmentor@backtick_lookup\n")
        try replace(in: set, name, "    - script_translator\n", with: "    - script_translator\n    - table_translator@wubi98_mint\n    - table_translator@backtick_lookup\n")
        try replace(in: set, name, "  alphabet: zyxwvutsrqponmlkjihgfedcba\n",
                    with: "  alphabet: zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA`\n")
        try replace(in: set, name, "recognizer:\n  import_preset: default\n", with: """
            recognizer:
              import_preset: default
              patterns:
                wubi98_mint: "Uw[a-z]*'?$"
                backtick_lookup: "^`[a-z]*'?$"
                uppercase: ""

            wubi98_mint:
              tag: wubi98_mint
              dictionary: wubi98_mint
              enable_user_dict: false
              prefix: "Uw"
              tips: 〔五笔〕

            backtick_lookup:
              tag: backtick_lookup
              dictionary: wubi98_mint
              enable_user_dict: false
              prefix: "`"
              tips: 〔反查〕

            """)
    }

    func openStore() throws -> LearningStore {
        try LearningStore(url: NoemaPaths.learningStoreURL(root: user))
    }
}

/// A `SchemaSetSwitcher` over `engine`, as `EngineHost` builds it, recording every event.
@MainActor
final class SwitcherHost {
    let switcher: SchemaSetSwitcher
    private(set) var events: [SchemaSetSwitcher.Event] = []
    /// Also receives every event (the IPC bridge).
    var forward: (@MainActor (SchemaSetSwitcher.Event) -> Void)?

    init(workspace: LexiconWorkspace, engine: RimeEngine, store: LearningStore? = nil, writer: LearningStoreWriter? = nil) {
        switcher = SchemaSetSwitcher(
            root: workspace.user, builtinSharedDataDir: LexiconWorkspace.builtin, luaFile: LexiconWorkspace.lua,
            learningStore: store, learningWriter: writer, engineProvider: { [engine] in engine })
        switcher.onEvent = { [weak self] event in
            self?.events.append(event)
            self?.forward?(event)
        }
    }

    /// Requests a switch and waits for its `ready` or `failed`.
    func switchAndWait(_ set: SchemaSetID, _ schemaID: String?) async throws -> SchemaSetSwitcher.Event {
        let request = SchemaSetSwitcher.Request(schemaSetID: set, schemaID: schemaID)
        switcher.request(request)
        func final() -> SchemaSetSwitcher.Event? {
            events.last { $0.requestID == request.requestID && ($0.phase == .ready || $0.phase == .failed) }
        }
        try #require(await eventually(timeout: .seconds(60)) { final() != nil }, "no outcome for \(set): \(events)")
        return try #require(final())
    }
}

/// Where a test damages a LevelDB userdb.
enum LevelDBCorruption: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case current
    case manifest
    case table

    var testDescription: String { rawValue }

    /// Overwrites the matching files of `userdb` with garbage of the same size (`CURRENT` with
    /// a name that resolves to nothing); returns the damaged file names.
    func apply(to userdb: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: userdb.path)
        let targets = names.filter { name in
            switch self {
            case .current: name == "CURRENT"
            case .manifest: name.hasPrefix("MANIFEST-")
            case .table: name.hasSuffix(".ldb") || name.hasSuffix(".sst")
            }
        }
        for name in targets {
            let url = userdb.appending(path: name)
            if self == .current {
                try Data("MANIFEST-999999\n".utf8).write(to: url)
            } else {
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
                try Data(repeating: 0xA5, count: max(size, 64)).write(to: url)
            }
        }
        return targets
    }
}

/// Types `input`, then selects `text` from up to `pages` pages: the preedit shown before
/// the selection and what it committed.
@MainActor
func commit(_ engine: RimeEngine, _ input: String, _ text: String, pages: Int = 8) throws -> (preedit: String, committed: String?) {
    engine.clearComposition()
    for character in input { _ = engine.processKey(.text(character)) }
    let preedit = engine.currentState.preedit
    for _ in 0..<pages {
        if let index = engine.currentState.candidates.firstIndex(where: { $0.text == text }) {
            return (preedit, engine.selectCandidate(at: index).committedText)
        }
        engine.changePage(backward: false)
    }
    Issue.record("no candidate \(text) for \(input) (preedit \(preedit))")
    engine.clearComposition()
    throw CancellationError()
}

/// Selects the candidate `text` from up to `pages` pages of the current composition.
@MainActor
func selectCandidate(_ engine: RimeEngine, _ text: String, pages: Int = 8) throws -> KeyHandlingResult {
    for _ in 0..<pages {
        if let index = engine.currentState.candidates.firstIndex(where: { $0.text == text }) {
            return engine.selectCandidate(at: index)
        }
        engine.changePage(backward: false)
    }
    Issue.record("no candidate \(text) in \(engine.currentState.candidates.map(\.text))")
    throw CancellationError()
}

/// `nihaoshijie`, select `你好` (preedit `你好shi jie`), then End, Left, three forward
/// Deletes (`jie` is gone), and `replacement` typed in its place.
@MainActor
func typeSelectAndEditTail(_ engine: RimeEngine, replacingThreeKeysWith replacement: String) throws {
    for character in "nihaoshijie" { _ = engine.processKey(.text(character)) }
    try #require(engine.currentState.preedit == "ni hao shi jie", "\(engine.currentState.preedit)")
    #expect(try selectCandidate(engine, "你好").committedText == nil)
    try #require(engine.currentState.preedit == "你好shi jie", "\(engine.currentState.preedit)")
    _ = engine.processKey(.key(VirtualKeyCode.end, ""))
    _ = engine.processKey(.key(VirtualKeyCode.leftArrow, ""))
    for _ in 0..<3 { _ = engine.processKey(.key(VirtualKeyCode.forwardDelete, "")) }
    try #require(engine.currentState.preedit == "你好shi", "\(engine.currentState.preedit)")
    for character in replacement { _ = engine.processKey(.text(character)) }
}

/// Every candidate text for `input` across up to `pages` pages; leaves no composition.
@MainActor
func candidates(_ engine: RimeEngine, _ input: String, pages: Int = 8) -> [String] {
    engine.clearComposition()
    for character in input { _ = engine.processKey(.text(character)) }
    var all = engine.currentState.candidates.map(\.text)
    for _ in 1..<pages {
        let before = engine.currentState.pageIndex
        let next = engine.changePage(backward: false)
        guard next.pageIndex != before else { break }
        all += next.candidates.map(\.text)
    }
    engine.clearComposition()
    return all
}

/// Polls `condition` every 5 ms, yielding the main actor, for up to `timeout`.
@MainActor
func eventually(timeout: Duration = .seconds(30), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

func inode(_ url: URL) throws -> UInt64 {
    var info = stat()
    try #require(lstat(url.path, &info) == 0)
    return UInt64(info.st_ino)
}

/// Relative path -> contents of every regular file under `directory`.
func tree(_ directory: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let enumerator = try #require(FileManager.default.enumerator(atPath: directory.path))
    while let relative = enumerator.nextObject() as? String {
        let url = directory.appending(path: relative)
        if FileSafety.isRegularFile(url) { result[relative] = try Data(contentsOf: url) }
    }
    return result
}
