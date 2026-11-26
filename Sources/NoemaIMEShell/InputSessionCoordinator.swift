import AppKit
import Carbon.HIToolbox
import NoemaCore
import NoemaText

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
///
/// v-mode: while the engine is idle, a plain `v` opens the v-mode menu (`VModeReducer`); its
/// offline tools (`CalculatorEvaluator`, `SnippetStore`, `SymbolPalette`,
/// `DateTimeTemplates`) commit text directly, and its agent cells call `onQuickAction`. While
/// the engine composes, every key goes to the engine, so `lv` still spells 绿. Secure input,
/// Safe Mode, ASCII mode, focus loss, `commitComposition`, and `hidePalettes` end v-mode at
/// once: its marked text is cleared and its panel hidden. v-mode itself sends no IPC.
@MainActor
public final class InputSessionCoordinator {
    /// A mode ID that switches the engine to ASCII. `Info.plist.in` declares only
    /// `NoemaPaths.zhHansInputModeID` today; this is the seam for an ASCII mode.
    public static let asciiInputModeID = NoemaPaths.imeBundleID + ".ascii"

    private let engineProvider: @MainActor () -> (any TypingEngine)?
    private let candidatePresenter: any CandidatePresenting
    private let vModePresenter: any VModePresenting
    private let isSecureInputEnabled: @MainActor () -> Bool
    private let inlinePreeditDisabledBundleIDs: Set<String>
    private let now: @MainActor () -> Date
    private let timeZone: TimeZone
    private let snippetStore: SnippetStore

    /// Where v-mode is; `.idle` or `.composing` whenever it shows nothing.
    public private(set) var vModeState: VModeState = .idle
    /// Strictly increases with every v-mode panel state presented; clicks carry it back.
    public private(set) var vModeGenerationID: UInt64 = 0
    /// Called on the main actor when the user picks a v-mode agent action (`v2`, `v4`, `v6`,
    /// `v7`, `v9`). Never called under secure input. `EngineHost` hands it to
    /// `CompositionIPCReporter.requestQuickAction(_:)`.
    public var onQuickAction: (@MainActor (QuickActionID) -> Void)?
    /// The instant the `v8` candidates describe, fixed while the date list is open.
    private var dateAnchor = Date(timeIntervalSince1970: 0)
    /// The snippets read when `v3` opened, kept while the list is open.
    private var snippetCache: [Snippet]?

    /// The session that owns the engine's composition, and its client.
    public private(set) var activeToken: UUID?
    private var activeClient: (any TextInputClient)?
    /// True while `activeClient` shows marked text the shell put there.
    public private(set) var hasMarkedText = false

    /// Called with the engine's state after every composition or mode change the shell
    /// makes: keys, panel clicks, `commitComposition`, a switch to ASCII mode, and every
    /// dropped composition (focus loss, controller close, ownership transfer, secure
    /// input). `EngineHost` hands it to `CompositionIPCReporter`, which updates the local
    /// generation gate on every call but sends nothing while secure input is on.
    public var onCompositionChange: (@MainActor (CompositionState) -> Void)?

    /// `now`, `timeZone`, and `snippetStore` feed v-mode's date list and snippets; tests pin them.
    public init(
        engineProvider: @escaping @MainActor () -> (any TypingEngine)?,
        candidatePresenter: any CandidatePresenting = NoOpCandidatePresenter(),
        vModePresenter: any VModePresenting = NoOpVModePresenter(),
        isSecureInputEnabled: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
        inlinePreeditDisabledBundleIDs: Set<String> = [],
        now: @escaping @MainActor () -> Date = { Date() },
        timeZone: TimeZone = .current,
        snippetStore: SnippetStore = SnippetStore(fileURL: NoemaPaths.snippetsURL())
    ) {
        self.engineProvider = engineProvider
        self.candidatePresenter = candidatePresenter
        self.vModePresenter = vModePresenter
        self.isSecureInputEnabled = isSecureInputEnabled
        self.inlinePreeditDisabledBundleIDs = inlinePreeditDisabledBundleIDs
        self.now = now
        self.timeZone = timeZone
        self.snippetStore = snippetStore
    }

    // MARK: - Lifecycle

    /// A controller's client gained focus (`activateServer:`).
    public func activate(token: UUID, client: any TextInputClient) {
        take(token: token, client: client)
        if isSecureInputEnabled() {
            candidatePresenter.hide()
            endVMode()
        }
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
        // v-mode commits nothing on a click outside: its marked text is only cleared.
        if vModeState.isActive {
            endVMode()
            return
        }
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
        onCompositionChange?(engine.currentState)
    }

    /// IMKit hides the input method's windows (`hidePalettes`); the composition stays.
    public func hidePalettes(token: UUID) {
        guard activeToken == nil || activeToken == token else { return }
        candidatePresenter.hide()
        // v-mode has no composition to keep: it ends with its panel.
        endVMode()
    }

    /// The user picked an input mode (`setValue:forTag:client:` with
    /// `kTextServiceInputModePropertyTag`). `zhHansInputModeID` keeps the engine's current
    /// `ascii_mode`: Chinese is the schema default, and a focus change never resets it.
    /// `asciiInputModeID` commits any composition (drops it under secure input, inserting
    /// nothing) and turns ASCII mode on. Unknown modes change nothing.
    public func setInputMode(_ modeID: String, token: UUID, client: any TextInputClient) {
        guard modeID == Self.asciiInputModeID else { return }
        take(token: token, client: client)
        endVMode()
        if isSecureInputEnabled() {
            dropComposition()
        } else {
            commitComposition(token: token, client: client)
        }
        guard let engine = engineProvider() else { return }
        // Never inline into `onCompositionChange?(…)`: a nil handler would skip the call.
        let state = engine.setASCIIMode(true)
        onCompositionChange?(state)
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
            endVMode()
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
            endVMode()
            if hasMarkedText { client.clearMarkedText() }
            hasMarkedText = false
            candidatePresenter.hide()
            return false
        }

        // 4. Idle ASCII mode: the key is the client's, with no engine call.
        let before = engine.currentState
        if before.isASCIIMode && !before.isComposing {
            endVMode()
            if hasMarkedText { client.clearMarkedText() }
            hasMarkedText = false
            candidatePresenter.hide()
            return false
        }

        // 5. v-mode, unless the engine composes (then the key is the engine's: `lv` is 绿).
        if !before.isComposing {
            let (next, effect) = runVMode(.key(event), isEngineComposing: false, isASCIIMode: before.isASCIIMode)
            if effect != .passToRime { return applyVMode(next, effect, client: client) }
            vModeState = .idle
        }

        // 6–7. Ask the engine, then apply its result: committed text first.
        let result = engine.processKey(event)
        vModeState = result.state.isComposing ? .composing : .idle
        applyResult(result, to: client)
        return result.handled
    }

    // MARK: - v-mode

    /// The user clicked item `index` (a menu cell or a row on the current page) of the
    /// v-mode panel showing `expectedGenerationID`. Acts like the key that selects it and
    /// returns true; returns false and changes nothing under secure input (which also ends
    /// v-mode), without an owner, engine, or v-mode, in Safe Mode, or for a stale panel.
    @discardableResult
    public func selectVModeItem(at index: Int, expectedGenerationID: UInt64) -> Bool {
        if isSecureInputEnabled() {
            candidatePresenter.hide()
            endVMode()
            return false
        }
        guard vModeState.isActive, activeToken != nil, let client = activeClient, expectedGenerationID == vModeGenerationID
        else { return false }
        guard let engine = engineProvider(), !engine.currentState.isSafeMode, !engine.currentState.isASCIIMode else {
            endVMode()
            return false
        }
        let (next, effect) = runVMode(
            .click(index: index), isEngineComposing: engine.currentState.isComposing,
            isASCIIMode: engine.currentState.isASCIIMode)
        _ = applyVMode(next, effect, client: client)
        return true
    }

    /// The reducer over this coordinator's offline tools.
    private var vModeReducer: VModeReducer {
        let snippets = snippetCache ?? []
        let palette = SymbolPalette.builtIn
        let templates = DateTimeTemplates(timeZone: timeZone)
        let anchor = dateAnchor
        return VModeReducer(environment: VModeEnvironment(
            pageSize: 9,
            calculate: { CalculatorEvaluator.evaluateFormatted($0) },
            snippets: { SnippetStore.matching(snippets, query: $0) },
            symbolCategories: palette.categoryNames,
            symbols: { palette.symbols(categoryIndex: $0, query: $1) },
            dateTimeItems: { templates.candidates(for: anchor) }))
    }

    /// One reducer step. The date list's instant is fixed when it opens, and the snippets
    /// are read once when `v3` opens.
    private func runVMode(_ input: VModeInput, isEngineComposing: Bool, isASCIIMode: Bool = false) -> (VModeState, VModeEffect) {
        if case .vSub(.dateTime) = vModeState {} else { dateAnchor = now() }
        let context = VModeContext(isASCIIMode: isASCIIMode, isEngineComposing: isEngineComposing)
        let (next, effect) = vModeReducer.reduce(vModeState, input, context: context)
        if case .vSub(.snippets) = next {
            if snippetCache == nil { snippetCache = snippetStore.load() }
        } else {
            snippetCache = nil
        }
        return (next, effect)
    }

    /// Applies a v-mode transition to the owner's client; returns whether the client must
    /// not receive the key.
    private func applyVMode(_ next: VModeState, _ effect: VModeEffect, client: any TextInputClient) -> Bool {
        switch effect {
        case .passToRime:
            vModeState = next
            return false
        case .passThroughToClient:
            endVMode()
            return false
        case .consumeOnly:
            if next.isActive {
                vModeState = next
                presentVMode(on: client)
            } else {
                endVMode()
            }
            return true
        case .commitText(let text):
            vModeState = .idle
            snippetCache = nil
            vModePresenter.hideVMode()
            client.insertText(text)
            // insertText replaced the marked text.
            hasMarkedText = false
            return true
        case .dispatchAgent(let action):
            endVMode()
            // Defense in depth: secure input never reaches here, and never dispatches.
            if !isSecureInputEnabled() { onQuickAction?(action) }
            return true
        }
    }

    /// Shows `vModeState` as marked text (or only in the panel for inline-preedit-disabled
    /// clients) and refreshes the panel under a new generation.
    private func presentVMode(on client: any TextInputClient) {
        let preedit = vModeState.preedit
        let inPanel = rendersPreeditInPanel(for: client)
        if inPanel {
            if hasMarkedText { client.clearMarkedText() }
            hasMarkedText = false
        } else {
            let length = preedit.utf16.count
            client.setMarkedText(preedit: preedit, caretUTF16Offset: length, selectionUTF16Range: 0..<length)
            hasMarkedText = true
        }
        candidatePresenter.hide()
        vModeGenerationID &+= 1
        guard let state = vModePanelState() else { return }
        vModePresenter.updateVMode(
            state, client: client, options: CandidatePresentationOptions(rendersPreeditInPanel: inPanel, sessionToken: activeToken))
    }

    /// The panel content for `vModeState`, or nil when v-mode is not active.
    func vModePanelState() -> VModePanelState? {
        let preedit = vModeState.preedit
        switch vModeState {
        case .idle, .composing:
            return nil
        case .vMenu(let highlighted):
            return .menu(items: VModeMenuCell.all, highlightedIndex: highlighted, preedit: preedit, generationID: vModeGenerationID)
        case .vSub(let sub):
            let reducer = vModeReducer
            let texts = reducer.rows(for: sub)
            var rows = texts.enumerated().map { VModeSubRow(label: String($0.offset + 1), text: $0.element) }
            var title: String
            var hint: String?
            var pageInfo: String?
            var highlighted = 0
            switch sub {
            case .calculator(let expression, let pendingOne, let index):
                title = VMenuItem.calculator.title
                highlighted = index
                rows = zip(["结果", "算式"], texts).map { VModeSubRow(label: $0, text: $1) }
                if rows.isEmpty { hint = (pendingOne || !expression.isEmpty) ? "算式不完整" : "输入算式，如 1+2*3" }
            case .snippets(let query, let index, let page):
                title = VMenuItem.snippets.title
                highlighted = index
                hint = query.isEmpty ? "输入字母筛选" : "筛选：\(query)"
                pageInfo = "\(page + 1)/\(reducer.pageCount(for: sub))"
            case .symbols(let category, let query, let index, let page):
                let names = SymbolPalette.builtIn.categoryNames
                title = "\(VMenuItem.symbols.title) · \(names[min(max(category, 0), names.count - 1)])"
                highlighted = index
                hint = query.isEmpty ? "Tab 切换分类" : "筛选：\(query)"
                pageInfo = "\(page + 1)/\(reducer.pageCount(for: sub))"
            case .dateTime(let index):
                title = VMenuItem.dateTime.title
                highlighted = index
            case .literal:
                title = "原样输入"
                rows = texts.map { VModeSubRow(label: "↵", text: $0) }
                hint = "回车或空格上屏"
            }
            if rows.isEmpty { highlighted = 0 } else { highlighted = min(max(highlighted, 0), rows.count - 1) }
            return .subMode(
                title: title, preedit: preedit, queryHint: hint, rows: rows, highlightedIndex: highlighted, pageInfo: pageInfo,
                generationID: vModeGenerationID)
        }
    }

    /// Ends v-mode: clears its marked text from the owner's client (only if the shell put it
    /// there) and hides its panel. Idempotent; a no-op unless v-mode is active.
    private func endVMode() {
        snippetCache = nil
        guard vModeState.isActive else { return }
        vModeState = .idle
        if hasMarkedText { activeClient?.clearMarkedText() }
        hasMarkedText = false
        vModePresenter.hideVMode()
    }

    /// Re-syncs marked text, candidate panel, and composition listeners with the engine's
    /// current state (e.g. after an out-of-band option change such as `emoji_suggestion`
    /// arrives from the agent mid-composition). A no-op under secure input, while v-mode is
    /// active, in Safe Mode, or without an active owner.
    public func refreshPresentation() {
        guard !isSecureInputEnabled(), !vModeState.isActive, activeToken != nil, let client = activeClient,
              let engine = engineProvider()
        else { return }
        let state = engine.currentState
        guard !state.isSafeMode else { return }
        applyResult(KeyHandlingResult(handled: false, state: state), to: client)
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
        defer { onCompositionChange?(state) }
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
    /// composition, keeping `ascii_mode`, and hides the menu. Inserts nothing. A cleared
    /// composition is reported, so neither the agent nor the local gate keeps the old one.
    private func dropComposition() {
        endVMode()
        if vModeState == .composing { vModeState = .idle }
        if hasMarkedText { activeClient?.clearMarkedText() }
        hasMarkedText = false
        var clearedState: CompositionState?
        if let engine = engineProvider(), engine.currentState.isComposing {
            clearedState = engine.clearComposition()
        }
        candidatePresenter.hide()
        if let clearedState { onCompositionChange?(clearedState) }
    }

    /// Drops the owner's composition and leaves no owner.
    private func releaseActive() {
        dropComposition()
        activeToken = nil
        activeClient = nil
    }
}
