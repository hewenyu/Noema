import AppKit
import Foundation
import NoemaAgentCore
import NoemaCore
import NoemaEngine
import NoemaIMEShell
import NoemaIPC
import NoemaLearning
import NoemaText
@testable import NoemaUI
import os
import Testing

/// v-mode and emoji candidates end to end: the real librime with the shipped schema and
/// OpenCC emoji data, the real `noema-rime-deployer`, the real `InputSessionCoordinator`
/// with the shipped `CandidatePanelController` off screen, and the real IPC to an agent.
/// Only the text client is a recording stand-in.
extension LibrimeSerializedTests {
    @MainActor
    @Suite struct VModeAndEmojiTests {
        static let fixedNow = Date(timeIntervalSince1970: 1_795_656_600)  // 2026-11-26 09:30:00 +08:00
        static let beijing = TimeZone(secondsFromGMT: 8 * 3600)!

        // MARK: - Emoji candidates

        /// `nihao` shows 你好 then 👋 (OpenCC `noema_emoji` through `simplifier@emoji_suggestion`);
        /// `setOption(emoji_suggestion, false)` removes it for this and every later session;
        /// committing 👋 teaches `learning.sqlite` nothing, committing 你好 does.
        @Test func emojiFollowsTheWordAndIsNeverLearned() throws {
            let workspace = try LexiconWorkspace()
            let engine = try workspace.engine(luaFile: nil)
            defer { engine.shutdown() }
            try #require(!engine.isSafeMode)
            let store = try workspace.openStore()
            defer { store.close() }
            let writer = LearningStoreWriter(store: store)
            engine.recordCommits(to: writer)

            #expect(engine.option(EngineHostEmojiOption.name) == true, "the schema switch resets to on")
            #expect(Array(candidates(engine, "nihao", pages: 1).prefix(2)) == ["你好", "👋"])
            #expect(candidates(engine, "kaixin", pages: 1).contains("😊"))
            // Paging and single characters are untouched: `shi` fills more than one page.
            let shi = candidates(engine, "shi")
            #expect(shi.count > 5 && shi.prefix(5) == ["是", "时", "事", "十", "世"], "\(shi)")

            engine.clearComposition()
            engine.type("nihao")
            let emojiIndex = try #require(engine.currentState.candidates.firstIndex { $0.text == "👋" })
            #expect(engine.selectCandidate(at: emojiIndex).committedText == "👋")
            writer.flush()
            #expect(try store.allEntries().isEmpty, "an emoji commit is never learned")

            engine.setOption(EngineHostEmojiOption.name, enabled: false)
            #expect(engine.option(EngineHostEmojiOption.name) == false)
            #expect(!candidates(engine, "nihao").contains("👋"))
            engine.resetSession()
            #expect(engine.option(EngineHostEmojiOption.name) == false, "a new session keeps the override")
            #expect(!candidates(engine, "nihao").contains("👋"))
            engine.setOption(EngineHostEmojiOption.name, enabled: true)
            #expect(candidates(engine, "nihao", pages: 1).contains("👋"))

            // Positive control: the same path learns a Han commit.
            engine.clearComposition()
            engine.type("nihao")
            #expect(engine.selectCandidate(at: 0).committedText == "你好")
            writer.flush()
            #expect(try store.allEntries().map(\.text) == ["你好"])
        }

        /// Options configured before or during Safe Mode (e.g. `emoji_suggestion = false`)
        /// are replayed onto the live session when `recoverFromSafeMode()` succeeds.
        @Test func optionOverridesSurviveRecoverFromSafeMode() throws {
            let workspace = try EngineWorkspace(sharedFiles: EngineWorkspace.shippedFiles)
            try workspace.writeSentinel(#"{"consecutiveFailures":2,"lastAttemptEpoch":1}"#)
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            try #require(engine.safeModeReason == .bootCrashLoop)

            engine.setOption(EngineHostEmojiOption.name, enabled: false)
            #expect(engine.recoverFromSafeMode())
            #expect(!engine.isSafeMode)
            #expect(engine.option(EngineHostEmojiOption.name) == false, "recoverFromSafeMode dropped emoji_suggestion override")
            #expect(!candidates(engine, "nihao").contains("👋"))
        }

        // MARK: - Deployer: upstream `v` recognizers

        /// An upstream schema (万象 and 雾凇 ship one) with `recognizer/patterns/v` and
        /// `v_mode`, plus a user patch: the real deployer compiles both `v` patterns away and
        /// keeps every other pattern and the user's keys, leaves the user's file untouched,
        /// and `lv`/`nv` still spell 绿/女. A build from before v-mode (no `schemaPatches`)
        /// is redeployed once; the redeployed build is reused.
        @Test func deployerStripsUpstreamVRecognizersAndRedeploysStaleBuilds() throws {
            let workspace = try EngineWorkspace(sharedFiles: EngineWorkspace.shippedFiles)
            try workspace.replaceInSharedFile("noema_pinyin.schema.yaml", "recognizer:\n  import_preset: default\n", with: """
                recognizer:
                  import_preset: default
                  patterns:
                    v: "^v[a-z]*$"
                    v_mode: "^v.*$"
                    keepme: "^zq[a-z]*$"

                """)
            try FileManager.default.createDirectory(at: workspace.user, withIntermediateDirectories: true)
            let userPatch = workspace.user.appending(path: "noema_pinyin.custom.yaml")
            // Includes the user's own `recognizer/patterns/v` and `v_mode` keys so the wrapper
            // must beat `__include` (YAML null `~` would be overwritten by `__include`).
            let userBytes = Data(
                "patch: {\"menu/page_size\": 7, \"recognizer/patterns/v\": \"^v.*$\", \"recognizer/patterns/v_mode\": \"^v_mode.*$\", \"recognizer/patterns/mine\": \"^qq[a-z]*$\"}\n"
                    .utf8)
            try userBytes.write(to: userPatch)

            let engine = try workspace.engine()
            #expect(!engine.isSafeMode)
            let compiled = try String(contentsOf: workspace.user.appending(path: "build/noema_pinyin.schema.yaml"), encoding: .utf8)
            #expect(!compiled.contains("^v[a-z]*$") && !compiled.contains("^v.*$"), "\(compiled)")
            #expect(compiled.contains("^zq[a-z]*$") && compiled.contains("^qq[a-z]*$"))
            #expect(try Data(contentsOf: userPatch) == userBytes, "the user's patch is never edited")
            #expect(try workspace.manifest().schemaPatches == SchemaPatch.requiredPatchIDs)
            #expect(engine.isPrimaryPinyinInput("vabc"), "no recognizer claims a leading v")
            #expect(!engine.isPrimaryPinyinInput("zqabc") && !engine.isPrimaryPinyinInput("qqabc"))
            engine.type("lv")
            #expect(engine.currentState.candidates.first?.text == "绿")
            #expect(engine.currentState.pageSize == 7, "the user's page size")
            engine.clearComposition()
            engine.type("nv")
            #expect(engine.currentState.candidates.first?.text == "女")
            engine.shutdown()

            // A PR #21 build: the same outputs, a manifest without `schemaPatches`.
            var stale = try workspace.manifest()
            stale.schemaPatches = nil
            try stale.encoded().write(to: workspace.user.appending(path: "build/\(DeployManifest.fileName)"))
            let staleID = try workspace.deploymentID()
            let redeployed = try workspace.engine()
            #expect(!redeployed.isSafeMode)
            redeployed.shutdown()
            #expect(try workspace.deploymentID() != staleID, "a build without the v-mode patch must redeploy")
            #expect(try workspace.manifest().schemaPatches == SchemaPatch.requiredPatchIDs)
            let currentID = try workspace.deploymentID()
            try workspace.engine().shutdown()
            #expect(try workspace.deploymentID() == currentID, "the redeployed build is reused")
        }

        // MARK: - Coordinator and the shipped panel

        static func panel() -> CandidatePanelController {
            let controller = CandidatePanelController(style: CandidatePanelStyle())
            controller.screensProvider = {
                [ScreenFrame(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))]
            }
            controller.shouldOrderFront = false
            return controller
        }

        static func harness(_ controller: CandidatePanelController, secure: SecureFlag = SecureFlag()) throws -> Harness {
            let harness = try Harness(
                isSecureInputEnabled: { secure.isOn }, candidatePresenter: controller, vModePresenter: controller,
                now: { VModeAndEmojiTests.fixedNow }, timeZone: VModeAndEmojiTests.beijing)
            // Wired as `EngineHost` wires the shipped panel.
            controller.onSelectVModeItem = { [coordinator = harness.coordinator] index, generation in
                _ = coordinator.selectVModeItem(at: index, expectedGenerationID: generation)
            }
            return harness
        }

        static func type(_ text: String, _ harness: Harness, _ token: UUID, _ client: RecordingClient) {
            for character in text {
                let event: KeyEvent = character == " "
                    ? .key(VirtualKeyCode.space, " ")
                    : character == "\r" ? .key(VirtualKeyCode.return, "\r") : .text(character)
                _ = harness.coordinator.handleKey(event, token: token, client: client)
            }
        }

        @Test func offlineToolsCommitThroughTheShell() throws {
            let controller = Self.panel()
            let harness = try Self.harness(controller)
            defer { harness.shutdown(); controller.hideAll() }
            let client = RecordingClient()
            client.caretRect = CGRect(x: 400, y: 600, width: 1, height: 18)
            let token = UUID()

            // `v`: the 2-column menu, marked text `v`, the candidate panel hidden.
            #expect(harness.coordinator.handleKey(.text("v"), token: token, client: client))
            #expect(client.calls.last == .mark("v", caret: 1, selection: 0..<1))
            #expect(controller.isVisible && controller.isShowingVMode)
            let menu = try #require(controller.currentVModeLayout)
            #expect(menu.isMenu && menu.items.count == 9 && menu.generationID == harness.coordinator.vModeGenerationID)
            #expect(!harness.engine.currentState.isComposing, "v-mode never reaches Rime")

            // `v1+2` Space inserts 3.
            Self.type("1+2", harness, token, client)
            #expect(client.calls.last == .mark("v1+2", caret: 4, selection: 0..<4))
            let calc = try #require(controller.currentVModeLayout)
            #expect(calc.header?.title == "计算" && calc.items.map(\.displayText) == ["3", "1+2=3"])
            Self.type(" ", harness, token, client)
            #expect(client.inserts == ["3"])
            #expect(!controller.isVisible && !controller.isShowingVMode && harness.coordinator.vModeState == .idle)

            // `v8` then `1`: today's date in the pinned zone.
            Self.type("v81", harness, token, client)
            #expect(client.inserts.last == "2026-11-26")
            // `v13+4` Return: the menu's 1 then a fresh expression.
            Self.type("v13+4\r", harness, token, client)
            #expect(client.inserts.last == "7")
            // `vim` Return: the literal escape hatch; `vv`: a literal v.
            Self.type("vim\r", harness, token, client)
            #expect(client.inserts.last == "vim")
            Self.type("vv", harness, token, client)
            #expect(client.inserts.last == "v")

            // `lv`/`nv` Space: once Rime composes, v is Rime's.
            Self.type("lv ", harness, token, client)
            #expect(client.inserts.last == "绿")
            Self.type("nv ", harness, token, client)
            #expect(client.inserts.last == "女")
            // `nihao` shows the emoji in the ordinary candidate panel.
            Self.type("nihao", harness, token, client)
            #expect(Array(controller.currentLayout?.items.map(\.displayText).prefix(2) ?? []) == ["你好", "👋"])
            harness.coordinator.commitComposition(token: token, client: client)
            #expect(client.inserts.last == "nihao" || client.inserts.last == "你好")
        }

        /// A real click on the menu opens 日期时间; a click carrying an older generation does
        /// nothing; a real click on a row commits it.
        @Test func clicksAreGenerationBound() throws {
            let controller = Self.panel()
            let harness = try Self.harness(controller)
            defer { harness.shutdown(); controller.hideAll() }
            let client = RecordingClient()
            client.caretRect = CGRect(x: 400, y: 600, width: 1, height: 18)
            let token = UUID()
            #expect(harness.coordinator.handleKey(.text("v"), token: token, client: client))
            let menuGeneration = harness.coordinator.vModeGenerationID

            let view = controller.vModeViewForTesting
            let panel = controller.panelForTesting
            func click(_ index: Int) throws {
                let layout = try #require(controller.currentVModeLayout)
                let pill = layout.items[index].pillFrame
                let point = view.convert(CGPoint(x: pill.midX, y: pill.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
                }
            }
            try click(VMenuItem.dateTime.index)
            #expect(harness.coordinator.vModeState == .vSub(.dateTime(highlightedIndex: 0)))
            #expect(client.calls.last == .mark("v8", caret: 2, selection: 0..<2))
            #expect(controller.currentVModeLayout?.items.first?.displayText == "2026-11-26")

            // The menu's generation is stale now: its click is ignored.
            #expect(!harness.coordinator.selectVModeItem(at: VMenuItem.calculator.index, expectedGenerationID: menuGeneration))
            #expect(harness.coordinator.vModeState == .vSub(.dateTime(highlightedIndex: 0)) && client.inserts.isEmpty)

            try click(5)
            #expect(client.inserts == ["星期四"])
            #expect(!controller.isVisible && harness.coordinator.vModeState == .idle)
            #expect(!harness.coordinator.selectVModeItem(at: 0, expectedGenerationID: harness.coordinator.vModeGenerationID), "no v-mode")
        }

        /// Focus loss, a click outside, and secure input each end v-mode: the `v` is cleared,
        /// the panel hides, nothing is inserted.
        @Test func focusLossAndClickOutsideClearTheV() throws {
            let controller = Self.panel()
            let harness = try Self.harness(controller)
            defer { harness.shutdown(); controller.hideAll() }
            let client = RecordingClient()
            client.caretRect = CGRect(x: 400, y: 600, width: 1, height: 18)
            let token = UUID()
            Self.type("v5", harness, token, client)
            #expect(controller.isShowingVMode)
            harness.coordinator.deactivate(token: token)
            #expect(client.calls.last == .clear && !controller.isVisible && harness.coordinator.vModeState == .idle)

            Self.type("v1+", harness, token, client)
            harness.coordinator.commitComposition(token: token, client: client)
            #expect(client.calls.last == .clear && !controller.isVisible && client.inserts.isEmpty)
            #expect(harness.coordinator.vModeState == .idle)
            // `hidePalettes` and ASCII mode end it too.
            Self.type("v", harness, token, client)
            harness.coordinator.setInputMode(InputSessionCoordinator.asciiInputModeID, token: token, client: client)
            #expect(!controller.isVisible && harness.coordinator.vModeState == .idle && client.calls.last == .clear)
        }

        /// Pressing `Esc` (from menu or sub-mode) or `Backspace` (from menu) must clear marked
        /// text and hide the v-mode panel rather than leaving an orphaned panel behind.
        @Test func escapeAndBackspaceExitVModeCleaningMarkedTextAndPanel() throws {
            let controller = Self.panel()
            let harness = try Self.harness(controller)
            defer { harness.shutdown(); controller.hideAll() }
            let client = RecordingClient()
            client.caretRect = CGRect(x: 400, y: 600, width: 1, height: 18)
            let token = UUID()

            // `v` -> `Esc`
            #expect(harness.coordinator.handleKey(.text("v"), token: token, client: client))
            #expect(controller.isVisible && controller.isShowingVMode)
            #expect(harness.coordinator.handleKey(.key(VirtualKeyCode.escape, "\u{1b}"), token: token, client: client))
            #expect(client.calls.last == .clear)
            #expect(!controller.isVisible && !controller.isShowingVMode && harness.coordinator.vModeState == .idle)

            // `v` -> `Backspace`
            #expect(harness.coordinator.handleKey(.text("v"), token: token, client: client))
            #expect(controller.isVisible && controller.isShowingVMode)
            #expect(harness.coordinator.handleKey(.key(VirtualKeyCode.delete, "\u{7f}"), token: token, client: client))
            #expect(client.calls.last == .clear)
            #expect(!controller.isVisible && !controller.isShowingVMode && harness.coordinator.vModeState == .idle)

            // `v1+2` -> `Esc`
            Self.type("v1+2", harness, token, client)
            #expect(controller.isVisible && controller.isShowingVMode)
            #expect(harness.coordinator.handleKey(.key(VirtualKeyCode.escape, "\u{1b}"), token: token, client: client))
            #expect(client.calls.last == .clear)
            #expect(!controller.isVisible && !controller.isShowingVMode && harness.coordinator.vModeState == .idle)

            // Subsequent ordinary Chinese input works normally and shows the candidate panel.
            Self.type("nihao ", harness, token, client)
            #expect(client.inserts == ["你好"] && !controller.isVisible && !controller.isShowingVMode)
        }

        // MARK: - Secure input and the agent

        /// Secure input mid v-mode: the next key passes through, the `v` is cleared, the
        /// panel hides, and not one IPC frame leaves the IME, even for `v2`.
        @Test func secureInputEndsVModeWithZeroIPC() throws {
            let secure = SecureFlag()
            let controller = Self.panel()
            let harness = try Self.harness(controller, secure: secure)
            defer { harness.shutdown(); controller.hideAll() }
            let server = InMemoryServerTransport()
            let agent = AgentServiceCoordinator(transport: server, agentVersion: "1.0.0-test")
            agent.start()
            defer { agent.stop() }
            let clock = ManualIPCClock()
            let manager = IPCConnectionManager(
                transport: InMemoryClientTransport(server: server, clock: clock),
                client: .init(bundleID: NoemaPaths.imeBundleID, version: "0.0.0-test"),
                policy: .init(heartbeatInterval: nil), clock: clock, readyNotificationName: nil, isSecureInputEnabled: { secure.isOn })
            defer { manager.stop() }
            let reporter = CompositionIPCReporter(manager: manager, isSecureInputEnabled: { secure.isOn })
            harness.coordinator.onCompositionChange = { reporter.report($0) }
            harness.coordinator.onQuickAction = { reporter.requestQuickAction($0) }
            func settle() { for _ in 0..<12 { manager.sync {} } }
            manager.start()
            settle()
            try #require(manager.state == .healthy)

            let client = RecordingClient()
            client.caretRect = CGRect(x: 400, y: 600, width: 1, height: 18)
            let token = UUID()
            #expect(harness.coordinator.handleKey(.text("v"), token: token, client: client))
            #expect(controller.isShowingVMode)
            settle()
            let framesBefore = server.receivedFrames.count

            secure.isOn = true
            #expect(!harness.coordinator.handleKey(.text("2"), token: token, client: client), "the key passes through")
            #expect(client.calls.last == .clear && !controller.isVisible && harness.coordinator.vModeState == .idle)
            #expect(!harness.coordinator.handleKey(.text("v"), token: token, client: client))
            #expect(!harness.coordinator.handleKey(.text("9"), token: token, client: client))
            #expect(!harness.coordinator.selectVModeItem(at: 1, expectedGenerationID: harness.coordinator.vModeGenerationID))
            harness.coordinator.activate(token: token, client: client)
            reporter.requestQuickAction(.clipboard)
            settle()
            #expect(server.receivedFrames.count == framesBefore, "an IPC frame left the IME under secure input")
            #expect(reporter.suppressedForSecureInput == 1, "the direct request")
            #expect(agent.snapshot.quickActionCount == 0 && client.inserts.isEmpty)

            // Secure input ends: `v2` reaches the agent.
            secure.isOn = false
            Self.type("v2", harness, token, client)
            settle()
            #expect(agent.snapshot.lastQuickAction == .clipboard && agent.snapshot.quickActionCount == 1)
            #expect(client.inserts.isEmpty && client.calls.last == .clear && !controller.isVisible)
        }

        /// The real anonymous libxpc agent receives `v2` and `v9`; with the agent dead, `v4`
        /// still returns at once and the shell stays usable.
        @Test func quickActionsReachTheRealAgentAndNeverBlock() throws {
            let harness = try Harness(now: { VModeAndEmojiTests.fixedNow }, timeZone: VModeAndEmojiTests.beijing)
            defer { harness.shutdown() }
            let link = try AgentLink(readyNotificationName: "dev.noema.tests.ready.\(UUID().uuidString)")
            defer { link.shutdown() }
            let reporter = CompositionIPCReporter(manager: link.manager, isSecureInputEnabled: { false })
            harness.coordinator.onCompositionChange = { reporter.report($0) }
            harness.coordinator.onQuickAction = { reporter.requestQuickAction($0) }
            link.manager.start()
            #expect(poll { link.manager.state == .healthy }, "state: \(link.manager.state)")

            let client = RecordingClient()
            let token = UUID()
            Self.type("v2", harness, token, client)
            #expect(poll { link.agent.snapshot.lastQuickAction == .clipboard })
            Self.type("v9", harness, token, client)
            #expect(poll { link.agent.snapshot.lastQuickAction == .settings && link.agent.snapshot.quickActionCount == 2 })
            #expect(client.inserts.isEmpty)

            link.killAgent()
            let clock = ContinuousClock()
            let start = clock.now
            #expect(harness.coordinator.handleKey(.text("v"), token: token, client: client))
            #expect(harness.coordinator.handleKey(.text("4"), token: token, client: client))
            #expect(clock.now - start < .milliseconds(50), "a dead agent never blocks the key path")
            Self.type("nihao ", harness, token, client)
            #expect(client.inserts == ["你好"])
        }
    }
}

/// The librime option `EngineHost` drives from `AgentSettingsSnapshot.emojiCandidatesEnabled`.
enum EngineHostEmojiOption {
    static let name = "emoji_suggestion"
}
