import AppKit
import Foundation
import NoemaCore
import NoemaEngine
import NoemaIMEShell
@testable import NoemaUI
import Testing

/// `InputSessionCoordinator` driving the real `RimeEngine` on the shipped schema: what
/// the IMKit controller does for each call, minus IMKit itself. Only the text client
/// and the candidate panel are recorded stand-ins (the external boundary); the engine,
/// key mapping, deployment, and librime are real.
extension LibrimeSerializedTests {
    @MainActor
    @Suite struct InputSessionCoordinatorTests {
        // MARK: Typing

        @Test func fullPinyinCommitsOnSpace() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            harness.coordinator.activate(token: token, client: client)
            for key in "nihao" {
                #expect(harness.coordinator.handleKey(.text(key), token: token, client: client))
            }
            #expect(client.calls.count == 5)
            #expect(client.calls.last == .mark("ni hao", caret: 6, selection: 0..<6))
            #expect(harness.coordinator.hasMarkedText)
            #expect(harness.presenter.lastState?.candidates.first?.text == "你好")

            client.calls.removeAll()
            let hides = harness.presenter.hideCount
            #expect(harness.coordinator.handleKey(.key(VirtualKeyCode.space, " "), token: token, client: client))
            #expect(client.calls == [.insert("你好")], "insertText replaces the marked text; nothing else follows")
            #expect(!harness.coordinator.hasMarkedText && harness.presenter.hideCount == hides + 1)
            // Idle keys that belong to the client reach it.
            #expect(!harness.coordinator.handleKey(.key(VirtualKeyCode.space, " "), token: token, client: client))
            #expect(!harness.coordinator.handleKey(.key(VirtualKeyCode.return, "\r"), token: token, client: client))
            #expect(client.calls == [.insert("你好")])
        }

        /// A partial selection puts Han text before the caret: the client receives UTF-16
        /// offsets (你 is one unit, three UTF-8 bytes).
        @Test func partialSelectionMarksHanPrefixWithUTF16Caret() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "nihao" { #expect(harness.coordinator.handleKey(.text(key), token: token, client: client)) }
            for code in [VirtualKeyCode.leftArrow, VirtualKeyCode.leftArrow, VirtualKeyCode.rightArrow] {
                #expect(harness.coordinator.handleKey(.key(code, "", .function), token: token, client: client))
            }
            client.calls.removeAll()
            #expect(harness.coordinator.handleKey(.text("1"), token: token, client: client))
            #expect(client.calls == [.mark("你hao", caret: 4, selection: 1..<4)])
            #expect(harness.coordinator.hasMarkedText)
        }

        @Test func escapeAndBackspaceCancelTheMarkedText() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "nihao" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            client.calls.removeAll()
            #expect(harness.coordinator.handleKey(.key(VirtualKeyCode.escape, "\u{1B}"), token: token, client: client))
            #expect(client.calls == [.clear] && !harness.coordinator.hasMarkedText)
            #expect(!harness.engine.currentState.isComposing)
            #expect(!harness.coordinator.handleKey(.key(VirtualKeyCode.escape, "\u{1B}"), token: token, client: client),
                    "idle Escape belongs to the client")

            _ = harness.coordinator.handleKey(.text("n"), token: token, client: client)
            client.calls.removeAll()
            #expect(harness.coordinator.handleKey(.key(VirtualKeyCode.delete, "\u{7F}"), token: token, client: client))
            #expect(client.calls == [.clear] && !harness.coordinator.hasMarkedText)
            #expect(!harness.coordinator.handleKey(.key(VirtualKeyCode.delete, "\u{7F}"), token: token, client: client),
                    "idle Backspace belongs to the client")
            #expect(client.calls == [.clear])
        }

        /// Without a punctuator, `,` after `nihao` commits 你好 and is still the client's
        /// key: the coordinator inserts the text and returns false, so the client types `,`.
        @Test func directCommitInsertsAndPassesTheKeyThrough() throws {
            let harness = try Harness(withoutPunctuator: true)
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "nihao" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            client.calls.removeAll()
            let handled = harness.coordinator.handleKey(.text(","), token: token, client: client)
            #expect(!handled, "the comma must reach the client")
            #expect(client.calls == [.insert("你好")])
            #expect(!harness.coordinator.hasMarkedText && !harness.engine.currentState.isComposing)
        }

        @Test func chinesePunctuationCommitsWhileIdle() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            #expect(harness.coordinator.handleKey(.text(","), token: token, client: client))
            #expect(client.calls == [.insert("，")])
        }

        // MARK: Secure input

        /// Secure input passes every key through before the engine sees it, clears only the
        /// marked text the shell put on the previous client, and never marks the secure one.
        @Test func secureInputPassesThroughWithoutTouchingTheSecureClient() throws {
            var secure = false
            let harness = try Harness(isSecureInputEnabled: { secure })
            defer { harness.shutdown() }
            let previous = RecordingClient()
            let previousToken = UUID()
            harness.coordinator.activate(token: previousToken, client: previous)
            for key in "ni" { #expect(harness.coordinator.handleKey(.text(key), token: previousToken, client: previous)) }
            #expect(harness.coordinator.hasMarkedText)

            secure = true
            let password = RecordingClient()
            let passwordToken = UUID()
            harness.coordinator.activate(token: passwordToken, client: password)
            previous.calls.removeAll()
            let hides = harness.presenter.hideCount
            for key in "hunter2" {
                #expect(!harness.coordinator.handleKey(.text(key), token: passwordToken, client: password))
            }
            #expect(password.calls.isEmpty, "no marked text on a secure field")
            #expect(!harness.engine.currentState.isComposing)
            #expect(harness.presenter.hideCount >= hides + 7)

            // The engine never sees a secure key: its state does not even change generation.
            let generation = harness.engine.currentState.generationID
            #expect(!harness.coordinator.handleKey(.key(VirtualKeyCode.return, "\r"), token: passwordToken, client: password))
            #expect(harness.engine.currentState.generationID == generation)

            // A composition still open when secure input turns on is dropped from its client.
            secure = false
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: passwordToken, client: password) }
            password.calls.removeAll()
            secure = true
            #expect(!harness.coordinator.handleKey(.text("x"), token: passwordToken, client: password))
            #expect(password.calls == [.clear] && !harness.engine.currentState.isComposing)
        }

        /// A key from a never-activated controller under secure input: the previous owner's
        /// marked text is cleared, and the secure client receives no call at all.
        @Test func secureKeyFromAnotherControllerNeverTouchesItsClient() throws {
            var secure = false
            let harness = try Harness(isSecureInputEnabled: { secure })
            defer { harness.shutdown() }
            let a = RecordingClient(), b = RecordingClient()
            let tokenA = UUID(), tokenB = UUID()
            for key in "nihao" { _ = harness.coordinator.handleKey(.text(key), token: tokenA, client: a) }
            a.calls.removeAll()
            secure = true
            #expect(!harness.coordinator.handleKey(.text("x"), token: tokenB, client: b))
            #expect(b.calls.isEmpty, "no insert, mark, or clear on the secure client")
            #expect(a.calls == [.clear])
            #expect(!harness.engine.currentState.isComposing && !harness.coordinator.hasMarkedText)
        }

        /// `commitComposition` and the ASCII mode switch under secure input drop the
        /// composition instead of inserting it.
        @Test func secureCommitCompositionInsertsNothing() throws {
            var secure = false
            let harness = try Harness(isSecureInputEnabled: { secure })
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "nihao" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            client.calls.removeAll()
            secure = true
            harness.coordinator.commitComposition(token: token, client: client)
            #expect(client.calls == [.clear], "never insertText on a secure client")
            #expect(!harness.engine.currentState.isComposing && !harness.coordinator.hasMarkedText)

            secure = false
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            client.calls.removeAll()
            secure = true
            harness.coordinator.setInputMode(InputSessionCoordinator.asciiInputModeID, token: token, client: client)
            #expect(client.calls == [.clear] && harness.engine.currentState.isASCIIMode)
            #expect(!harness.engine.currentState.isComposing)
        }

        // MARK: ASCII mode, Caps Lock

        @Test func asciiModePassesThroughWithoutCallingTheEngine() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            harness.engine.setASCIIMode(true)
            let generation = harness.engine.currentState.generationID
            for key in "abc," { #expect(!harness.coordinator.handleKey(.text(key), token: token, client: client)) }
            #expect(client.calls.isEmpty && harness.engine.currentState.generationID == generation)

            harness.engine.setASCIIMode(false)
            #expect(harness.coordinator.handleKey(.text("a"), token: token, client: client))
            #expect(client.calls == [.mark("a", caret: 1, selection: 0..<1)])
        }

        /// With Caps Lock on, librime's ascii_composer leaves letters to the client: an idle
        /// Caps Lock letter reaches it untouched, and mid-composition the letter still
        /// reaches the client while the composition stays open (librime declines it).
        @Test func capsLockLetterIsNeverSwallowed() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            let caps = KeyEvent(keyCode: 0x2D, characters: "N", modifiers: .capsLock, charactersIgnoringModifiers: "n")
            #expect(!harness.coordinator.handleKey(caps, token: token, client: client))
            #expect(client.calls.isEmpty && !harness.engine.currentState.isComposing)

            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            client.calls.removeAll()
            #expect(!harness.coordinator.handleKey(caps, token: token, client: client), "never swallowed")
            #expect(client.calls == [.mark("ni", caret: 2, selection: 0..<2)])
            #expect(harness.engine.currentState.preedit == "ni")
        }

        // MARK: Degradation

        @Test func safeModeAndMissingEnginePassEverythingThrough() throws {
            let workspace = try EngineWorkspace()
            try workspace.writeSentinel(#"{"consecutiveFailures":2,"lastAttemptEpoch":1}"#)
            let engine = try workspace.engine()
            defer { engine.shutdown() }
            #expect(engine.safeModeReason == .bootCrashLoop)
            let presenter = RecordingPresenter()
            let coordinator = InputSessionCoordinator(
                engineProvider: { engine }, candidatePresenter: presenter, isSecureInputEnabled: { false })
            let client = RecordingClient()
            let token = UUID()
            for event in [KeyEvent.text("n"), .text(","), .key(VirtualKeyCode.space, " "), .key(VirtualKeyCode.return, "\r")] {
                #expect(!coordinator.handleKey(event, token: token, client: client))
            }
            coordinator.commitComposition(token: token, client: client)
            #expect(client.calls.isEmpty)

            let noEngine = InputSessionCoordinator(
                engineProvider: { nil }, candidatePresenter: presenter, isSecureInputEnabled: { false })
            for key in "nihao" { #expect(!noEngine.handleKey(.text(key), token: token, client: client)) }
            noEngine.commitComposition(token: token, client: client)
            #expect(client.calls.isEmpty)
        }

        /// The engine disappearing mid-composition (shutdown) clears the marked text and
        /// passes the key through.
        @Test func engineShutdownMidCompositionClearsMarkedText() throws {
            let harness = try Harness()
            let client = RecordingClient()
            let token = UUID()
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            harness.shutdown()
            client.calls.removeAll()
            #expect(!harness.coordinator.handleKey(.text("h"), token: token, client: client))
            #expect(client.calls == [.clear] && !harness.coordinator.hasMarkedText)
        }

        // MARK: Multiple controllers

        /// IMKit may deliver `activate(B)` before the late `deactivate(A)`: A's deactivate
        /// must not clear B's composition or marked text.
        @Test func outOfOrderActivateAndDeactivateKeepTheNewOwner() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let a = RecordingClient(), b = RecordingClient()
            let tokenA = UUID(), tokenB = UUID()
            harness.coordinator.activate(token: tokenA, client: a)
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: tokenA, client: a) }
            a.calls.removeAll()

            harness.coordinator.activate(token: tokenB, client: b)
            #expect(a.calls == [.clear], "the previous owner's marked text is cleared")
            #expect(!harness.engine.currentState.isComposing)
            for key in "hao" { #expect(harness.coordinator.handleKey(.text(key), token: tokenB, client: b)) }
            let bCalls = b.calls

            harness.coordinator.deactivate(token: tokenA)
            harness.coordinator.controllerWillClose(token: tokenA)
            harness.coordinator.commitComposition(token: tokenA, client: a)
            #expect(a.calls == [.clear] && b.calls == bCalls)
            #expect(harness.coordinator.activeToken == tokenB && harness.coordinator.hasMarkedText)
            #expect(harness.engine.currentState.preedit == "hao")

            harness.coordinator.deactivate(token: tokenB)
            #expect(b.calls.last == .clear && harness.coordinator.activeToken == nil)
            #expect(!harness.engine.currentState.isComposing)
        }

        /// A key from a controller that was never activated takes ownership the same way.
        @Test func keyFromAnotherControllerTakesOwnership() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let a = RecordingClient(), b = RecordingClient()
            let tokenA = UUID(), tokenB = UUID()
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: tokenA, client: a) }
            a.calls.removeAll()
            #expect(harness.coordinator.handleKey(.text("h"), token: tokenB, client: b))
            #expect(a.calls == [.clear] && b.calls == [.mark("h", caret: 1, selection: 0..<1)])
        }

        /// Deactivation drops the composition with `clearComposition()`, never
        /// `resetSession()`, so ASCII mode survives a focus change.
        @Test func deactivatePreservesASCIIMode() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            harness.coordinator.activate(token: token, client: client)
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            harness.engine.setASCIIMode(true)
            harness.coordinator.deactivate(token: token)
            #expect(harness.engine.currentState.isASCIIMode, "ascii_mode survives deactivate")
            #expect(!harness.engine.currentState.isComposing)

            harness.coordinator.activate(token: token, client: client)
            harness.coordinator.setInputMode(NoemaPaths.zhHansInputModeID, token: token, client: client)
            #expect(harness.engine.currentState.isASCIIMode, "selecting the zh-Hans mode keeps ascii_mode")
            harness.coordinator.controllerWillClose(token: token)
            #expect(harness.engine.currentState.isASCIIMode)
        }

        @Test func asciiInputModeCommitsAndSwitches() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "nihao" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            client.calls.removeAll()
            harness.coordinator.setInputMode(InputSessionCoordinator.asciiInputModeID, token: token, client: client)
            #expect(client.calls == [.insert("你好")] && harness.engine.currentState.isASCIIMode)
        }

        // MARK: IMKit lifecycle calls

        @Test func commitCompositionInsertsThePreview() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            harness.coordinator.commitComposition(token: token, client: client)
            #expect(client.calls.isEmpty, "nothing to commit")
            for key in "nihao" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            client.calls.removeAll()
            harness.coordinator.commitComposition(token: UUID(), client: client)
            #expect(client.calls.isEmpty && harness.engine.currentState.isComposing, "another token cannot commit")
            harness.coordinator.commitComposition(token: token, client: client)
            #expect(client.calls == [.insert("你好")])
            #expect(!harness.coordinator.hasMarkedText && !harness.engine.currentState.isComposing)
            harness.coordinator.commitComposition(token: token, client: client)
            #expect(client.calls == [.insert("你好")])
        }

        /// Marked text with nothing left to commit (the engine's composition went away
        /// underneath it) is still cleared: no insertText replaced it.
        @Test func commitCompositionWithoutCommitClearsMarkedText() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            harness.engine.clearComposition()
            client.calls.removeAll()
            #expect(harness.coordinator.hasMarkedText)
            harness.coordinator.commitComposition(token: token, client: client)
            #expect(client.calls == [.clear] && !harness.coordinator.hasMarkedText)
        }

        @Test func hidePalettesKeepsTheComposition() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            let calls = client.calls
            let hides = harness.presenter.hideCount
            harness.coordinator.hidePalettes(token: UUID())
            #expect(harness.presenter.hideCount == hides, "another controller cannot hide the owner's panel")
            harness.coordinator.hidePalettes(token: token)
            #expect(harness.presenter.hideCount == hides + 1)
            #expect(client.calls == calls && harness.engine.currentState.isComposing && harness.coordinator.hasMarkedText)
        }

        /// The AppKit entry point: real key-down `NSEvent`s reach the engine; other event
        /// types return false without touching anything.
        @Test func handleNSEventBridgesRealAppKitEvents() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for (character, code) in [("n", UInt16(0x2D)), ("i", UInt16(0x22))] {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
                #expect(harness.coordinator.handleNSEvent(event, token: token, client: client))
            }
            #expect(client.calls.last == .mark("ni", caret: 2, selection: 0..<2))
            let command = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 0x08))
            #expect(!harness.coordinator.handleNSEvent(command, token: token, client: client), "⌘C belongs to the client")
            let mouse = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let count = client.calls.count
            #expect(!harness.coordinator.handleNSEvent(mouse, token: token, client: client))
            #expect(client.calls.count == count && harness.engine.currentState.preedit == "ni")
        }

        // MARK: Inline preedit disabled (panel draws the preedit)

        /// A client in `inlinePreeditDisabledBundleIDs` never receives marked text: the
        /// panel gets every state with `rendersPreeditInPanel`, and commits still insert.
        @Test func inlinePreeditDisabledClientGetsNoMarkedText() throws {
            let harness = try Harness(inlinePreeditDisabledBundleIDs: [RecordingClient.bundleID])
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "nihao" { #expect(harness.coordinator.handleKey(.text(key), token: token, client: client)) }
            #expect(client.calls.isEmpty && !harness.coordinator.hasMarkedText)
            #expect(harness.presenter.lastState?.preedit == "ni hao")
            #expect(harness.presenter.lastOptions == CandidatePresentationOptions(rendersPreeditInPanel: true, sessionToken: token))
            #expect(harness.coordinator.handleKey(.key(VirtualKeyCode.space, " "), token: token, client: client))
            #expect(client.calls == [.insert("你好")] && harness.presenter.lastState == nil)

            // Escape cancels without a clear: the client never had marked text.
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            #expect(harness.coordinator.handleKey(.key(VirtualKeyCode.escape, "\u{1B}"), token: token, client: client))
            #expect(client.calls == [.insert("你好")] && !harness.engine.currentState.isComposing)

            // Other clients keep inline marked text.
            let other = RecordingClient(bundleIdentifier: "dev.noema.tests.inline")
            #expect(harness.coordinator.handleKey(.text("n"), token: UUID(), client: other))
            #expect(other.calls == [.mark("n", caret: 1, selection: 0..<1)])
            #expect(harness.presenter.lastOptions?.rendersPreeditInPanel == false)
        }

        /// Secure input turning on for the *same* session drops a composition that has no
        /// marked text (panel-only preedit): nothing may survive into the secure field.
        @Test func secureInputDropsPanelOnlyCompositionOfTheSameSession() throws {
            var secure = false
            let harness = try Harness(
                isSecureInputEnabled: { secure }, inlinePreeditDisabledBundleIDs: [RecordingClient.bundleID])
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            harness.coordinator.activate(token: token, client: client)
            for key in "ni" { #expect(harness.coordinator.handleKey(.text(key), token: token, client: client)) }
            #expect(harness.engine.currentState.isComposing && !harness.coordinator.hasMarkedText)

            secure = true
            #expect(!harness.coordinator.handleKey(.text("x"), token: token, client: client))
            #expect(!harness.engine.currentState.isComposing, "the stale composition is dropped")
            #expect(client.calls.isEmpty && harness.presenter.lastState == nil)

            secure = false
            #expect(harness.coordinator.handleKey(.text("h"), token: token, client: client))
            #expect(harness.presenter.lastState?.preedit == "h", "no stale ni prefix")
        }

        // MARK: Panel clicks

        @Test func clickingACandidateCommitsIt() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "nihao" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            let shown = try #require(harness.presenter.lastState)
            client.calls.removeAll()
            let hides = harness.presenter.hideCount
            #expect(harness.coordinator.selectCandidate(at: 0, expectedGenerationID: shown.generationID))
            #expect(client.calls == [.insert(shown.candidates[0].text)])
            #expect(!harness.engine.currentState.isComposing && !harness.coordinator.hasMarkedText)
            #expect(harness.presenter.hideCount == hides + 1)
            #expect(!harness.coordinator.selectCandidate(at: 0), "nothing left to select")
        }

        /// Clicking the first candidate of a partial segment keeps composing the rest:
        /// marked text and the panel both refresh, exactly as the number key would.
        @Test func clickingAPartialCandidateRefreshesMarkedTextAndPanel() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in "nihao" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            for code in [VirtualKeyCode.leftArrow, VirtualKeyCode.leftArrow, VirtualKeyCode.rightArrow] {
                _ = harness.coordinator.handleKey(.key(code, "", .function), token: token, client: client)
            }
            let shown = try #require(harness.presenter.lastState)
            client.calls.removeAll()
            #expect(harness.coordinator.selectCandidate(at: 0, expectedGenerationID: shown.generationID))
            #expect(client.calls == [.mark("你hao", caret: 4, selection: 1..<4)])
            #expect(harness.coordinator.hasMarkedText)
            let refreshed = try #require(harness.presenter.lastState)
            #expect(refreshed.preedit == "你hao" && refreshed.generationID > shown.generationID)
            #expect(refreshed.candidates.first?.text == "好")
        }

        /// A click on a panel the engine has moved past, under secure input, or with an
        /// index off the page changes nothing.
        @Test func staleSecureAndOffPageClicksAreIgnored() throws {
            var secure = false
            let harness = try Harness(isSecureInputEnabled: { secure })
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            #expect(!harness.coordinator.selectCandidate(at: 0), "no owner yet")
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            let stale = try #require(harness.presenter.lastState).generationID
            _ = harness.coordinator.handleKey(.text("h"), token: token, client: client)
            let preedit = harness.engine.currentState.preedit
            client.calls.removeAll()
            #expect(!harness.coordinator.selectCandidate(at: 0, expectedGenerationID: stale))
            #expect(!harness.coordinator.changePage(backward: false, expectedGenerationID: stale))
            #expect(client.calls.isEmpty && harness.engine.currentState.preedit == preedit)

            let current = harness.engine.currentState.generationID
            #expect(!harness.coordinator.selectCandidate(at: 99, expectedGenerationID: current))
            #expect(client.calls.isEmpty && harness.engine.currentState.isComposing)

            secure = true
            #expect(!harness.coordinator.selectCandidate(at: 0, expectedGenerationID: current))
            #expect(!harness.coordinator.changePage(backward: false, expectedGenerationID: current))
            #expect(client.calls.isEmpty && harness.engine.currentState.preedit == preedit)
            #expect(harness.engine.currentState.generationID == current, "the engine never saw the click")
        }

        /// The real `CandidatePanelView` wired to the coordinator the way the panel
        /// controller wires it: a press on generation A, a refresh to generation B, then a
        /// release on the same point commits nothing (Codex review of PR #19).
        @Test func clickPressedOnAStalePanelNeverCommitsTheRefreshedCandidate() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            let panel = PanelUnderTest(coordinator: harness.coordinator)

            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            let layoutA = panel.show(try #require(harness.presenter.lastState))
            #expect(layoutA.items.first?.displayText == "你")
            let point = try #require(layoutA.items.first).pillFrame.center
            client.calls.removeAll()
            panel.view.mouseDown(with: try panel.mouse(.leftMouseDown, at: point))

            for key in "hao" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            let layoutB = panel.show(try #require(harness.presenter.lastState))
            #expect(layoutB.generationID != layoutA.generationID && layoutB.items.first?.displayText == "你好")
            #expect(layoutB.hitTest(point) == .candidate(0), "the release lands on candidate 0 of B")
            client.calls.removeAll()
            panel.view.mouseUp(with: try panel.mouse(.leftMouseUp, at: point))
            #expect(client.inserts.isEmpty, "a stale press commits nothing: \(client.calls)")
            #expect(harness.engine.currentState.preedit == "ni hao")

            // Without an intervening refresh the same click commits candidate 0.
            _ = harness.coordinator.handleKey(.key(VirtualKeyCode.escape, "\u{1B}"), token: token, client: client)
            for key in "ni" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            let layoutC = panel.show(try #require(harness.presenter.lastState))
            #expect(layoutC.items.first?.displayText == "你")
            client.calls.removeAll()
            panel.view.mouseDown(with: try panel.mouse(.leftMouseDown, at: point))
            panel.view.mouseUp(with: try panel.mouse(.leftMouseUp, at: point))
            #expect(client.inserts == ["你"])
            #expect(!harness.engine.currentState.isComposing)
        }

        /// Real Rime with inline preedit disabled: a 150-letter preedit overflows the panel,
        /// and the floating strip scrolls so the caret stays inside its clip rect.
        @Test func longPanelOnlyPreeditKeepsTheCaretInsideThePanel() throws {
            let harness = try Harness(inlinePreeditDisabledBundleIDs: [RecordingClient.bundleID])
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            for key in String(repeating: "nihao", count: 30) {
                _ = harness.coordinator.handleKey(.text(key), token: token, client: client)
            }
            let state = try #require(harness.presenter.lastState)
            let options = try #require(harness.presenter.lastOptions)
            #expect(options.rendersPreeditInPanel && client.calls.isEmpty)
            let style = CandidatePanelStyle()
            let layout = CandidateLayoutEngine(style: style).layout(state: state, options: options, expanded: false)
            let strip = try #require(layout.preeditStrip)
            #expect(strip.scrollOffset > 0, "the preedit overflows: \(state.preedit.utf16.count) UTF-16 units")
            #expect(strip.caretRect.minX >= strip.clipRect.minX && strip.caretRect.maxX <= strip.clipRect.maxX)
            #expect(strip.clipRect.maxX <= layout.panelSize.width && layout.panelSize.width <= style.maxPanelWidth)
        }

        /// The shipped `CandidatePanelController` on the real `NSPanel` (kept off screen),
        /// driven by real Rime through the coordinator: expanding and collapsing `shi` by
        /// clicking the chevron resizes the panel, the view, and every subview to the
        /// layout's size in both backdrop modes (Codex review of PR #19: autoresizing
        /// applied the size delta twice, leaving `(0, 276)` and `(352, 0)` subviews).
        @Test(arguments: [CandidatePanelStyle.BackdropMode.glass, .visualEffect])
        func expandAndCollapseResizeEverySubviewToThePanel(mode: CandidatePanelStyle.BackdropMode) throws {
            var style = CandidatePanelStyle()
            style.backdropMode = mode
            let controller = CandidatePanelController(style: style)
            controller.screensProvider = {
                [ScreenFrame(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))]
            }
            controller.shouldOrderFront = false
            let harness = try Harness(candidatePresenter: controller)
            defer { harness.shutdown(); controller.hide() }
            let client = RecordingClient()
            client.caretRect = CGRect(x: 400, y: 500, width: 1, height: 18)
            let token = UUID()
            for key in "shi" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }

            let view = controller.panelViewForTesting
            let panel = controller.panelForTesting
            func expectSized(_ layout: CandidatePanelLayout, _ step: String) {
                let size = layout.panelSize
                #expect(size.width > 0 && size.height > 0, "\(step)")
                #expect(panel.frame.size == size, "\(step): panel \(panel.frame.size) vs \(size)")
                #expect(view.bounds.size == size, "\(step): view \(view.bounds.size) vs \(size)")
                #expect(view.subviews.count == 2, "\(step): highlight host and CoreText view")
                for frame in view.subviews.map(\.frame) + view.subviewFramesForTesting {
                    #expect(frame == CGRect(origin: .zero, size: size), "\(step): subview \(frame) vs \(size)")
                }
            }
            func click(_ rect: CGRect?) throws {
                let point = view.convert(try #require(rect).center, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .leftMouseDown ? 1 : 0))
                    type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
                }
            }

            #expect(controller.isVisible && !controller.isExpanded)
            let collapsed = try #require(controller.currentLayout)
            #expect(!collapsed.isExpanded && !collapsed.items.isEmpty)
            expectSized(collapsed, "collapsed")

            try click(collapsed.expandButtonFrame)
            #expect(controller.isExpanded)
            let expanded = try #require(controller.currentLayout)
            #expect(expanded.isExpanded && expanded.panelSize != collapsed.panelSize)
            expectSized(expanded, "expanded")

            try click(expanded.expandButtonFrame)
            #expect(!controller.isExpanded)
            let recollapsed = try #require(controller.currentLayout)
            #expect(!recollapsed.isExpanded)
            expectSized(recollapsed, "collapsed again")

            // Switching the backdrop mid-session re-hosts the view at the same size.
            controller.backdropMode = mode == .glass ? .visualEffect : .glass
            expectSized(try #require(controller.currentLayout), "after backdrop switch")
            try click(controller.currentLayout?.expandButtonFrame)
            expectSized(try #require(controller.currentLayout), "expanded after backdrop switch")
            #expect(controller.isExpanded)
            #expect(client.inserts.isEmpty, "chevron clicks commit nothing")
        }

        /// Real Rime with `menu/page_size: 20` (Codex review of PR #19): typing `s` fills a
        /// 20-candidate page that cannot fit one capsule row even with every text cut to
        /// "…". The shipped controller lays it out expanded with no dead collapse button,
        /// every capsule inside the panel, and a real click on the last one commits it.
        @Test func twentyCandidatePageExpandsInsideThePanel() throws {
            let style = CandidatePanelStyle()
            let controller = CandidatePanelController(style: style)
            controller.screensProvider = {
                [ScreenFrame(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))]
            }
            controller.shouldOrderFront = false
            let recorder = RecordingPresenter()
            let harness = try Harness(pageSize: 20, candidatePresenter: TeePresenter([recorder, controller]))
            defer { harness.shutdown(); controller.hide() }
            // Wired as `EngineHost` wires the shipped panel.
            controller.onSelectCandidate = { [coordinator = harness.coordinator] index, generation in
                _ = coordinator.selectCandidate(at: index, expectedGenerationID: generation)
            }
            let client = RecordingClient()
            client.caretRect = CGRect(x: 400, y: 600, width: 1, height: 18)
            let token = UUID()
            #expect(harness.coordinator.handleKey(.text("s"), token: token, client: client))

            let state = try #require(recorder.lastState)
            #expect(state.candidates.count >= 15, "page_size 20 took effect: \(state.candidates.count)")
            let options = try #require(recorder.lastOptions)
            let direct = CandidateLayoutEngine(style: style).layout(state: state, options: options, expanded: false)
            let layout = try #require(controller.currentLayout)
            #expect(!controller.isExpanded, "nobody clicked the chevron")
            for candidate in [direct, layout] {
                #expect(candidate.isExpanded && candidate.expandButtonFrame == nil)
                #expect(candidate.contentWidth <= candidate.panelSize.width, "\(candidate.contentWidth) > \(candidate.panelSize.width)")
                #expect(candidate.panelSize.width <= style.maxPanelWidth)
                #expect(candidate.items.count == state.candidates.count)
                for item in candidate.items {
                    #expect(item.pillFrame.minX >= 0 && item.pillFrame.maxX <= candidate.panelSize.width, "\(item.index): \(item.pillFrame)")
                    #expect(item.pillFrame.minY >= 0 && item.pillFrame.maxY <= candidate.panelSize.height, "\(item.index): \(item.pillFrame)")
                    #expect(candidate.hitTest(item.pillFrame.center) == .candidate(item.index))
                }
            }
            #expect(direct.items.map(\.pillFrame) == layout.items.map(\.pillFrame))
            let view = controller.panelViewForTesting
            let panel = controller.panelForTesting
            #expect(panel.frame.size == layout.panelSize && view.bounds.size == layout.panelSize)

            // A real click on the last capsule commits the last candidate.
            let last = try #require(layout.items.last)
            let point = view.convert(last.pillFrame.center, to: nil)
            client.calls.removeAll()
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
                type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
            }
            #expect(client.inserts == [state.candidates[last.index].text])
            #expect(!harness.engine.currentState.isComposing && !controller.isVisible)
        }

        /// Real Rime with `menu/page_size: 50` and 60 more `shi` entries on a 1440×900 screen
        /// (Codex review of PR #19): the 50-row page is taller than the 875-point visible
        /// frame. The shipped controller keeps the panel inside the visible frame with the
        /// list scrolling in a viewport: candidate 0 starts visible and clickable, arrow keys
        /// keep the highlight in view, real scroll-wheel events reach candidate 49 without
        /// paging Rime, and a real click on it commits it. Only at the bottom does the wheel
        /// turn the page, which resets the scroll.
        @Test func fiftyCandidatePageScrollsInsideTheVisibleFrame() throws {
            let style = CandidatePanelStyle()
            let controller = CandidatePanelController(style: style)
            let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
            controller.screensProvider = {
                [ScreenFrame(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: visible)]
            }
            controller.shouldOrderFront = false
            let recorder = RecordingPresenter()
            let extra = (0..<60).map { i in
                "\(Character(UnicodeScalar(0x4E00 + 7 * i)!))\tshi\t\(60 - i)\n"
            }.joined()
            let harness = try Harness(
                pageSize: 50, dictionaryAppendix: extra, candidatePresenter: TeePresenter([recorder, controller]))
            defer { harness.shutdown(); controller.hide() }
            // Wired as `EngineHost` wires the shipped panel.
            controller.onSelectCandidate = { [coordinator = harness.coordinator] index, generation in
                _ = coordinator.selectCandidate(at: index, expectedGenerationID: generation)
            }
            controller.onChangePage = { [coordinator = harness.coordinator] backward, generation in
                _ = coordinator.changePage(backward: backward, expectedGenerationID: generation)
            }
            let client = RecordingClient()
            client.caretRect = CGRect(x: 400, y: 600, width: 1, height: 18)
            let token = UUID()
            for key in "shi" { #expect(harness.coordinator.handleKey(.text(key), token: token, client: client)) }

            let state = try #require(recorder.lastState)
            #expect(state.candidates.count == 50, "page_size 50 took effect: \(state.candidates.count)")
            #expect(state.pageIndex == 0 && state.highlightedIndex == 0)
            let view = controller.panelViewForTesting
            let panel = controller.panelForTesting

            /// `index` is whole inside the viewport, on screen, and a real click there hits it.
            func expectReachable(_ index: Int, _ step: String) throws {
                let layout = try #require(controller.currentLayout, "\(step)")
                #expect(panel.frame.size == layout.panelSize && view.bounds.size == layout.panelSize, "\(step)")
                #expect(panel.frame.height <= visible.height && visible.contains(panel.frame), "\(step): panel \(panel.frame)")
                let viewport = try #require(layout.candidatesViewport, "\(step): the list scrolls")
                let pill = layout.items[index].pillFrame
                #expect(viewport.contains(pill), "\(step): \(index) at \(pill) outside \(viewport)")
                let onScreen = panel.convertToScreen(view.convert(pill, to: nil))
                #expect(visible.contains(onScreen), "\(step): \(index) at \(onScreen) off screen")
                let event = try #require(NSEvent.mouseEvent(
                    with: .leftMouseDown, location: view.convert(pill.center, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                #expect(layout.hitTest(view.convert(event.locationInWindow, from: nil)) == .candidate(index), "\(step)")
            }
            func scroll(_ deltaY: Int32) throws {
                let cgEvent = try #require(CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0))
                view.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))
            }

            let top = try #require(controller.currentLayout)
            #expect(top.maxVerticalScrollOffset > 0 && top.verticalScrollOffset == 0)
            #expect(top.highlightedPillFrame == top.items[0].pillFrame)
            try expectReachable(0, "initial highlight")

            // Arrow keys on the same page scroll just enough to keep the highlight in view.
            for _ in 0..<30 {
                _ = harness.coordinator.handleKey(.key(VirtualKeyCode.downArrow, "", .function), token: token, client: client)
            }
            let arrowed = try #require(recorder.lastState)
            #expect(arrowed.candidates == state.candidates && arrowed.highlightedIndex == 30, "\(String(describing: arrowed.highlightedIndex))")
            let tracked = try #require(controller.currentLayout)
            #expect(tracked.verticalScrollOffset > 0 && tracked.highlightedPillFrame == tracked.items[30].pillFrame)
            try expectReachable(30, "highlight after 30 × Down")

            // The wheel scrolls within the page down to candidate 49; Rime never pages.
            let generation = harness.engine.currentState.generationID
            let updates = recorder.updateCount
            var steps = 0
            while let layout = controller.currentLayout, layout.verticalScrollOffset < layout.maxVerticalScrollOffset, steps < 100 {
                try scroll(-60)
                steps += 1
            }
            let bottom = try #require(controller.currentLayout)
            #expect(steps > 1 && bottom.verticalScrollOffset == bottom.maxVerticalScrollOffset)
            #expect(harness.engine.currentState.generationID == generation && recorder.updateCount == updates, "no Rime paging")
            #expect(harness.engine.currentState.pageIndex == 0)
            #expect(visible.contains(panel.frame))
            try expectReachable(49, "scrolled to the bottom")
            #expect(bottom.highlightedPillFrame == bottom.items[30].pillFrame, "scrolling never moves the highlight")

            // A real click on candidate 49 commits it.
            let last = view.convert(bottom.items[49].pillFrame.center, to: nil)
            client.calls.removeAll()
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: last, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
                type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
            }
            #expect(client.inserts == [state.candidates[49].text])
            #expect(!harness.engine.currentState.isComposing && !controller.isVisible)

            // Retyped: the list starts at the top again; at the bottom, the wheel pages Rime
            // and the next page starts scrolled to its top.
            for key in "shi" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            #expect(controller.currentLayout?.verticalScrollOffset == 0)
            try scroll(-100_000)
            let end = try #require(controller.currentLayout)
            #expect(end.verticalScrollOffset == end.maxVerticalScrollOffset && harness.engine.currentState.pageIndex == 0)
            try scroll(-60)
            #expect(harness.engine.currentState.pageIndex == 1, "past the bottom the wheel pages Rime")
            let next = try #require(recorder.lastState)
            #expect(next.pageIndex == 1 && next.candidates != state.candidates)
            #expect(controller.currentLayout?.verticalScrollOffset == 0)
            #expect(visible.contains(panel.frame))
        }

        /// Real Rime with the shipped `menu/page_size: 5` and five long `shi` entries (Codex
        /// review of PR #19). Part A: on a 640×960 portrait screen the shipped controller
        /// bounds the row to the screen's usable width (not the 720 pt style bound), so the
        /// panel and its chevron stay inside the visible frame, and a real click on the
        /// chevron expands it in place. Part B: the same composition grown to 704 pt on a
        /// 1440×900 screen and then moved to the 640 pt screen re-clamps its hysteresis width.
        @Test func longCandidatesStayInsideANarrowScreen() throws {
            let style = CandidatePanelStyle()
            let narrow = CGRect(x: 0, y: 0, width: 640, height: 960)
            let wide = CGRect(x: 0, y: 0, width: 1440, height: 900)
            let longEntries = (0..<5).map { "这是一个比较长的候选词组\($0)\tshi\t\(9_000 - $0)\n" }.joined()
            let controller = CandidatePanelController(style: style)
            controller.shouldOrderFront = false
            let recorder = RecordingPresenter()
            let harness = try Harness(dictionaryAppendix: longEntries, candidatePresenter: TeePresenter([recorder, controller]))
            defer { harness.shutdown(); controller.hide() }
            let client = RecordingClient()
            client.caretRect = CGRect(x: 300, y: 600, width: 1, height: 18)
            let token = UUID()
            let view = controller.panelViewForTesting
            let panel = controller.panelForTesting
            func onScreen(_ rect: CGRect) -> CGRect { panel.convertToScreen(view.convert(rect, to: nil)) }
            func expectInside(_ visible: CGRect, _ step: String) throws {
                let layout = try #require(controller.currentLayout, "\(step)")
                #expect(panel.frame.size == layout.panelSize && view.bounds.size == layout.panelSize, "\(step)")
                #expect(panel.frame.width <= visible.width && visible.contains(panel.frame), "\(step): panel \(panel.frame)")
                if let button = layout.expandButtonFrame {
                    #expect(visible.contains(onScreen(button)), "\(step): chevron at \(onScreen(button)) off screen")
                }
                for item in layout.items {
                    #expect(visible.contains(onScreen(item.pillFrame)), "\(step): \(item.index) at \(onScreen(item.pillFrame))")
                }
            }

            // Part A: typed on the narrow screen.
            controller.screensProvider = { [ScreenFrame(frame: narrow, visibleFrame: narrow)] }
            for key in "shi" { #expect(harness.coordinator.handleKey(.text(key), token: token, client: client)) }
            let state = try #require(recorder.lastState)
            #expect(state.candidates.count == 5 && state.candidates.allSatisfy { $0.text.hasPrefix("这是一个比较长的候选词组") },
                    "\(state.candidates.map(\.text))")
            let unbounded = CandidateLayoutEngine(style: style).layout(
                state: state, options: try #require(recorder.lastOptions), expanded: false)
            #expect(unbounded.panelSize.width > narrow.width, "the reproduction overflows 640 pt without the bound")
            try expectInside(narrow, "narrow collapsed")
            let collapsed = try #require(controller.currentLayout)
            let button = try #require(collapsed.expandButtonFrame, "five truncated capsules still fit one row")
            let point = view.convert(button.center, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
                type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
            }
            #expect(controller.isExpanded && controller.currentLayout?.isExpanded == true)
            try expectInside(narrow, "narrow expanded")
            #expect(client.inserts.isEmpty, "the chevron click commits nothing")

            // Part B: grown on the wide screen, then moved to the narrow one mid-composition.
            harness.coordinator.commitComposition(token: token, client: client)
            controller.hide()
            controller.screensProvider = { [ScreenFrame(frame: wide, visibleFrame: wide)] }
            for key in "shi" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            try expectInside(wide, "wide")
            #expect(panel.frame.width > narrow.width, "hysteresis grew past 640 pt on the wide screen: \(panel.frame.width)")
            controller.screensProvider = { [ScreenFrame(frame: narrow, visibleFrame: narrow)] }
            _ = harness.coordinator.handleKey(.key(VirtualKeyCode.downArrow, "", .function), token: token, client: client)
            #expect(recorder.lastState?.highlightedIndex == 1, "the same composition re-rendered")
            try expectInside(narrow, "moved to the narrow screen")
        }

        /// Real Rime, a client reporting no caret, and no cached caret on a 1440×900 screen
        /// (Codex review of PR #19): the panel falls back to the mouse once per composition.
        /// With the pointer then on the panel, real scroll-wheel events page Rime and a real
        /// click expands the page, and the panel never re-anchors under the pointer. A new
        /// composition after Escape samples the mouse again, and a valid caret mid-composition
        /// takes over at once.
        @Test func mouseFallbackAnchorStaysPutWhileThePointerIsOnThePanel() throws {
            let controller = CandidatePanelController(style: CandidatePanelStyle())
            controller.screensProvider = {
                [ScreenFrame(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))]
            }
            controller.shouldOrderFront = false
            var mouse = CGPoint(x: 400, y: 600)
            controller.mouseLocationProvider = { mouse }
            let recorder = RecordingPresenter()
            let harness = try Harness(candidatePresenter: TeePresenter([recorder, controller]))
            defer { harness.shutdown(); controller.hide() }
            // Wired as `EngineHost` wires the shipped panel.
            controller.onSelectCandidate = { [coordinator = harness.coordinator] index, generation in
                _ = coordinator.selectCandidate(at: index, expectedGenerationID: generation)
            }
            controller.onChangePage = { [coordinator = harness.coordinator] backward, generation in
                _ = coordinator.changePage(backward: backward, expectedGenerationID: generation)
            }
            let client = RecordingClient()
            client.caretRect = nil
            let token = UUID()
            let view = controller.panelViewForTesting
            let panel = controller.panelForTesting
            func press(_ character: String, _ code: UInt16) throws {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
                #expect(harness.coordinator.handleNSEvent(event, token: token, client: client))
            }
            func typeShi() throws {
                for (character, code) in [("s", UInt16(0x01)), ("h", UInt16(0x04)), ("i", UInt16(0x22))] {
                    try press(character, code)
                }
            }
            func scroll(_ deltaY: Int32) throws {
                let cgEvent = try #require(CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0))
                view.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))
            }
            /// The panel kept its left edge and top edge, and the pointer is still on it.
            func expectPinned(to before: CGRect, _ step: String) {
                let frame = panel.frame
                #expect(frame.origin.x == before.origin.x && frame.maxY == before.maxY,
                        "\(step): anchor shifted by (\(frame.origin.x - before.origin.x), \(frame.maxY - before.maxY)) to \(frame)")
                #expect(frame.contains(mouse), "\(step): pointer \(mouse) left the panel \(frame)")
            }

            try typeShi()
            let first = try #require(recorder.lastState)
            #expect(first.pageIndex == 0 && !first.isLastPage)
            let anchored = panel.frame
            #expect(anchored.origin.x == 400 && anchored.maxY == 600 - 18 - 6, "below the mouse: \(anchored)")
            #expect(anchored.origin.y == 540, "\(anchored)")

            // The pointer moves onto the panel; two real wheel events page Rime twice.
            mouse = CGPoint(x: anchored.midX, y: anchored.midY)
            try scroll(-60)
            let second = try #require(recorder.lastState)
            #expect(harness.engine.currentState.pageIndex == 1 && second.pageIndex == 1)
            #expect(second.candidates != first.candidates, "Rime paged")
            expectPinned(to: anchored, "page 1")
            try scroll(-60)
            let third = try #require(recorder.lastState)
            #expect(third.pageIndex == 2 && third.candidates != second.candidates, "Rime paged again")
            expectPinned(to: anchored, "page 2")

            // The pointer moves onto the chevron; a real click expands the page in place.
            let collapsed = try #require(controller.currentLayout)
            let button = try #require(collapsed.expandButtonFrame)
            let point = view.convert(button.center, to: nil)
            mouse = panel.convertPoint(toScreen: point)
            let beforeExpand = panel.frame
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
                type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
            }
            #expect(controller.isExpanded && controller.currentLayout?.isExpanded == true)
            #expect(panel.frame.height > beforeExpand.height, "expanded: \(panel.frame)")
            #expect(panel.frame.origin.x == beforeExpand.origin.x && panel.frame.maxY == beforeExpand.maxY,
                    "expand kept the anchor: \(beforeExpand) → \(panel.frame)")
            #expect(client.inserts.isEmpty, "paging and the chevron commit nothing")

            // Escape hides the panel; the next composition samples the mouse again.
            try press("\u{1B}", 0x35)
            #expect(!controller.isVisible && !harness.engine.currentState.isComposing)
            mouse = CGPoint(x: 800, y: 500)
            try typeShi()
            #expect(panel.frame.origin.x == 800 && panel.frame.maxY == 500 - 18 - 6, "new composition: \(panel.frame)")

            // A valid caret mid-composition replaces the mouse anchor at once.
            client.caretRect = CGRect(x: 150, y: 700, width: 1, height: 18)
            _ = harness.coordinator.handleKey(.key(VirtualKeyCode.downArrow, "", .function), token: token, client: client)
            #expect(recorder.lastState?.highlightedIndex == 1, "the same composition re-rendered")
            #expect(panel.frame.origin.x == 150 && panel.frame.maxY == 700 - 6, "real caret: \(panel.frame)")
        }

        @Test func pagingFromThePanelRefreshesCandidates() throws {
            let harness = try Harness()
            defer { harness.shutdown() }
            let client = RecordingClient()
            let token = UUID()
            #expect(!harness.coordinator.changePage(backward: false), "nothing to page")
            for key in "shi" { _ = harness.coordinator.handleKey(.text(key), token: token, client: client) }
            let first = try #require(harness.presenter.lastState)
            #expect(first.pageIndex == 0 && !first.isLastPage)
            client.calls.removeAll()
            #expect(harness.coordinator.changePage(backward: false, expectedGenerationID: first.generationID))
            let second = try #require(harness.presenter.lastState)
            #expect(second.pageIndex == 1 && second.candidates != first.candidates)
            #expect(client.calls == [.mark("shi", caret: 3, selection: 0..<3)])
            #expect(harness.coordinator.changePage(backward: true, expectedGenerationID: second.generationID))
            #expect(harness.presenter.lastState?.pageIndex == 0)
        }
    }
}

// MARK: - Recording boundary stand-ins

@MainActor
final class RecordingClient: TextInputClient {
    enum Call: Equatable {
        case insert(String)
        case mark(String, caret: Int, selection: Range<Int>)
        case clear
    }

    static let bundleID = "dev.noema.tests.client"

    var calls: [Call] = []
    let clientBundleIdentifier: String?
    /// What `caretScreenRect` reports; nil like a client that reports none.
    var caretRect: CGRect?

    init(bundleIdentifier: String? = RecordingClient.bundleID) {
        clientBundleIdentifier = bundleIdentifier
    }

    func insertText(_ text: String) { calls.append(.insert(text)) }

    func setMarkedText(preedit: String, caretUTF16Offset: Int, selectionUTF16Range: Range<Int>) {
        calls.append(.mark(preedit, caret: caretUTF16Offset, selection: selectionUTF16Range))
    }

    func clearMarkedText() { calls.append(.clear) }

    func caretScreenRect(atUTF16Offset offset: Int) -> CGRect? { caretRect }

    var inserts: [String] {
        calls.compactMap { if case .insert(let text) = $0 { text } else { nil } }
    }
}

/// The shipped `CandidatePanelView` in an offscreen window, its click callback wired to
/// the coordinator as `CandidatePanelController` wires it.
@MainActor
final class PanelUnderTest {
    let window: NSWindow
    let view = CandidatePanelView(style: CandidatePanelStyle())
    private let engine = CandidateLayoutEngine(style: CandidatePanelStyle())

    init(coordinator: InputSessionCoordinator) {
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 200), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = view
        view.onSelectCandidate = { index, generation in
            _ = coordinator.selectCandidate(at: index, expectedGenerationID: generation)
        }
    }

    /// Lays out `state` as the inline-preedit panel and applies it to the view.
    @discardableResult
    func show(_ state: CompositionState) -> CandidatePanelLayout {
        let layout = engine.layout(state: state, options: CandidatePresentationOptions(), expanded: false)
        view.frame = CGRect(origin: .zero, size: layout.panelSize)
        view.apply(layout)
        return layout
    }

    /// A real mouse event at `point` in the view's (flipped) coordinates.
    func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0))
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
final class RecordingPresenter: CandidatePresenting {
    var lastState: CompositionState?
    var lastOptions: CandidatePresentationOptions?
    var updateCount = 0
    var hideCount = 0

    func update(state: CompositionState, client: any TextInputClient, options: CandidatePresentationOptions) {
        lastState = state
        lastOptions = options
        updateCount += 1
    }
    func hide() {
        hideCount += 1
        lastState = nil
        lastOptions = nil
    }
}

/// Forwards every presenter call to each of `presenters`, in order.
@MainActor
final class TeePresenter: CandidatePresenting {
    let presenters: [any CandidatePresenting]
    init(_ presenters: [any CandidatePresenting]) { self.presenters = presenters }
    func update(state: CompositionState, client: any TextInputClient, options: CandidatePresentationOptions) {
        for presenter in presenters { presenter.update(state: state, client: client, options: options) }
    }
    func hide() { for presenter in presenters { presenter.hide() } }
}

/// A deployed engine on a throwaway workspace and a coordinator over it.
@MainActor
final class Harness {
    let workspace: EngineWorkspace
    let engine: RimeEngine
    let presenter = RecordingPresenter()
    let coordinator: InputSessionCoordinator
    private var isUp = true

    /// `pageSize` overrides the shipped `menu/page_size: 5` in a copied `default.yaml`;
    /// `dictionaryAppendix` adds entry lines to a copied `noema_pinyin.dict.yaml`.
    init(
        withoutPunctuator: Bool = false,
        pageSize: Int? = nil,
        dictionaryAppendix: String? = nil,
        isSecureInputEnabled: @escaping @MainActor () -> Bool = { false },
        inlinePreeditDisabledBundleIDs: Set<String> = [],
        candidatePresenter: (any CandidatePresenting)? = nil
    ) throws {
        if withoutPunctuator || pageSize != nil || dictionaryAppendix != nil {
            workspace = try EngineWorkspace(sharedFiles: EngineWorkspace.shippedFiles)
            if withoutPunctuator {
                try workspace.replaceInSharedFile("noema_pinyin.schema.yaml", "    - punctuator\n", with: "")
            }
            if let pageSize {
                try workspace.replaceInSharedFile("default.yaml", "page_size: 5", with: "page_size: \(pageSize)")
            }
            if let dictionaryAppendix {
                try workspace.appendToSharedFile("noema_pinyin.dict.yaml", dictionaryAppendix)
            }
        } else {
            workspace = try EngineWorkspace()
        }
        let engine = try workspace.engine()
        try #require(!engine.isSafeMode)
        self.engine = engine
        coordinator = InputSessionCoordinator(
            engineProvider: { [engine] in engine }, candidatePresenter: candidatePresenter ?? presenter, isSecureInputEnabled: isSecureInputEnabled,
            inlinePreeditDisabledBundleIDs: inlinePreeditDisabledBundleIDs)
    }

    func shutdown() {
        guard isUp else { return }
        isUp = false
        engine.shutdown()
    }
}
