import AppKit
import Foundation
import NoemaCore
import NoemaEngine
import NoemaIMEShell
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

    var calls: [Call] = []
    var clientBundleIdentifier: String? { "dev.noema.tests.client" }

    func insertText(_ text: String) { calls.append(.insert(text)) }

    func setMarkedText(preedit: String, caretUTF16Offset: Int, selectionUTF16Range: Range<Int>) {
        calls.append(.mark(preedit, caret: caretUTF16Offset, selection: selectionUTF16Range))
    }

    func clearMarkedText() { calls.append(.clear) }
}

@MainActor
final class RecordingPresenter: CandidatePresenting {
    var lastState: CompositionState?
    var hideCount = 0

    func update(state: CompositionState, client: any TextInputClient) { lastState = state }
    func hide() {
        hideCount += 1
        lastState = nil
    }
}

/// A deployed engine on a throwaway workspace and a coordinator over it.
@MainActor
final class Harness {
    let workspace: EngineWorkspace
    let engine: RimeEngine
    let presenter = RecordingPresenter()
    let coordinator: InputSessionCoordinator
    private var isUp = true

    init(withoutPunctuator: Bool = false, isSecureInputEnabled: @escaping @MainActor () -> Bool = { false }) throws {
        if withoutPunctuator {
            workspace = try EngineWorkspace(sharedFiles: EngineWorkspace.shippedFiles)
            try workspace.replaceInSharedFile("noema_pinyin.schema.yaml", "    - punctuator\n", with: "")
        } else {
            workspace = try EngineWorkspace()
        }
        let engine = try workspace.engine()
        try #require(!engine.isSafeMode)
        self.engine = engine
        coordinator = InputSessionCoordinator(
            engineProvider: { [engine] in engine }, candidatePresenter: presenter, isSecureInputEnabled: isSecureInputEnabled)
    }

    func shutdown() {
        guard isUp else { return }
        isUp = false
        engine.shutdown()
    }
}
