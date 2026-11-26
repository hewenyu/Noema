import AppKit
import CoreText
import QuartzCore

/// Draws a `CandidatePanelLayout` and turns clicks into candidate and expand actions.
///
/// Everything uses one top-down coordinate space (`isFlipped`): the layout, the highlight
/// `CAShapeLayer`, CoreText drawing, and hit testing. The blue capsule highlight lives in a
/// shape layer below the text view, updated without implicit animation, so it never slides
/// in from the origin. Dynamic colors resolve under the view's effective appearance on
/// every draw and on every appearance change.
@MainActor
public final class CandidatePanelView: NSView {
    /// A candidate was clicked: its page index and the layout's generation.
    public var onSelectCandidate: (@MainActor (Int, UInt64) -> Void)?
    /// The expand/collapse button was clicked.
    public var onToggleExpand: (@MainActor () -> Void)?
    /// The panel was scrolled: `true` pages backward, with the layout's generation.
    public var onChangePage: (@MainActor (Bool, UInt64) -> Void)?
    /// A scrolling list was scrolled within the page: the requested
    /// `verticalScrollOffset`, with the layout's generation.
    public var onScrollCandidates: (@MainActor (CGFloat, UInt64) -> Void)?

    public private(set) var panelLayout: CandidatePanelLayout?
    private let style: CandidatePanelStyle
    private let highlightHost = FlippedView()
    private let highlightLayer = CAShapeLayer()
    /// Clips the highlight to `candidatesViewport`, so a capsule scrolled partly out never
    /// bleeds over the preedit strip or the panel edge.
    private let highlightClipMask = CALayer()
    private let contentView: CandidateContentView
    /// The target under `mouseDown` and the generation it was laid out for. A refresh to
    /// another generation before `mouseUp` cancels the click, so a press on an old panel
    /// never commits a candidate of the new one.
    private var pressed: (target: CandidateHitTarget, generationID: UInt64)?
    private var scrollAccumulator: CGFloat = 0

    public init(style: CandidatePanelStyle) {
        self.style = style
        contentView = CandidateContentView(style: style)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        // No autoresizing masks: `layout()` sizes both subviews to `bounds`, so a panel
        // resize never applies the parent's size delta on top of an explicit frame.
        highlightHost.wantsLayer = true
        highlightLayer.actions = ["path": NSNull(), "fillColor": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        highlightLayer.isHidden = true
        highlightHost.layer?.addSublayer(highlightLayer)
        highlightClipMask.backgroundColor = CGColor(gray: 1, alpha: 1)
        highlightClipMask.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        addSubview(highlightHost)

        addSubview(contentView)
        updateAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Every click inside the panel is the panel's, never a subview's.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return bounds.contains(point) ? self : nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override public func layout() {
        super.layout()
        syncSubviewFrames()
    }

    /// The frames of the highlight host and the CoreText view, for tests.
    var subviewFramesForTesting: [CGRect] { [highlightHost.frame, contentView.frame] }

    /// Sizes the highlight host, its shape layer, and the CoreText view to `bounds`. The
    /// owner sizes this view (the panel frame) before `apply(_:)`; nothing here reads
    /// `layout.panelSize`, so the two can never disagree.
    private func syncSubviewFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightHost.frame = bounds
        contentView.frame = bounds
        highlightLayer.frame = bounds
        if let viewport = panelLayout?.candidatesViewport {
            highlightClipMask.frame = viewport
            if highlightHost.layer?.mask !== highlightClipMask { highlightHost.layer?.mask = highlightClipMask }
        } else if highlightHost.layer?.mask != nil {
            highlightHost.layer?.mask = nil
        }
        CATransaction.commit()
    }

    /// Shows `layout`; the caller sizes this view to `layout.panelSize` first and wraps
    /// both in a `CATransaction` with actions disabled.
    public func apply(_ layout: CandidatePanelLayout) {
        syncSubviewFrames()
        guard layout != self.panelLayout else { return }
        if self.panelLayout?.generationID != layout.generationID { pressed = nil }
        self.panelLayout = layout
        syncSubviewFrames()
        contentView.layout = layout
        if let pill = layout.highlightedPillFrame {
            let radius = layout.isExpanded
                ? max(min(style.expandedCornerRadius - style.horizontalPadding, pill.height / 2), 4)
                : min(pill.height, pill.width) / 2
            highlightLayer.path = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)
            highlightLayer.isHidden = false
        } else {
            highlightLayer.path = nil
            highlightLayer.isHidden = true
        }
        needsLayout = true
        contentView.needsDisplay = true
    }

    /// Clears the press state, e.g. when the panel hides mid-click.
    public func reset() {
        pressed = nil
        scrollAccumulator = 0
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        let palette = CandidatePanelPalette.resolve(for: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.fillColor = palette.selectionFill
        CATransaction.commit()
        contentView.needsDisplay = true
    }

    // MARK: - Mouse

    override public func mouseDown(with event: NSEvent) {
        guard let layout = panelLayout else { pressed = nil; return }
        let target = layout.hitTest(convert(event.locationInWindow, from: nil))
        pressed = target == .none ? nil : (target, layout.generationID)
    }

    /// Fires only when the release lands on the pressed target of the same generation, and
    /// always reports the press's generation, never a newer layout's.
    override public func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { pressed = nil }
        guard let layout = panelLayout, let pressed, layout.generationID == pressed.generationID,
              layout.hitTest(point) == pressed.target else { return }
        switch pressed.target {
        case .candidate(let index): onSelectCandidate?(index, pressed.generationID)
        case .expandButton: onToggleExpand?()
        case .none: break
        }
    }

    /// Scrolls a list taller than the screen within the page first (positive deltas toward
    /// candidate 0); only at either end does the accumulated scroll turn the Rime page.
    override public func scrollWheel(with event: NSEvent) {
        guard let layout = panelLayout, event.momentumPhase.isEmpty else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        if layout.maxVerticalScrollOffset > 0 {
            let target = min(max(layout.verticalScrollOffset - delta, 0), layout.maxVerticalScrollOffset)
            if abs(target - layout.verticalScrollOffset) > 0.5 {
                scrollAccumulator = 0
                onScrollCandidates?(target, layout.generationID)
                return
            }
        }
        scrollAccumulator += delta
        guard abs(scrollAccumulator) >= 30 else { return }
        let backward = scrollAccumulator > 0
        scrollAccumulator = 0
        onChangePage?(backward, layout.generationID)
    }
}

/// A layer-backed view whose sublayers use top-down coordinates.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The CoreText drawing of the panel: preedit strip, labels, candidates, comments, chevron.
@MainActor
private final class CandidateContentView: NSView {
    var layout: CandidatePanelLayout?
    private let style: CandidatePanelStyle

    init(style: CandidatePanelStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let palette = CandidatePanelPalette.resolve(for: effectiveAppearance)
        let fonts = CandidateTypesetter.Fonts(style: style)
        let scale = window?.backingScaleFactor ?? 2

        if let strip = layout.preeditStrip {
            // Text and caret scroll inside `clipRect`; nothing spills past the panel edge.
            ctx.saveGState()
            ctx.clip(to: strip.clipRect)
            drawLine(CandidateTypesetter.line(strip.text, font: fonts.preedit.font, color: palette.preeditText), at: strip.textOrigin, in: ctx)
            ctx.setFillColor(palette.caret)
            ctx.fill(strip.caretRect)
            ctx.restoreGState()
            if let dividerY = strip.dividerY {
                let hairline = 1 / scale
                ctx.setFillColor(palette.divider)
                ctx.fill(CGRect(x: strip.frame.minX + style.pillHorizontalInset, y: dividerY - hairline / 2,
                                width: max(strip.frame.width - 2 * style.pillHorizontalInset, 0), height: hairline))
            }
        }

        let viewport = layout.candidatesViewport
        if let viewport {
            ctx.saveGState()
            ctx.clip(to: viewport)
        }
        for item in layout.items where viewport.map({ item.pillFrame.intersects($0) }) ?? true {
            let primary = item.isHighlighted ? palette.selectedText : palette.text
            let secondary = item.isHighlighted ? palette.selectedSecondary : palette.secondary
            drawLine(CandidateTypesetter.line(item.displayLabel, font: fonts.label.font, color: secondary), at: item.labelOrigin, in: ctx)
            drawLine(CandidateTypesetter.line(item.displayText, font: fonts.candidate.font, color: primary), at: item.textOrigin, in: ctx)
            if let comment = item.displayComment, let origin = item.commentOrigin {
                drawLine(CandidateTypesetter.line(comment, font: fonts.comment.font, color: secondary), at: origin, in: ctx)
            }
        }
        if let viewport {
            ctx.restoreGState()
            if layout.maxVerticalScrollOffset > 0 {
                drawScrollThumb(in: viewport, layout: layout, color: palette.chevron, ctx: ctx)
            }
        }

        if let button = layout.expandButtonFrame {
            drawChevron(in: button, pointingUp: layout.isExpanded, color: palette.chevron, ctx: ctx)
        }
    }

    /// Draws `line` with its baseline at `origin` in this flipped view: CoreText draws
    /// bottom-up, so the text matrix is un-flipped around the baseline (color emoji included).
    private func drawLine(_ line: CTLine, at origin: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: origin.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: origin.x, y: 0)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// A 3-point thumb on the viewport's trailing edge: its length is the visible share of
    /// the list, its position the scroll offset.
    private func drawScrollThumb(in viewport: CGRect, layout: CandidatePanelLayout, color: CGColor, ctx: CGContext) {
        let total = viewport.height + layout.maxVerticalScrollOffset
        guard total > 0, viewport.height > 4 else { return }
        let track = viewport.insetBy(dx: 0, dy: 2)
        let length = max(track.height * viewport.height / total, min(16, track.height))
        let progress = layout.verticalScrollOffset / layout.maxVerticalScrollOffset
        let thumb = CGRect(x: viewport.maxX - 2 - 3, y: track.minY + (track.height - length) * progress, width: 3, height: length)
        ctx.saveGState()
        ctx.setFillColor(color.copy(alpha: 0.45) ?? color)
        ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func drawChevron(in rect: CGRect, pointingUp: Bool, color: CGColor, ctx: CGContext) {
        let halfWidth: CGFloat = 4, halfHeight: CGFloat = 2.25
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let tipY = pointingUp ? center.y - halfHeight : center.y + halfHeight
        let armY = pointingUp ? center.y + halfHeight : center.y - halfHeight
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: center.x - halfWidth, y: armY))
        ctx.addLine(to: CGPoint(x: center.x, y: tipY))
        ctx.addLine(to: CGPoint(x: center.x + halfWidth, y: armY))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
