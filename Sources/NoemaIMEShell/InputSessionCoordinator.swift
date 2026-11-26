import AppKit
import Carbon.HIToolbox
import NoemaCore

/// Routes the key and lifecycle calls of every input controller in the process to the one
/// process-wide `TypingEngine`, and applies each `KeyHandlingResult` to the client.
///
/// IMKit creates one controller per client session, but librime holds a single
/// composition, so exactly one session token owns it at a time (`activeToken`). Calls from
/// a token that does not own the composition never touch another client's marked text:
/// a late `deactivate(A)` after `activate(B)` is ignored.
///
/// Never swallows a key: secure input, a missing engine, Safe Mode, and every key the
/// engine declines return `false`, so the client receives the key. Committed text is
/// always inserted before the key is passed through. Clearing a composition calls
/// `clearComposition()`, never `resetSession()`, which would also reset `ascii_mode`.
///
/// Clients whose bundle identifier is in `inlinePreeditDisabledBundleIDs` never receive
/// marked text: the candidate panel draws the preedit instead. Clicks on the panel arrive
/// through `selectCandidate(at:expectedGenerationID:)` and
/// `changePage(backward:expectedGenerationID:)`, which ignore stale generations.
@MainActor
public final class InputSessionCoordinator {
    /// A mode ID that switches the engine to ASCII. `Info.plist.in` declares only
    /// `NoemaPaths.zhHansInputModeID` today; this is the seam for an ASCII mode.
    public static let asciiInputModeID = NoemaPaths.imeBundleID + ".ascii"

    private let engineProvider: @MainActor () -> (any TypingEngine)?
    private let candidatePresenter: any CandidatePresenting
    private let isSecureInputEnabled: @MainActor () -> Bool
    private let inlinePreeditDisabledBundleIDs: Set<String>

    /// The session that owns the engine's composition, and its client.
    public private(set) var activeToken: UUID?
    private var activeClient: (any TextInputClient)?
    /// True while `activeClient` shows marked text the shell put there.
    public private(set) var hasMarkedText = false

    public init(
        engineProvider: @escaping @MainActor () -> (any TypingEngine)?,
        candidatePresenter: any CandidatePresenting = NoOpCandidatePresenter(),
        isSecureInputEnabled: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
        inlinePreeditDisabledBundleIDs: Set<String> = []
    ) {
        self.engineProvider = engineProvider
        self.candidatePresenter = candidatePresenter
        self.isSecureInputEnabled = isSecureInputEnabled
        self.inlinePreeditDisabledBundleIDs = inlinePreeditDisabledBundleIDs
    }

    // MARK: - Lifecycle

    /// A controller's client gained focus (`activateServer:`).
    public func activate(token: UUID, client: any TextInputClient) {
        take(token: token, client: client)
        if isSecureInputEnabled() { candidatePresenter.hide() }
    }

    /// A controller's client lost focus (`deactivateServer:`). Ignored unless `token` owns
    /// the composition. Needs no client: the owner's client is the one that is cleared, so
    /// a detached client proxy cannot keep a stale owner alive.
    public func deactivate(token: UUID) {
        guard activeToken == token else { return }
        releaseActive()
    }

    /// The controller is going away (`inputControllerWillClose`). Ignored unless `token`
    /// owns the composition.
    public func controllerWillClose(token: UUID) {
        guard activeToken == token else { return }
        releaseActive()
    }

    /// IMKit asks the controller to commit (`commitComposition:`, e.g. a click outside the
    /// marked text). Inserts what the engine commits and leaves nothing marked. Under
    /// secure input nothing is inserted: the composition is dropped instead.
    public func commitComposition(token: UUID, client: any TextInputClient) {
        guard activeToken == token else { return }
        if isSecureInputEnabled() {
            dropComposition()
            return
        }
        guard let engine = engineProvider(), !engine.currentState.isSafeMode else {
            if hasMarkedText { client.clearMarkedText() }
            hasMarkedText = false
            candidatePresenter.hide()
            return
        }
        let result = engine.commitComposition()
        var didInsert = false
        if let committed = result.committedText, !committed.isEmpty {
            client.insertText(committed)
            didInsert = true
        }
        if result.state.isComposing { engine.clearComposition() }
        // insertText replaced the marked text; without an insert it is still there.
        if hasMarkedText && !didInsert { client.clearMarkedText() }
        hasMarkedText = false
        candidatePresenter.hide()
    }

    /// IMKit hides the input method's windows (`hidePalettes`); the composition stays.
    public func hidePalettes(token: UUID) {
        guard activeToken == nil || activeToken == token else { return }
        candidatePresenter.hide()
    }

    /// The user picked an input mode (`setValue:forTag:client:` with
    /// `kTextServiceInputModePropertyTag`). `zhHansInputModeID` keeps the engine's current
    /// `ascii_mode`: Chinese is the schema default, and a focus change never resets it.
    /// `asciiInputModeID` commits any composition (drops it under secure input, inserting
    /// nothing) and turns ASCII mode on. Unknown modes change nothing.
    public func setInputMode(_ modeID: String, token: UUID, client: any TextInputClient) {
        guard modeID == Self.asciiInputModeID else { return }
        take(token: token, client: client)
        if isSecureInputEnabled() {
            dropComposition()
        } else {
            commitComposition(token: token, client: client)
        }
        engineProvider()?.setASCIIMode(true)
    }

    // MARK: - Keys

    /// Handles an AppKit event from `handle(_:client:)`; anything but a key-down is `false`.
    public func handleNSEvent(_ nsEvent: NSEvent, token: UUID, client: any TextInputClient) -> Bool {
        guard let event = NSEventKeyBridge.keyEvent(from: nsEvent) else { return false }
        return handleKey(event, token: token, client: client)
    }

    /// Handles one key for `token`'s client. Returns whether the client must *not* receive
    /// the key; committed text is inserted either way.
    public func handleKey(_ event: KeyEvent, token: UUID, client: any TextInputClient) -> Bool {
        // 1. Secure input: pass through before the engine sees the key. Only marked text
        //    the shell put on a client is cleared; a secure client is never given any. A
        //    composition without marked text (preedit drawn in the panel) is dropped too.
        if isSecureInputEnabled() {
            candidatePresenter.hide()
            if activeToken != token || hasMarkedText || (engineProvider()?.currentState.isComposing == true) {
                dropComposition()
                activeToken = token
                activeClient = client
            }
            return false
        }

        // 2. The key's session owns the composition from now on.
        take(token: token, client: client)

        // 3. No engine or Safe Mode: everything passes through.
        guard let engine = engineProvider(), !engine.currentState.isSafeMode else {
            if hasMarkedText { client.clearMarkedText() }
            hasMarkedText = false
            candidatePresenter.hide()
            return false
        }

        // 4. Idle ASCII mode: the key is the client's, with no engine call.
        let before = engine.currentState
        if before.isASCIIMode && !before.isComposing {
            if hasMarkedText { client.clearMarkedText() }
            hasMarkedText = false
            candidatePresenter.hide()
            return false
        }

        // 5–6. Ask the engine, then apply its result: committed text first.
        let result = engine.processKey(event)
        applyResult(result, to: client)
        return result.handled
    }

    // MARK: - Panel clicks

    /// The user clicked candidate `index` of the panel showing `expectedGenerationID`.
    /// Selects it like its number key would and returns true; returns false and changes
    /// nothing under secure input, without an owner, engine, or Safe Mode, or when the
    /// engine has moved past `expectedGenerationID` (a click on a stale panel).
    @discardableResult
    public func selectCandidate(at index: Int, expectedGenerationID: UInt64? = nil) -> Bool {
        guard let (engine, client) = clickTarget(expectedGenerationID: expectedGenerationID) else { return false }
        let result = engine.selectCandidate(at: index)
        guard result.handled else { return false }
        applyResult(result, to: client)
        return true
    }

    /// The user paged the panel showing `expectedGenerationID`. Same guards as
    /// `selectCandidate(at:expectedGenerationID:)`; also false without a composition.
    @discardableResult
    public func changePage(backward: Bool, expectedGenerationID: UInt64? = nil) -> Bool {
        guard let (engine, client) = clickTarget(expectedGenerationID: expectedGenerationID),
            engine.currentState.isComposing
        else { return false }
        let state = engine.changePage(backward: backward)
        applyResult(KeyHandlingResult(handled: true, state: state), to: client)
        return true
    }

    /// The engine and owner's client a panel click may act on, or nil.
    private func clickTarget(expectedGenerationID: UInt64?) -> (any TypingEngine, any TextInputClient)? {
        if isSecureInputEnabled() {
            candidatePresenter.hide()
            return nil
        }
        guard activeToken != nil, let client = activeClient, let engine = engineProvider() else { return nil }
        let state = engine.currentState
        guard !state.isSafeMode else { return nil }
        if let expected = expectedGenerationID, state.generationID != expected { return nil }
        return (engine, client)
    }

    // MARK: - Applying results

    /// Applies an engine result to the owner's client: committed text first, then the
    /// composition (marked text or panel preedit) or nothing.
    private func applyResult(_ result: KeyHandlingResult, to client: any TextInputClient) {
        let state = result.state
        if let committed = result.committedText, !committed.isEmpty {
            client.insertText(committed)
            // insertText replaced the marked text; no redundant empty setMarkedText.
            hasMarkedText = false
            if state.isComposing {
                present(state, on: client)
            } else {
                candidatePresenter.hide()
            }
            return
        }
        if state.isComposing {
            present(state, on: client)
        } else {
            if hasMarkedText { client.clearMarkedText() }
            hasMarkedText = false
            candidatePresenter.hide()
        }
    }

    /// Shows `state` as marked text, or only in the panel for inline-preedit-disabled
    /// clients, and refreshes the panel.
    private func present(_ state: CompositionState, on client: any TextInputClient) {
        let inPanel = rendersPreeditInPanel(for: client)
        if inPanel {
            if hasMarkedText { client.clearMarkedText() }
            hasMarkedText = false
        } else {
            client.setMarkedText(
                preedit: state.preedit,
                caretUTF16Offset: state.caretUTF16Offset,
                selectionUTF16Range: state.selectionUTF16Range
            )
            hasMarkedText = true
        }
        candidatePresenter.update(
            state: state, client: client,
            options: CandidatePresentationOptions(rendersPreeditInPanel: inPanel, sessionToken: activeToken))
    }

    private func rendersPreeditInPanel(for client: any TextInputClient) -> Bool {
        client.clientBundleIdentifier.map { inlinePreeditDisabledBundleIDs.contains($0) } == true
    }

    // MARK: - Ownership

    /// Makes `token` the owner, first clearing what a different previous owner left.
    private func take(token: UUID, client: any TextInputClient) {
        if activeToken == token {
            activeClient = client
            return
        }
        if activeToken != nil { releaseActive() }
        activeToken = token
        activeClient = client
        hasMarkedText = false
    }

    /// Clears the owner's marked text (only if the shell put it there) and the engine's
    /// composition, keeping `ascii_mode`, and hides the menu. Inserts nothing.
    private func dropComposition() {
        if hasMarkedText { activeClient?.clearMarkedText() }
        hasMarkedText = false
        if let engine = engineProvider(), engine.currentState.isComposing {
            engine.clearComposition()
        }
        candidatePresenter.hide()
    }

    /// Drops the owner's composition and leaves no owner.
    private func releaseActive() {
        dropComposition()
        activeToken = nil
        activeClient = nil
    }
}
