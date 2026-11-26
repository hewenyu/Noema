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
            let watermarks = try store.stats().watermarks.map(\.schemaSet).sorted()
            #expect(watermarks == ["mint", "rime-ice"], "\(watermarks)")
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

    /// The input method's boot: `active-schema-set.json`, else the built-in set, with the Lua translator.
    @MainActor
    func engine(luaFile: URL? = LexiconWorkspace.lua) throws -> RimeEngine {
        try RimeEngine(configuration: .activeSchemaSet(root: user, builtinSharedDataDir: Self.builtin, logDir: logs, luaFile: luaFile))
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
