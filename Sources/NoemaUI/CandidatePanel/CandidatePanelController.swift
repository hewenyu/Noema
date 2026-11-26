import AppKit
import CoreGraphics
import NoemaCore
import NoemaIMEShell
import QuartzCore

/// A borderless panel that never becomes key or main, so clicking it never takes focus
/// from the client application.
final class NonActivatingCandidatePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The candidate panel: one reused non-activating `NSPanel` above the client's window,
/// placed by `CaretPositionResolver`, sized by `CandidateLayoutEngine` and
/// `WidthHysteresis`, and drawn by `CandidatePanelView` on Liquid Glass
/// (`NSGlassEffectView`) or, in `.visualEffect` mode, an `NSVisualEffectView`.
///
/// Zero flicker: the panel is ordered front only on the hidden → visible transition, its
/// frame is set only when it changes, and every layer change runs with actions disabled.
///
/// The same panel presents v-mode (`VModePresenting`): `VModePanelView` and the candidate
/// view share one content host on the one backdrop, and exactly one of them is visible, so
/// the v-mode menu and the candidate menu never overlap. Both place through the one
/// `CaretPositionResolver` (one caret cache) at the same window level and screen bounds.
/// `hide()` hides only the candidate menu and `hideVMode()` only v-mode; `hideAll()` both.
@MainActor
public final class CandidatePanelController: CandidatePresenting, VModePresenting {
    /// A candidate was clicked: page index and the generation the panel showed.
    public var onSelectCandidate: (@MainActor (Int, UInt64) -> Void)?
    /// The panel was scrolled: `true` pages backward; the generation the panel showed.
    public var onChangePage: (@MainActor (Bool, UInt64) -> Void)?
    /// A v-mode item was clicked: its index and the v-mode generation the panel showed.
    public var onSelectVModeItem: (@MainActor (Int, UInt64) -> Void)?

    public var backdropMode: CandidatePanelStyle.BackdropMode {
        didSet {
            guard backdropMode != oldValue else { return }
            installBackdrop()
            rerenderCurrent()
        }
    }

    public let style: CandidatePanelStyle
    public private(set) var isVisible = false
    public private(set) var isExpanded = false
    public private(set) var currentLayout: CandidatePanelLayout?
    /// The v-mode layout on screen; nil unless v-mode is shown.
    public private(set) var currentVModeLayout: VModePanelLayout?
    /// True while the panel shows v-mode rather than candidates.
    public private(set) var isShowingVMode = false

    private let layoutEngine: CandidateLayoutEngine
    private var hysteresis: WidthHysteresis
    private var resolver: CaretPositionResolver
    private let panel: NonActivatingCandidatePanel
    private let candidateView: CandidatePanelView
    private let vModeView: VModePanelView
    private let vModeLayoutEngine: VModeLayoutEngine
    /// Holds the candidate view and the v-mode view, each sized to its bounds.
    private let contentHost = PanelContentHost()
    private var glassView: NSGlassEffectView?
    private var effectView: NSVisualEffectView?
    private var lastAppliedFrame: CGRect?
    /// The in-page scroll of a list taller than the screen; 0 on every new candidate list.
    private var verticalScrollOffset: CGFloat = 0

    /// What the panel shows, kept so the expand button can re-render it in place.
    private struct Presentation {
        let state: CompositionState
        let options: CandidatePresentationOptions
        let caretRect: CGRect?
        let clientKey: String
        let windowLevel: Int?
    }
    private var presentation: Presentation?

    private struct VModePresentation {
        let state: VModePanelState
        let options: CandidatePresentationOptions
        let caretRect: CGRect?
        let clientKey: String
        let windowLevel: Int?
    }
    private var vModePresentation: VModePresentation?
    private var vModeScrollOffset: CGFloat = 0
    /// The mouse location a composition with no valid or cached caret is anchored to,
    /// sampled once per client and session so paging, scrolling, or expanding with the
    /// pointer over the panel never re-anchors it under that pointer. Cleared when a valid
    /// caret arrives or the panel hides.
    private var mouseFallbackAnchor: (clientKey: String, sessionToken: UUID?, location: CGPoint)?

    // MARK: Test hooks (internal; `@testable import NoemaUI`)

    /// The screens the resolver places the panel on.
    var screensProvider: @MainActor () -> [ScreenFrame] = {
        NSScreen.screens.map { ScreenFrame(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
    /// `false` keeps the real panel off screen (headless tests); everything else still runs.
    var shouldOrderFront = true
    /// The pointer location sampled for the mouse fallback anchor.
    var mouseLocationProvider: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    var panelViewForTesting: CandidatePanelView { candidateView }
    var vModeViewForTesting: VModePanelView { vModeView }
    var panelForTesting: NSPanel { panel }

    public init(style: CandidatePanelStyle = CandidatePanelStyle()) {
        self.style = style
        backdropMode = style.backdropMode
        layoutEngine = CandidateLayoutEngine(style: style)
        hysteresis = WidthHysteresis(style: style)
        resolver = CaretPositionResolver(style: style)
        candidateView = CandidatePanelView(style: style)
        vModeView = VModePanelView(style: style)
        vModeLayoutEngine = VModeLayoutEngine(style: style)
        contentHost.addSubview(candidateView)
        contentHost.addSubview(vModeView)
        vModeView.isHidden = true

        panel = NonActivatingCandidatePanel(
            contentRect: CGRect(x: 0, y: 0, width: style.minPanelWidth, height: 36),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .popUpMenu

        candidateView.onSelectCandidate = { [weak self] index, generation in
            self?.onSelectCandidate?(index, generation)
        }
        candidateView.onChangePage = { [weak self] backward, generation in
            self?.onChangePage?(backward, generation)
        }
        candidateView.onScrollCandidates = { [weak self] offset, generation in
            guard let self, generation == currentLayout?.generationID else { return }
            verticalScrollOffset = offset
            rerender(ensureHighlightVisible: false)
        }
        vModeView.onSelectItem = { [weak self] index, generation in
            self?.onSelectVModeItem?(index, generation)
        }
        vModeView.onScroll = { [weak self] offset, generation in
            guard let self, generation == currentVModeLayout?.generationID else { return }
            vModeScrollOffset = offset
            rerenderVMode(ensureHighlightVisible: false)
        }
        candidateView.onToggleExpand = { [weak self] in
            guard let self else { return }
            isExpanded.toggle()
            verticalScrollOffset = 0
            rerender()
        }
        installBackdrop()
    }

    // MARK: - CandidatePresenting

    public func update(state: CompositionState, client: any TextInputClient, options: CandidatePresentationOptions) {
        let showsPreedit = options.rendersPreeditInPanel && !state.preedit.isEmpty
        guard state.isComposing, !(state.candidates.isEmpty && !showsPreedit) else {
            hide()
            return
        }
        if isShowingVMode { leaveVMode() }
        // Index 0 of the marked text: the panel stays put while the caret moves inside it.
        let clientKey = client.uniqueClientIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            ?? options.sessionToken?.uuidString ?? "default"
        // Arrow keys on the same page keep the scroll; the highlight tracking moves it.
        if presentation?.state.candidates != state.candidates { verticalScrollOffset = 0 }
        presentation = Presentation(
            state: state, options: options, caretRect: client.caretScreenRect(atUTF16Offset: 0),
            clientKey: clientKey, windowLevel: client.windowLevel)
        rerender()
    }

    /// Hides the candidate menu; a no-op while the panel shows v-mode.
    public func hide() {
        guard !isShowingVMode else { return }
        hideAll()
    }

    /// Hides the panel, whatever it shows. Idempotent.
    public func hideAll() {
        if isShowingVMode { leaveVMode() }
        if isVisible { panel.orderOut(nil) }
        isVisible = false
        isExpanded = false
        verticalScrollOffset = 0
        hysteresis.reset()
        lastAppliedFrame = nil
        presentation = nil
        mouseFallbackAnchor = nil
        currentLayout = nil
        candidateView.reset()
    }

    // MARK: - VModePresenting

    public func updateVMode(_ state: VModePanelState, client: any TextInputClient, options: CandidatePresentationOptions) {
        if !isShowingVMode {
            // The candidate menu's per-composition state ends; the panel and caret cache stay.
            isExpanded = false
            verticalScrollOffset = 0
            hysteresis.reset()
            presentation = nil
            currentLayout = nil
            candidateView.reset()
            candidateView.isHidden = true
            vModeView.isHidden = false
            isShowingVMode = true
        }
        let clientKey = client.uniqueClientIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            ?? options.sessionToken?.uuidString ?? "default"
        if vModePresentation.map({ Self.sameList($0.state, state) }) != true { vModeScrollOffset = 0 }
        vModePresentation = VModePresentation(
            state: state, options: options, caretRect: client.caretScreenRect(atUTF16Offset: 0), clientKey: clientKey,
            windowLevel: client.windowLevel)
        rerenderVMode()
    }

    /// Hides v-mode; a no-op while the panel shows candidates.
    public func hideVMode() {
        guard isShowingVMode else { return }
        hideAll()
    }

    /// Switches the content host back to the candidate view and forgets v-mode.
    private func leaveVMode() {
        isShowingVMode = false
        vModePresentation = nil
        currentVModeLayout = nil
        vModeScrollOffset = 0
        vModeView.reset()
        vModeView.isHidden = true
        candidateView.isHidden = false
    }

    /// Whether two v-mode states show the same list (only the highlight may differ).
    private static func sameList(_ a: VModePanelState, _ b: VModePanelState) -> Bool {
        switch (a, b) {
        case (.menu, .menu): true
        case (.subMode(let t1, _, let h1, let r1, _, let p1, _), .subMode(let t2, _, let h2, let r2, _, let p2, _)):
            t1 == t2 && h1 == h2 && r1 == r2 && p1 == p2
        default: false
        }
    }

    /// Lays out and places v-mode exactly as `rerender` does the candidates: bounded by the
    /// target screen's visible frame, at the caret (cached caret, then a fixed mouse anchor).
    private func rerenderVMode(ensureHighlightVisible: Bool = true) {
        guard let presentation = vModePresentation else { return }
        let screens = screensProvider()
        let mouseLocation: CGPoint
        if let saved = mouseFallbackAnchor, saved.clientKey == presentation.clientKey,
            saved.sessionToken == presentation.options.sessionToken
        {
            mouseLocation = saved.location
        } else {
            mouseLocation = mouseLocationProvider()
        }
        guard let screen = resolver.targetScreen(
            caretRect: presentation.caretRect, clientKey: presentation.clientKey, screens: screens,
            fallbackMouseLocation: mouseLocation)
        else {
            hideAll()
            return
        }
        let margins = 2 * style.screenMargin
        let visible = screen.visibleFrame
        let maxWidth = visible.width > margins + style.minPanelWidth ? visible.width - margins : visible.width
        let maxHeight = visible.height > margins + 80 ? visible.height - margins : visible.height
        let layout = vModeLayoutEngine.layout(
            state: presentation.state, options: presentation.options, maxWidth: maxWidth, maxHeight: maxHeight,
            verticalScrollOffset: vModeScrollOffset, ensureHighlightVisible: ensureHighlightVisible)
        vModeScrollOffset = layout.verticalScrollOffset
        guard let resolution = resolver.resolve(
            caretRect: presentation.caretRect, clientKey: presentation.clientKey, panelSize: layout.panelSize,
            screens: screens, fallbackMouseLocation: mouseLocation)
        else {
            hideAll()
            return
        }
        mouseFallbackAnchor = resolution.usedMouseFallback
            ? (presentation.clientKey, presentation.options.sessionToken, mouseLocation) : nil
        currentVModeLayout = layout
        let target = CGRect(origin: resolution.origin, size: layout.panelSize)
        let level = Self.windowLevel(above: presentation.windowLevel)
        if panel.level != level { panel.level = level }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if target != lastAppliedFrame {
            let sizeChanged = lastAppliedFrame?.size != target.size
            panel.setFrame(target, display: false)
            if sizeChanged && backdropMode == .visualEffect { panel.invalidateShadow() }
            lastAppliedFrame = target
        }
        glassView?.cornerRadius = layout.cornerRadius
        effectView?.layer?.cornerRadius = layout.cornerRadius
        contentHost.syncSubviewFrames()
        vModeView.apply(layout)
        panel.contentView?.layoutSubtreeIfNeeded()
        CATransaction.commit()

        if !isVisible {
            if shouldOrderFront { panel.orderFrontRegardless() }
            isVisible = true
        }
    }

    // MARK: - Rendering

    /// Lays out the presentation bounded to its target screen's visible width and height
    /// (minus the screen margins when there is room), so the panel always fits inside the
    /// visible frame, a row too wide expands, and a list taller than that scrolls; then
    /// places it at the caret.
    private func rerender(ensureHighlightVisible: Bool = true) {
        guard let presentation else { return }
        let screens = screensProvider()
        let mouseLocation: CGPoint
        if let saved = mouseFallbackAnchor, saved.clientKey == presentation.clientKey,
            saved.sessionToken == presentation.options.sessionToken
        {
            mouseLocation = saved.location
        } else {
            mouseLocation = mouseLocationProvider()
        }
        guard let screen = resolver.targetScreen(
            caretRect: presentation.caretRect, clientKey: presentation.clientKey, screens: screens,
            fallbackMouseLocation: mouseLocation)
        else {
            hide()
            return
        }
        let visibleWidth = screen.visibleFrame.width
        let visibleHeight = screen.visibleFrame.height
        let margins = 2 * style.screenMargin
        let maxWidth = visibleWidth > margins + style.minPanelWidth ? visibleWidth - margins : visibleWidth
        let maxHeight = visibleHeight > margins + 80 ? visibleHeight - margins : visibleHeight
        let layout = layoutEngine.layout(
            state: presentation.state, options: presentation.options, expanded: isExpanded, hysteresis: &hysteresis,
            maxWidth: maxWidth, maxHeight: maxHeight, verticalScrollOffset: verticalScrollOffset,
            ensureHighlightVisible: ensureHighlightVisible)
        verticalScrollOffset = layout.verticalScrollOffset
        guard let resolution = resolver.resolve(
            caretRect: presentation.caretRect, clientKey: presentation.clientKey, panelSize: layout.panelSize,
            screens: screens, fallbackMouseLocation: mouseLocation)
        else {
            hide()
            return
        }
        mouseFallbackAnchor = resolution.usedMouseFallback
            ? (presentation.clientKey, presentation.options.sessionToken, mouseLocation) : nil
        currentLayout = layout
        let target = CGRect(origin: resolution.origin, size: layout.panelSize)

        let level = Self.windowLevel(above: presentation.windowLevel)
        if panel.level != level { panel.level = level }

        // Resize the panel first, then apply the layout to the resized view: the view sizes
        // its subviews from its own bounds, never from a size the panel has not reached yet.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if target != lastAppliedFrame {
            let sizeChanged = lastAppliedFrame?.size != target.size
            panel.setFrame(target, display: false)
            if sizeChanged && backdropMode == .visualEffect { panel.invalidateShadow() }
            lastAppliedFrame = target
        }
        glassView?.cornerRadius = layout.cornerRadius
        effectView?.layer?.cornerRadius = layout.cornerRadius
        contentHost.syncSubviewFrames()
        candidateView.apply(layout)
        panel.contentView?.layoutSubtreeIfNeeded()
        CATransaction.commit()

        if !isVisible {
            if shouldOrderFront { panel.orderFrontRegardless() }
            isVisible = true
        }
    }

    /// One level above the client's window, at least `.popUpMenu` (above Spotlight and
    /// launcher panels), at most the screen saver level.
    static func windowLevel(above clientLevel: Int?) -> NSWindow.Level {
        let ceiling = Int(CGWindowLevelForKey(.screenSaverWindow))
        let level = clientLevel ?? 0
        let raised = level >= ceiling ? ceiling : level + 1
        return NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, raised))
    }

    private func installBackdrop() {
        let radius = currentVModeLayout?.cornerRadius ?? currentLayout?.cornerRadius ?? style.expandedCornerRadius
        // Detach the host from the previous backdrop first.
        glassView?.contentView = nil
        contentHost.removeFromSuperview()
        glassView = nil
        effectView = nil

        switch backdropMode {
        case .glass:
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            contentHost.translatesAutoresizingMaskIntoConstraints = true
            contentHost.autoresizingMask = [.width, .height]
            glass.contentView = contentHost
            glassView = glass
            panel.contentView = glass
            panel.hasShadow = false
        case .visualEffect:
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
            contentHost.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(contentHost)
            NSLayoutConstraint.activate([
                contentHost.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                contentHost.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                contentHost.topAnchor.constraint(equalTo: effect.topAnchor),
                contentHost.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            effectView = effect
            panel.contentView = effect
            panel.hasShadow = true
        }
        candidateView.needsLayout = true
        vModeView.needsLayout = true
        lastAppliedFrame = nil
    }

    /// Re-applies the shown content after a backdrop switch.
    private func rerenderCurrent() {
        if isShowingVMode { rerenderVMode() } else { rerender() }
    }
}

/// The backdrop's content: the candidate view and the v-mode view, each always exactly the
/// host's bounds (set explicitly, never by autoresizing deltas).
@MainActor
final class PanelContentHost: NSView {
    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        syncSubviewFrames()
    }

    override func layout() {
        super.layout()
        syncSubviewFrames()
    }

    func syncSubviewFrames() {
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }

    /// Clicks go to whichever content view is visible.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for view in subviews.reversed() where !view.isHidden {
            if let hit = view.hitTest(local) { return hit }
        }
        return nil
    }
}
