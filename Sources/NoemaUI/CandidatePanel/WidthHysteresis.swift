import CoreGraphics

/// Keeps the panel width from jittering while the user types. Widths snap up to multiples
/// of `step` (clamped into `minWidth...maxWidth`) and never shrink within one composition
/// and one layout mode; `reset()` (panel hidden) and a mode change start over.
public struct WidthHysteresis: Sendable, Hashable {
    public let step: CGFloat
    public let minWidth: CGFloat
    public let maxWidth: CGFloat
    /// The width last returned; 0 after `reset()`.
    public private(set) var currentWidth: CGFloat = 0
    /// The layout mode (`expanded`) of `currentWidth`; nil after `reset()`.
    public private(set) var mode: Bool?

    public init(step: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) {
        self.step = step.isFinite ? max(step, 1) : 1
        let minimum = minWidth.isFinite ? max(minWidth, 0) : 0
        self.minWidth = minimum
        self.maxWidth = maxWidth.isFinite ? max(maxWidth, minimum) : minimum
    }

    public init(style: CandidatePanelStyle) {
        self.init(step: style.widthQuantizationStep, minWidth: style.minPanelWidth, maxWidth: style.maxPanelWidth)
    }

    /// The panel width for content `contentWidth` wide in `expanded` mode. `ceiling` (the
    /// target screen's usable width; nil: none) lowers `maxWidth` for this call and re-clamps
    /// a width grown on a wider screen, so the panel never outgrows a narrower screen.
    public mutating func resolve(contentWidth: CGFloat, expanded: Bool, maxWidth ceiling: CGFloat? = nil) -> CGFloat {
        if mode != expanded {
            currentWidth = 0
            mode = expanded
        }
        let limit: CGFloat
        if let ceiling, ceiling.isFinite {
            limit = min(maxWidth, max(ceiling, 0))
        } else {
            limit = maxWidth
        }
        let floorWidth = min(minWidth, limit)
        currentWidth = min(currentWidth, limit)
        let width = contentWidth.isFinite ? contentWidth : floorWidth
        let clamped = min(max(width, floorWidth), limit)
        let quantized = min(limit, (clamped / step).rounded(.up) * step)
        currentWidth = min(limit, max(currentWidth, quantized))
        return currentWidth
    }

    public mutating func reset() {
        currentWidth = 0
        mode = nil
    }
}
