import AppKit
import CoreText
import QuartzCore

/// Draws a `VModePanelLayout` and turns clicks into item selections.
///
/// Same rules as `CandidatePanelView`: one top-down coordinate space (`isFlipped`), a blue
/// capsule highlight in a `CAShapeLayer` updated without implicit animation, dynamic colors
/// resolved under the view's effective appearance, and generation-bound clicks: a press
/// records the item and the layout's `generationID`, a refresh to another generation cancels
/// it, and `mouseUp` fires only on the same item of the same generation.
@MainActor
public final class VModePanelView: NSView {
    /// An item was clicked: its index and the generation the panel showed.
    public var onSelectItem: (@MainActor (Int, UInt64) -> Void)?
    /// The items were scrolled: the requested `verticalScrollOffset`, with the generation.
    public var onScroll: (@MainActor (CGFloat, UInt64) -> Void)?

    public private(set) var panelLayout: VModePanelLayout?
    private let style: CandidatePanelStyle
    private let highlightHost = VModeFlippedView()
    private let highlightLayer = CAShapeLayer()
    private let highlightClipMask = CALayer()
    private let contentView: VModeContentView
    private var pressed: (index: Int, generationID: UInt64)?

    public init(style: CandidatePanelStyle) {
        self.style = style
        contentView = VModeContentView(style: style)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
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

    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        guard let superview else { return bounds.contains(point) ? self : nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override public func layout() {
        super.layout()
        syncSubviewFrames()
    }

    private func syncSubviewFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightHost.frame = bounds
        contentView.frame = bounds
        highlightLayer.frame = bounds
        if let viewport = panelLayout?.itemsViewport {
            highlightClipMask.frame = viewport
            if highlightHost.layer?.mask !== highlightClipMask { highlightHost.layer?.mask = highlightClipMask }
        } else if highlightHost.layer?.mask != nil {
            highlightHost.layer?.mask = nil
        }
        CATransaction.commit()
    }

    /// Shows `layout`; the caller sizes this view to `layout.panelSize` first.
    public func apply(_ layout: VModePanelLayout) {
        syncSubviewFrames()
        guard layout != panelLayout else { return }
        if panelLayout?.generationID != layout.generationID { pressed = nil }
        panelLayout = layout
        syncSubviewFrames()
        contentView.layout = layout
        if let pill = layout.highlightedPillFrame {
            let radius = min(pill.height / 2, max(style.expandedCornerRadius - style.horizontalPadding, 4))
            highlightLayer.path = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)
            highlightLayer.isHidden = false
        } else {
            highlightLayer.path = nil
            highlightLayer.isHidden = true
        }
        needsLayout = true
        contentView.needsDisplay = true
    }

    /// Forgets the layout and any press, e.g. when the panel hides mid-click.
    public func reset() {
        pressed = nil
        panelLayout = nil
        contentView.layout = nil
        highlightLayer.path = nil
        highlightLayer.isHidden = true
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
        guard let layout = panelLayout, let index = layout.hitTest(convert(event.locationInWindow, from: nil)) else {
            pressed = nil
            return
        }
        pressed = (index, layout.generationID)
    }

    override public func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { pressed = nil }
        guard let layout = panelLayout, let pressed, layout.generationID == pressed.generationID,
              layout.hitTest(point) == pressed.index
        else { return }
        onSelectItem?(pressed.index, pressed.generationID)
    }

    override public func scrollWheel(with event: NSEvent) {
        guard let layout = panelLayout, layout.maxVerticalScrollOffset > 0, event.momentumPhase.isEmpty else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        let target = min(max(layout.verticalScrollOffset - delta, 0), layout.maxVerticalScrollOffset)
        guard abs(target - layout.verticalScrollOffset) > 0.5 else { return }
        onScroll?(target, layout.generationID)
    }
}

private final class VModeFlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The CoreText drawing of the v-mode panel: preedit strip, header, labels, and items.
@MainActor
private final class VModeContentView: NSView {
    var layout: VModePanelLayout?
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
        let hairline = 1 / (window?.backingScaleFactor ?? 2)

        func divider(at y: CGFloat, in frame: CGRect) {
            ctx.setFillColor(palette.divider)
            ctx.fill(CGRect(x: frame.minX + style.pillHorizontalInset, y: y - hairline / 2,
                            width: max(frame.width - 2 * style.pillHorizontalInset, 0), height: hairline))
        }

        if let strip = layout.preeditStrip {
            ctx.saveGState()
            ctx.clip(to: strip.clipRect)
            draw(CandidateTypesetter.line(strip.text, font: fonts.preedit.font, color: palette.preeditText), at: strip.textOrigin, in: ctx)
            ctx.setFillColor(palette.caret)
            ctx.fill(strip.caretRect)
            ctx.restoreGState()
            if let y = strip.dividerY { divider(at: y, in: strip.frame) }
        }
        if let header = layout.header {
            draw(CandidateTypesetter.line(header.title, font: fonts.candidate.font, color: palette.text), at: header.titleOrigin, in: ctx)
            if let info = header.pageInfo, let origin = header.pageInfoOrigin {
                draw(CandidateTypesetter.line(info, font: fonts.label.font, color: palette.secondary), at: origin, in: ctx)
            }
            if let hint = header.hint, let origin = header.hintOrigin {
                draw(CandidateTypesetter.line(hint, font: fonts.comment.font, color: palette.secondary), at: origin, in: ctx)
            }
            divider(at: header.dividerY, in: header.frame)
        }
        if let viewport = layout.itemsViewport {
            ctx.saveGState()
            ctx.clip(to: viewport)
        }
        for item in layout.items where layout.itemsViewport.map({ item.pillFrame.intersects($0) }) ?? true {
            var primary = item.isHighlighted ? palette.selectedText : palette.text
            let secondary = item.isHighlighted ? palette.selectedSecondary : palette.secondary
            if item.isDimmed && !item.isHighlighted { primary = palette.secondary }
            draw(CandidateTypesetter.line(item.displayLabel, font: fonts.label.font, color: secondary), at: item.labelOrigin, in: ctx)
            draw(CandidateTypesetter.line(item.displayText, font: fonts.candidate.font, color: primary), at: item.textOrigin, in: ctx)
        }
        if layout.itemsViewport != nil { ctx.restoreGState() }
    }

    private func draw(_ line: CTLine, at origin: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: origin.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: origin.x, y: 0)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
