import Darwin
import Foundation
import NoemaCore
import NoemaEngine
import Testing

/// `RimeEngine` end to end: the real librime, the shipped `Resources/rime-default`
/// schema, real deployment into a throwaway `user_data_dir`, real boot-guard files and
/// locks. No mocks. Nested under `LibrimeSerializedTests`, so never concurrent with any
/// other librime test.
extension LibrimeSerializedTests {
    @MainActor
    @Suite struct RimeEngineTests {
        // MARK: Typing

        @Test func fullPinyinNihao() throws {
            let workspace = try EngineWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(!engine.isSafeMode && engine.currentState.schemaID == "noema_pinyin")

            var generation = engine.currentState.generationID
            for key in "nihao" {
                let result = engine.processKey(.text(key))
                #expect(result.handled && result.committedText == nil)
                #expect(result.state.generationID > generation)
                generation = result.state.generationID
            }
            let state = engine.currentState
            #expect(state.isComposing && state.preedit == "ni hao")
            #expect(state.caretUTF8Offset == state.preedit.utf8.count && state.caretUTF16Offset == state.preedit.utf16.count)
            #expect(state.candidates.first?.text == "你好")
            #expect(state.candidates.first?.label == "1")
            #expect(state.highlightedIndex == 0 && state.commitTextPreview == "你好")

            let space = engine.processKey(.key(VirtualKeyCode.space, " "))
            #expect(space.handled && space.committedText == "你好")
            #expect(!space.state.isComposing && space.state.candidates.isEmpty && space.state.highlightedIndex == nil)
            #expect(space.state.preedit.isEmpty && space.state.isLastPage)
        }

        @Test func continuousSentence() throws {
            let workspace = try EngineWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            engine.type("jintiantianqi")
            #expect(engine.currentState.preedit == "jin tian tian qi")
            #expect(engine.currentState.candidates.first?.text == "今天天气")
            let selected = engine.selectCandidate(at: 0)
            #expect(selected.handled && selected.committedText == "今天天气" && !selected.state.isComposing)
        }

        @Test func apostropheSeparatesSyllables() throws {
            let workspace = try EngineWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            // Without the separator, "xian" is also read as the single syllable xian (先).
            engine.type("xian")
            #expect(engine.currentState.candidates.contains { $0.text == "先" })
            engine.clearComposition()
            engine.type("xi'an")
            #expect(engine.currentState.preedit == "xi'an")
            #expect(engine.currentState.candidates.first?.text == "西安")
            #expect(!engine.currentState.candidates.contains { $0.text == "先" }, "xi'an is two syllables")
            #expect(engine.processKey(.key(VirtualKeyCode.space, " ")).committedText == "西安")
        }

        @Test func pagingHighlightingAndPageLocalSelection() throws {
            let workspace = try EngineWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(!engine.isSafeMode)
            engine.type("shi")
            var state = engine.currentState
            try #require(state.candidates.count == 5, "shi must fill a page: \(state.candidates.map(\.text))")
            #expect(state.pageIndex == 0 && !state.isLastPage && state.pageSize == 5 && state.candidates.count == 5)
            #expect(state.candidates.map(\.label) == ["1", "2", "3", "4", "5"])
            let firstPage = state.candidates.map(\.text)

            state = engine.processKey(.text("=")).state
            #expect(state.pageIndex == 1 && !state.isLastPage && state.candidates.map(\.text) != firstPage)
            state = engine.processKey(.key(VirtualKeyCode.pageDown, "", .function)).state
            #expect(state.pageIndex == 2 && state.isLastPage)
            state = engine.processKey(.text("=")).state
            #expect(state.pageIndex == 2, "paging past the last page stays there")
            state = engine.processKey(.text("-")).state
            #expect(state.pageIndex == 1)
            state = engine.processKey(.key(VirtualKeyCode.pageUp, "", .function)).state
            #expect(state.pageIndex == 0 && state.candidates.map(\.text) == firstPage)
            state = engine.changePage(backward: false)
            #expect(state.pageIndex == 1)

            state = engine.highlightCandidate(at: 2)
            try #require(state.candidates.count == 5)
            #expect(state.highlightedIndex == 2 && state.commitTextPreview == state.candidates[2].text)

            // Off-page indices change nothing and report the key unhandled.
            let before = engine.currentState
            for index in [-1, 5, 99] {
                let rejected = engine.selectCandidate(at: index)
                #expect(!rejected.handled && rejected.committedText == nil && rejected.state == before)
                #expect(engine.highlightCandidate(at: index) == before)
            }

            // Index 1 is local to page 1, not the second candidate overall.
            let expected = state.candidates[1].text
            #expect(expected != firstPage[1])
            let selected = engine.selectCandidate(at: 1)
            #expect(selected.handled && selected.committedText == expected && !selected.state.isComposing)
        }

        @Test func editingCaretAndCancellation() throws {
            let workspace = try EngineWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            engine.type("nihao")
            var state = engine.processKey(.key(VirtualKeyCode.delete, "\u{7F}")).state
            #expect(state.preedit == "ni ha" && state.caretUTF8Offset == 5)
            engine.type("o")

            state = engine.processKey(.key(VirtualKeyCode.leftArrow, "", .function)).state
            #expect(state.caretUTF8Offset == 2 && state.caretUTF16Offset == 2)
            #expect(state.candidates.first?.text == "你")
            state = engine.processKey(.key(VirtualKeyCode.leftArrow, "", .function)).state
            #expect(state.caretUTF8Offset == 0 && state.caretUTF16Offset == 0)
            state = engine.processKey(.key(VirtualKeyCode.rightArrow, "", .function)).state
            #expect(state.caretUTF8Offset == 2)

            // A partial selection puts Han text before the caret: UTF-8 and UTF-16 diverge.
            let partial = engine.selectCandidate(at: 0)
            #expect(partial.handled && partial.committedText == nil)
            state = partial.state
            #expect(state.preedit == "你hao" && state.isComposing)
            #expect(state.caretUTF8Offset == 6 && state.caretUTF16Offset == 4)
            #expect(state.selectionUTF8Range == 3..<6 && state.selectionUTF16Range == 1..<4)
            // Left walks the caret back one character at a time to between 你 and h. Each
            // step differs in UTF-8 bytes and UTF-16 units (你 is 3 vs 1), so a byte offset
            // passed off as a UTF-16 offset cannot survive.
            for (utf8, utf16) in [(5, 3), (4, 2), (3, 1)] {
                state = engine.processKey(.key(VirtualKeyCode.leftArrow, "", .function)).state
                #expect(state.preedit == "你hao" && state.isComposing)
                #expect(state.caretUTF8Offset == utf8 && state.caretUTF16Offset == utf16)
            }
            for (utf8, utf16) in [(4, 2), (5, 3), (6, 4)] {
                state = engine.processKey(.key(VirtualKeyCode.rightArrow, "", .function)).state
                #expect(state.preedit == "你hao" && state.caretUTF8Offset == utf8 && state.caretUTF16Offset == utf16)
            }

            // librime's Escape drops the unconfirmed segment first, then the rest.
            let dropSegment = engine.processKey(.key(VirtualKeyCode.escape, "\u{1B}"))
            #expect(dropSegment.handled && dropSegment.committedText == nil)
            #expect(dropSegment.state.preedit == "你" && dropSegment.state.isComposing)
            let escape = engine.processKey(.key(VirtualKeyCode.escape, "\u{1B}"))
            #expect(escape.handled && escape.committedText == nil && !escape.state.isComposing)
            #expect(!engine.processKey(.key(VirtualKeyCode.escape, "\u{1B}")).handled, "idle Escape belongs to the client")

            engine.type("nihao")
            let enter = engine.processKey(.key(VirtualKeyCode.return, "\r"))
            #expect(enter.handled && enter.committedText == "nihao")

            engine.type("nihao")
            let committed = engine.commitComposition()
            #expect(committed.handled && committed.committedText == "你好" && !committed.state.isComposing)
            #expect(!engine.commitComposition().handled, "nothing to commit")

            // ⌃H edits; ⌃C passes through and keeps the composition.
            engine.type("ni")
            state = engine.processKey(.key(0x04, "\u{8}", .control, ignoring: "h")).state
            #expect(state.preedit == "n")
            let controlC = engine.processKey(.key(0x08, "\u{3}", .control, ignoring: "c"))
            #expect(!controlC.handled && controlC.state.preedit == "n")
            // ⌘ chords pass through even while composing.
            #expect(!engine.processKey(.key(0x00, "a", .command)).handled)

            engine.resetSession()
            #expect(!engine.currentState.isComposing && engine.currentState.schemaID == "noema_pinyin")
            engine.type("nihao")
            #expect(engine.currentState.candidates.first?.text == "你好")
            #expect(!engine.clearComposition().isComposing)
        }

        @Test func chinesePunctuationAndASCIIMode() throws {
            let workspace = try EngineWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            for (key, expected) in [(",", "，"), (".", "。"), ("?", "？"), ("!", "！")] {
                let result = engine.processKey(.text(Character(key)))
                #expect(result.handled && result.committedText == expected && !result.state.isComposing)
            }
            engine.type("nihao")
            #expect(engine.processKey(.text(",")).committedText == "你好，")

            // Idle keys that belong to the client.
            #expect(!engine.processKey(.text("1")).handled)
            #expect(!engine.processKey(.key(VirtualKeyCode.space, " ")).handled)
            #expect(!engine.processKey(.key(VirtualKeyCode.return, "\r")).handled)
            #expect(!engine.processKey(.key(VirtualKeyCode.leftArrow, "", .function)).handled)

            #expect(engine.setASCIIMode(true).isASCIIMode)
            for key in ["a", ",", "."] as [Character] {
                let result = engine.processKey(.text(key))
                #expect(!result.handled && result.committedText == nil && !result.state.isComposing)
            }
            #expect(!engine.setASCIIMode(false).isASCIIMode)
            engine.type("a")
            #expect(engine.currentState.isComposing && engine.currentState.candidates.first?.text == "啊")
            #expect(engine.processKey(.text("1")).committedText == "啊")
        }

        /// Without a punctuator, librime's editor commits the composition on `,` and rejects
        /// the key (DirectCommit). The engine reports exactly that: the commit and an
        /// unhandled key, so the shell inserts "你好" and then passes `,` to the client.
        @Test func unhandledKeyAfterDirectCommitPassesThrough() throws {
            let workspace = try EngineWorkspace(sharedFiles: EngineWorkspace.shippedFiles)
            try workspace.replaceInSharedFile("noema_pinyin.schema.yaml", "    - punctuator\n", with: "")
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(!engine.isSafeMode)
            engine.type("nihao")
            #expect(engine.currentState.candidates.first?.text == "你好")
            let comma = engine.processKey(.text(","))
            #expect(!comma.handled, "the comma belongs to the client")
            #expect(comma.committedText == "你好")
            #expect(!comma.state.isComposing && comma.degradation == nil)
            // Idle, the comma is simply not handled.
            let idle = engine.processKey(.text(","))
            #expect(!idle.handled && idle.committedText == nil)
        }

        @Test func deployIfNeededReusesTheStagedBuild() throws {
            let workspace = try EngineWorkspace()
            let staged = workspace.user.appending(path: "build/noema_pinyin.schema.yaml")
            let first = try workspace.engine()
            first.shutdown()
            let stamp = try #require(try FileManager.default.attributesOfItem(atPath: staged.path)[.modificationDate] as? Date)
            let deployed = try workspace.deploymentID()
            #expect(FileManager.default.fileExists(atPath: workspace.user.appending(path: "build/noema_pinyin.table.bin").path))
            #expect(try workspace.deployLeftovers().isEmpty, "staging and old builds are removed")
            let second = try workspace.engine()
            defer { second.shutdown() }
            #expect(!second.isSafeMode)
            #expect(try FileManager.default.attributesOfItem(atPath: staged.path)[.modificationDate] as? Date == stamp)
            #expect(try workspace.deploymentID() == deployed, "unchanged inputs must not redeploy")
            second.type("nihao")
            #expect(second.currentState.candidates.first?.text == "你好")
        }

        /// `select_labels` is the one C array librime sizes by `page_size`, not
        /// `num_candidates`. librime fills it only when the schema lists at least
        /// `page_size` `alternative_select_labels`; a shorter list leaves it NULL and the
        /// engine falls back to numeric labels for every slot.
        @Test(arguments: [
            ("[甲, 乙, 丙, 丁, 戊, 己, 庚]", ["甲", "乙", "丙", "丁", "戊"]),
            ("[甲, 乙, 丙]", ["1", "2", "3", "4", "5"]),
        ])
        func alternativeSelectLabels(_ list: String, _ expected: [String]) throws {
            let workspace = try EngineWorkspace(sharedFiles: EngineWorkspace.shippedFiles)
            try workspace.appendToSharedFile("noema_pinyin.schema.yaml", """

            menu:
              page_size: 5
              alternative_select_labels: \(list)

            """)
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(!engine.isSafeMode)
            engine.type("shi")
            let state = engine.currentState
            try #require(state.candidates.count == 5 && state.pageSize == 5, "shi must fill a page")
            #expect(state.candidates.map(\.label) == expected)
            // Every page reads the labels afresh; the last page may hold fewer candidates.
            let last = engine.processKey(.key(VirtualKeyCode.pageDown, "", .function)).state
            let further = engine.processKey(.key(VirtualKeyCode.pageDown, "", .function)).state
            for page in [last, further] {
                #expect(page.candidates.map(\.label) == Array(expected.prefix(page.candidates.count)))
            }
            #expect(engine.selectCandidate(at: 0).committedText != nil)
        }

        /// An added, then deleted, input under a shared-data subdirectory (one librime does
        /// not stage as YAML) each trigger one redeployment, and only one.
        @Test func deployIfNeededRedeploysWhenASharedSubdirectoryFileChanges() throws {
            let workspace = try EngineWorkspace(sharedFiles: EngineWorkspace.shippedFiles)
            try workspace.engine().shutdown()
            let firstDeploy = try workspace.deploymentID()

            let lua = workspace.shared.appending(path: "lua")
            try FileManager.default.createDirectory(at: lua, withIntermediateDirectories: true)
            try "-- extra\n".write(to: lua.appending(path: "extra.lua"), atomically: true, encoding: .utf8)
            try workspace.engine().shutdown()
            let secondDeploy = try workspace.deploymentID()
            #expect(secondDeploy != firstDeploy, "a new lua/extra.lua must redeploy")
            #expect(try workspace.manifest().inputs.contains { $0.relativePath == "shared/lua/extra.lua" })

            let engine = try workspace.engine()
            #expect(try workspace.deploymentID() == secondDeploy, "nothing changed since: no redeploy")
            engine.type("nihao")
            #expect(engine.currentState.candidates.first?.text == "你好")
            engine.shutdown()

            // Deleting the file is a change too: modification times alone cannot see it.
            try FileManager.default.removeItem(at: lua.appending(path: "extra.lua"))
            let afterDelete = try workspace.engine()
            defer { afterDelete.shutdown() }
            #expect(!afterDelete.isSafeMode)
            #expect(try workspace.deploymentID() != secondDeploy, "a deleted lua/extra.lua must redeploy")
            #expect(try !workspace.manifest().inputs.contains { $0.relativePath == "shared/lua/extra.lua" })
        }

        /// A user `*.custom.yaml` patch triggers a redeployment that librime really applies,
        /// and deleting the patch triggers one that really reverts it.
        @Test func deployIfNeededRedeploysWhenAUserCustomPatchChangesOrIsDeleted() throws {
            let workspace = try EngineWorkspace()
            let first = try workspace.engine()
            first.type("shi")
            #expect(first.currentState.pageSize == 5 && first.currentState.candidates.count == 5)
            first.shutdown()
            let firstDeploy = try workspace.deploymentID()

            let patch = workspace.user.appending(path: "noema_pinyin.custom.yaml")
            try "patch:\n  menu/page_size: 3\n".write(to: patch, atomically: true, encoding: .utf8)
            let patched = try workspace.engine()
            #expect(!patched.isSafeMode)
            let patchedDeploy = try workspace.deploymentID()
            #expect(patchedDeploy != firstDeploy)
            patched.type("shi")
            #expect(patched.currentState.pageSize == 3 && patched.currentState.candidates.count == 3,
                    "the patched page size must be live: \(patched.currentState.candidates.map(\.text))")
            patched.shutdown()

            try FileManager.default.removeItem(at: patch)
            let reverted = try workspace.engine()
            defer { reverted.shutdown() }
            #expect(!reverted.isSafeMode)
            #expect(try workspace.deploymentID() != patchedDeploy, "deleting the patch must redeploy")
            reverted.type("shi")
            #expect(reverted.currentState.pageSize == 5 && reverted.currentState.candidates.count == 5,
                    "the deleted patch must no longer apply: \(reverted.currentState.candidates.map(\.text))")
        }

        @Test func neverDeployLoadsAnExistingBuildWithoutDeploying() throws {
            let workspace = try EngineWorkspace(sharedFiles: EngineWorkspace.shippedFiles)
            try workspace.engine().shutdown()
            let deployed = try workspace.deploymentID()
            try "-- extra\n".write(to: workspace.shared.appending(path: "extra.lua"), atomically: true, encoding: .utf8)
            let engine = try workspace.engine(policy: .neverDeploy)
            defer { engine.shutdown() }
            #expect(!engine.isSafeMode)
            #expect(try workspace.deploymentID() == deployed, "neverDeploy must not deploy")
        }

        @Test func directoryPosingAsAStagedFileIsNotABuild() throws {
            let workspace = try EngineWorkspace()
            try workspace.engine().shutdown()
            let staged = workspace.user.appending(path: "build/noema_pinyin.schema.yaml")
            try FileManager.default.removeItem(at: staged)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
            let engine = try workspace.engine(policy: .neverDeploy)
            defer { engine.shutdown() }
            #expect(engine.safeModeReason == .engineInitFailed)
        }

        /// A deployment that fails (here: `default.yaml` lists a schema that does not
        /// exist) runs in the isolated subprocess and staging directory, so the previous
        /// `build/` survives byte for byte while the engine enters Safe Mode.
        @Test func failedDeploymentLeavesThePreviousBuildUntouched() throws {
            let workspace = try EngineWorkspace(sharedFiles: EngineWorkspace.shippedFiles)
            try workspace.engine().shutdown()
            let before = try workspace.buildSnapshot()
            #expect(before.keys.contains("default.yaml") && before.keys.contains("noema_pinyin.table.bin"))
            #expect(before.keys.contains(DeployManifest.fileName))

            try workspace.replaceInSharedFile("default.yaml", "page_size: 5", with: "page_size: 9")
            try workspace.replaceInSharedFile("default.yaml", "  - schema: noema_pinyin\n",
                                              with: "  - schema: noema_pinyin\n  - schema: noema_missing\n")
            let engine = try workspace.engine(policy: .forceDeploy)
            #expect(engine.safeModeReason == .engineInitFailed)
            engine.expectEverythingPassesThrough()
            engine.shutdown()
            #expect(try workspace.buildSnapshot() == before, "a failed deployment must not touch build/")
            #expect(try workspace.deployLeftovers().isEmpty)

            // The intact old build still loads without deploying.
            let fallback = try workspace.engine(policy: .neverDeploy)
            defer { fallback.shutdown() }
            #expect(!fallback.isSafeMode)
            fallback.type("shi")
            #expect(fallback.currentState.pageSize == 5)
        }

        /// No deployer to run is a failed deployment, never an in-process one.
        @Test func missingDeployerEntersSafeModeWithoutTouchingTheBuild() throws {
            let workspace = try EngineWorkspace()
            try workspace.engine().shutdown()
            let before = try workspace.buildSnapshot()
            let missing = workspace.root.appending(path: "no-such-deployer")
            let engine = try workspace.engine(policy: .forceDeploy, deployerURL: missing)
            defer { engine.shutdown() }
            #expect(engine.safeModeReason == .engineInitFailed)
            #expect(try workspace.buildSnapshot() == before)
        }

        /// A compiled dictionary missing from `build/` is an incomplete build: deployIfNeeded
        /// rebuilds it, neverDeploy refuses to load it.
        @Test func missingCompiledDictionaryIsAnIncompleteBuild() throws {
            let workspace = try EngineWorkspace()
            try workspace.engine().shutdown()
            let table = workspace.user.appending(path: "build/noema_pinyin.table.bin")

            try FileManager.default.removeItem(at: table)
            let rebuilt = try workspace.engine()
            #expect(!rebuilt.isSafeMode)
            #expect(FileManager.default.fileExists(atPath: table.path), "deployIfNeeded must rebuild the table")
            rebuilt.type("nihao")
            #expect(rebuilt.currentState.candidates.first?.text == "你好")
            rebuilt.shutdown()

            try FileManager.default.removeItem(at: table)
            let refused = try workspace.engine(policy: .neverDeploy)
            defer { refused.shutdown() }
            #expect(refused.safeModeReason == .engineInitFailed)
            #expect(!refused.processKey(.text("n")).handled)
            refused.expectEverythingPassesThrough()
            #expect(!FileManager.default.fileExists(atPath: table.path), "neverDeploy must not rebuild")
        }

        /// A compiled output whose bytes no longer match the manifest is not trusted either.
        @Test func tamperedOutputIsAnIncompleteBuild() throws {
            let workspace = try EngineWorkspace()
            try workspace.engine().shutdown()
            let prism = workspace.user.appending(path: "build/noema_pinyin.prism.bin")
            var bytes = try Data(contentsOf: prism)
            bytes[bytes.count / 2] ^= 0xFF
            try bytes.write(to: prism)
            let engine = try workspace.engine(policy: .neverDeploy)
            defer { engine.shutdown() }
            #expect(engine.safeModeReason == .engineInitFailed)
        }

        // MARK: Lifecycle

        @Test func onlyOneLiveEngineAtATime() throws {
            let workspace = try EngineWorkspace()
            let other = try EngineWorkspace()
            let first = try workspace.engine()
            #expect(throws: NoemaError.self) { try other.engine() }
            first.type("ni")
            #expect(first.currentState.isComposing, "the refused second engine must not disturb the first")

            first.shutdown()
            first.shutdown() // idempotent
            let afterShutdown = first.processKey(.text("a"))
            #expect(!afterShutdown.handled && afterShutdown.degradation == .engineUnavailable)
            #expect(!first.recoverFromSafeMode())

            let second = try other.engine()
            second.type("nihao")
            #expect(second.currentState.candidates.first?.text == "你好")
            second.shutdown()

            // An engine dropped without shutdown() releases librime, the lock, and the claim.
            do {
                let leaked = try workspace.engine()
                leaked.type("ni")
            }
            let third = try workspace.engine()
            defer { third.shutdown() }
            #expect(!third.isSafeMode)
        }

        // MARK: Safe Mode

        @Test func crashLoopEntersSafeModeWithoutTouchingLibrime() throws {
            let workspace = try EngineWorkspace()
            try workspace.writeSentinel(#"{"consecutiveFailures":2,"lastAttemptEpoch":1}"#)
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(engine.isSafeMode && engine.safeModeReason == .bootCrashLoop)
            engine.expectEverythingPassesThrough()
            #expect(!FileManager.default.fileExists(atPath: workspace.user.appending(path: "build").path),
                    "Safe Mode must not deploy")

            #expect(engine.recoverFromSafeMode())
            #expect(!engine.isSafeMode && !FileManager.default.fileExists(atPath: workspace.sentinel.path))
            engine.type("nihao")
            #expect(engine.currentState.candidates.first?.text == "你好")
        }

        /// Unfinished boots accumulate through the real engine: two failed loads arm the
        /// sentinel twice and the third boot refuses to touch librime.
        @Test func repeatedFailedBootsTripTheCrashLoopGuard() throws {
            let workspace = try EngineWorkspace()
            for attempt in 1...2 {
                let failing = try workspace.engine(policy: .neverDeploy)
                #expect(failing.safeModeReason == .engineInitFailed)
                #expect(try workspace.sentinelFailures() == attempt)
                failing.shutdown()
            }
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(engine.safeModeReason == .bootCrashLoop)
            #expect(try workspace.sentinelFailures() == 2)
            #expect(engine.recoverFromSafeMode())
            #expect(engine.processKey(.text("n")).handled)
        }

        @Test func corruptedSentinelEntersSafeMode() throws {
            let workspace = try EngineWorkspace()
            try workspace.writeSentinel("{ not json")
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(engine.safeModeReason == .bootGuardCorrupted)
            engine.expectEverythingPassesThrough()
            #expect(engine.recoverFromSafeMode())
            #expect(engine.processKey(.text("n")).handled)
        }

        @Test func lockedUserDataDirEntersSafeMode() throws {
            let workspace = try EngineWorkspace()
            try FileManager.default.createDirectory(at: workspace.user, withIntermediateDirectories: true)
            let lockPath = workspace.user.appending(path: BootGuard.lockFileName).path
            let holder = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            try #require(holder >= 0)
            defer { close(holder) }
            #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)

            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(engine.safeModeReason == .userDataDirLocked)
            engine.expectEverythingPassesThrough()
            #expect(!FileManager.default.fileExists(atPath: workspace.sentinel.path), "a locked boot must not arm the sentinel")
            #expect(!engine.recoverFromSafeMode(), "still locked")
            #expect(engine.safeModeReason == .userDataDirLocked)

            flock(holder, LOCK_UN)
            #expect(engine.recoverFromSafeMode())
            #expect(engine.processKey(.text("n")).handled)
        }

        @Test func unwritableUserDataDirEntersSafeMode() throws {
            try #require(geteuid() != 0, "root ignores directory permissions")
            let workspace = try EngineWorkspace()
            try FileManager.default.createDirectory(at: workspace.user, withIntermediateDirectories: true)
            #expect(chmod(workspace.user.path, 0o555) == 0)
            defer { chmod(workspace.user.path, 0o755) }

            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(engine.safeModeReason == .userDataDirUnwritable)
            engine.expectEverythingPassesThrough()
            #expect(!engine.recoverFromSafeMode())

            #expect(chmod(workspace.user.path, 0o755) == 0)
            #expect(engine.recoverFromSafeMode())
            #expect(engine.processKey(.text("n")).handled)
        }

        @Test func engineInitFailureEntersSafeMode() throws {
            // Never deploying into an empty user_data_dir leaves nothing to load.
            let workspace = try EngineWorkspace()
            let engine = try workspace.engine(policy: .neverDeploy)
            #expect(engine.safeModeReason == .engineInitFailed)
            engine.expectEverythingPassesThrough()
            #expect(!engine.recoverFromSafeMode())
            engine.shutdown()

            // A shared data dir without the schema fails deployment the same way.
            let broken = try EngineWorkspace(sharedFiles: ["default.yaml"])
            let brokenEngine = try broken.engine()
            defer { brokenEngine.shutdown() }
            #expect(brokenEngine.safeModeReason == .engineInitFailed)
            #expect(!brokenEngine.processKey(.text("n")).handled)
        }

        // MARK: Latency

        /// Single-key latency through the real entry path (`processKey` on a deployed
        /// engine): 50 warm-up keys, then 500 timed keys mixing letters, paging,
        /// selection, backspace, commits, and punctuation. P95 must stay under 2 ms.
        @Test func singleKeyLatencyP95() throws {
            let workspace = try EngineWorkspace()
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            var cycle: [KeyEvent] = "nihao".map(KeyEvent.text)
            cycle += [.text("="), .text("-"), .key(VirtualKeyCode.space, " ")]
            cycle += "jintiantianqi".map(KeyEvent.text)
            cycle += [.key(VirtualKeyCode.delete, "\u{7F}"), .text("i")]
            cycle += [.key(VirtualKeyCode.leftArrow, "", .function), .key(VirtualKeyCode.return, "\r")]
            cycle += "shi".map(KeyEvent.text)
            cycle += [.key(VirtualKeyCode.pageDown, "", .function), .text("2"), .text(",")]
            cycle += "xi'an".map(KeyEvent.text)
            cycle += [.key(VirtualKeyCode.escape, "\u{1B}")]
            var keys = cycle.makeIterator()
            func nextKey() -> KeyEvent {
                if let key = keys.next() { return key }
                keys = cycle.makeIterator()
                return keys.next()!
            }
            for _ in 0..<50 { _ = engine.processKey(nextKey()) }

            let clock = ContinuousClock()
            var samples: [Duration] = []
            samples.reserveCapacity(500)
            var handled = 0
            for _ in 0..<500 {
                let key = nextKey()
                let start = clock.now
                let result = engine.processKey(key)
                samples.append(clock.now - start)
                if result.handled { handled += 1 }
            }
            samples.sort()
            func percentile(_ p: Double) -> Duration { samples[min(samples.count - 1, Int(Double(samples.count) * p))] }
            func ms(_ d: Duration) -> String {
                let c = d.components
                return String(format: "%.3f", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
            }
            let p50 = percentile(0.50), p95 = percentile(0.95), p99 = percentile(0.99)
            print("[RimeEngine latency] keys=500 handled=\(handled) P50=\(ms(p50))ms P95=\(ms(p95))ms P99=\(ms(p99))ms max=\(ms(samples.last!))ms")
            #expect(handled > 400, "the mix must exercise librime, not pass keys through")
            #expect(p95 < .milliseconds(2), "P95 \(ms(p95)) ms exceeds the 2 ms budget")
        }
    }
}

// MARK: - Helpers

extension KeyEvent {
    /// A plain key typing `character` (virtual key code is irrelevant for printable input).
    static func text(_ character: Character) -> KeyEvent {
        KeyEvent(keyCode: 0x00, characters: String(character))
    }

    static func key(_ code: UInt16, _ characters: String, _ modifiers: KeyModifiers = [], ignoring: String? = nil) -> KeyEvent {
        KeyEvent(keyCode: code, characters: characters, modifiers: modifiers, charactersIgnoringModifiers: ignoring)
    }
}

extension RimeEngine {
    func type(_ text: String) {
        for character in text {
            let result = processKey(.text(character))
            #expect(result.handled, "key \(character) not handled")
        }
    }

    /// Safe Mode: every entry point degrades without handling a key or committing text.
    func expectEverythingPassesThrough() {
        let before = currentState
        #expect(before.isSafeMode && before.candidates.isEmpty)
        for event in [KeyEvent.text("n"), .text(","), .key(VirtualKeyCode.space, " "), .key(VirtualKeyCode.return, "\r")] {
            let result = processKey(event)
            #expect(!result.handled && result.committedText == nil && result.degradation == .safeMode)
        }
        let selection = selectCandidate(at: 0)
        #expect(!selection.handled && selection.degradation == .safeMode)
        let commit = commitComposition()
        #expect(!commit.handled && commit.degradation == .safeMode)
        #expect(highlightCandidate(at: 0) == before)
        #expect(changePage(backward: false) == before)
        #expect(setASCIIMode(true) == before)
        #expect(clearComposition() == before)
        resetSession()
        #expect(currentState == before)
    }
}

/// A throwaway user/log directory pair over the shipped `Resources/rime-default`
/// (or a copy holding only `sharedFiles`). Removed on deinit.
final class EngineWorkspace {
    static let shippedFiles = ["default.yaml", "noema_pinyin.schema.yaml", "noema_pinyin.dict.yaml"]
    static let shippedSharedData = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/rime-default")

    let root: URL
    let shared: URL
    var user: URL { root.appending(path: "user") }
    var logs: URL { root.appending(path: "log") }
    var sentinel: URL { user.appending(path: BootGuard.sentinelFileName) }

    init(sharedFiles: [String]? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "noema-engine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let sharedFiles {
            shared = root.appending(path: "shared")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            for name in sharedFiles {
                try FileManager.default.copyItem(at: Self.shippedSharedData.appending(path: name), to: shared.appending(path: name))
            }
        } else {
            shared = Self.shippedSharedData
        }
    }

    deinit {
        chmod(user.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func engine(policy: RimeEngineConfiguration.DeployPolicy = .deployIfNeeded, deployerURL: URL? = nil) throws -> RimeEngine {
        try RimeEngine(configuration: RimeEngineConfiguration(
            sharedDataDir: shared, userDataDir: user, logDir: logs, deployPolicy: policy, deployerURL: deployerURL
        ))
    }

    func writeSentinel(_ contents: String) throws {
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try contents.write(to: sentinel, atomically: true, encoding: .utf8)
    }

    /// Appends YAML to a copied shared file; only for workspaces built with `sharedFiles`.
    func appendToSharedFile(_ name: String, _ text: String) throws {
        precondition(shared != Self.shippedSharedData, "never edit the shipped schema")
        let url = shared.appending(path: name)
        try (String(contentsOf: url, encoding: .utf8) + text).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Replaces text in a copied shared file; the text must be present.
    func replaceInSharedFile(_ name: String, _ target: String, with replacement: String) throws {
        precondition(shared != Self.shippedSharedData, "never edit the shipped schema")
        let url = shared.appending(path: name)
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.contains(target), "\(name) lacks \(target.debugDescription)")
        try text.replacingOccurrences(of: target, with: replacement).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Identifies the live deployment: every deployment renames a fresh directory into
    /// `build/`, so its inode changes exactly when a deployment happened.
    func deploymentID() throws -> UInt64 {
        var info = stat()
        try #require(lstat(user.appending(path: "build").path, &info) == 0)
        return UInt64(info.st_ino)
    }

    func manifest() throws -> DeployManifest {
        try JSONDecoder().decode(DeployManifest.self, from: Data(contentsOf: user.appending(path: "build/\(DeployManifest.fileName)")))
    }

    /// Every file under `build/`, by relative path, with its bytes.
    func buildSnapshot() throws -> [String: Data] {
        let build = user.appending(path: "build")
        var snapshot: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(atPath: build.path))
        for case let relative as String in enumerator {
            var isDirectory: ObjCBool = false
            let url = build.appending(path: relative)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                snapshot[relative] = try Data(contentsOf: url)
            }
        }
        return snapshot
    }

    /// Staging directories or old builds a deployment left in `user_data_dir`.
    func deployLeftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: user.path)
            .filter { $0.hasPrefix(".deploy-staging.") || $0.hasPrefix(".build-old.") }
    }

    func sentinelFailures() throws -> Int {
        try JSONDecoder().decode(BootGuard.Record.self, from: Data(contentsOf: sentinel)).consecutiveFailures
    }
}
