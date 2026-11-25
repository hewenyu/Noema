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
@MainActor
public final class CandidatePanelController: CandidatePresenting {
    /// A candidate was clicked: page index and the generation the panel showed.
    public var onSelectCandidate: (@MainActor (Int, UInt64) -> Void)?
    /// The panel was scrolled: `true` pages backward; the generation the panel showed.
    public var onChangePage: (@MainActor (Bool, UInt64) -> Void)?

    public var backdropMode: CandidatePanelStyle.BackdropMode {
        didSet {
            guard backdropMode != oldValue else { return }
            installBackdrop()
            rerender()
        }
    }

    public let style: CandidatePanelStyle
    public private(set) var isVisible = false
    public private(set) var isExpanded = false
    public private(set) var currentLayout: CandidatePanelLayout?

    private let layoutEngine: CandidateLayoutEngine
    private var hysteresis: WidthHysteresis
    private var resolver: CaretPositionResolver
    private let panel: NonActivatingCandidatePanel
    private let candidateView: CandidatePanelView
    private var glassView: NSGlassEffectView?
    private var effectView: NSVisualEffectView?
    private var lastAppliedFrame: CGRect?

    /// What the panel shows, kept so the expand button can re-render it in place.
    private struct Presentation {
        let state: CompositionState
        let options: CandidatePresentationOptions
        let caretRect: CGRect?
        let clientKey: String
        let windowLevel: Int?
    }
    private var presentation: Presentation?

    // MARK: Test hooks (internal; `@testable import NoemaUI`)

    /// The screens the resolver places the panel on.
    var screensProvider: @MainActor () -> [ScreenFrame] = {
        NSScreen.screens.map { ScreenFrame(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
    /// `false` keeps the real panel off screen (headless tests); everything else still runs.
    var shouldOrderFront = true
    var panelViewForTesting: CandidatePanelView { candidateView }
    var panelForTesting: NSPanel { panel }

    public init(style: CandidatePanelStyle = CandidatePanelStyle()) {
        self.style = style
        backdropMode = style.backdropMode
        layoutEngine = CandidateLayoutEngine(style: style)
        hysteresis = WidthHysteresis(style: style)
        resolver = CaretPositionResolver(style: style)
        candidateView = CandidatePanelView(style: style)

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
        candidateView.onToggleExpand = { [weak self] in
            guard let self else { return }
            isExpanded.toggle()
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
        // Index 0 of the marked text: the panel stays put while the caret moves inside it.
        let clientKey = client.uniqueClientIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            ?? options.sessionToken?.uuidString ?? "default"
        presentation = Presentation(
            state: state, options: options, caretRect: client.caretScreenRect(atUTF16Offset: 0),
            clientKey: clientKey, windowLevel: client.windowLevel)
        rerender()
    }

    public func hide() {
        if isVisible { panel.orderOut(nil) }
        isVisible = false
        isExpanded = false
        hysteresis.reset()
        lastAppliedFrame = nil
        presentation = nil
        currentLayout = nil
        candidateView.reset()
    }

    // MARK: - Rendering

    private func rerender() {
        guard let presentation else { return }
        let layout = layoutEngine.layout(
            state: presentation.state, options: presentation.options, expanded: isExpanded, hysteresis: &hysteresis)
        let screens = screensProvider()
        guard let resolution = resolver.resolve(
            caretRect: presentation.caretRect, clientKey: presentation.clientKey, panelSize: layout.panelSize,
            screens: screens, fallbackMouseLocation: NSEvent.mouseLocation)
        else {
            hide()
            return
        }
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
        let radius = currentLayout?.cornerRadius ?? style.expandedCornerRadius
        // Detach the view from the previous backdrop first.
        glassView?.contentView = nil
        candidateView.removeFromSuperview()
        glassView = nil
        effectView = nil

        switch backdropMode {
        case .glass:
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            candidateView.translatesAutoresizingMaskIntoConstraints = true
            candidateView.autoresizingMask = [.width, .height]
            glass.contentView = candidateView
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
            candidateView.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(candidateView)
            NSLayoutConstraint.activate([
                candidateView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                candidateView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                candidateView.topAnchor.constraint(equalTo: effect.topAnchor),
                candidateView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            effectView = effect
            panel.contentView = effect
            panel.hasShadow = true
        }
        candidateView.needsLayout = true
        lastAppliedFrame = nil
    }
}
