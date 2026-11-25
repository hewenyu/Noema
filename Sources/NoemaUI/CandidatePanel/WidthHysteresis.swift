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

    /// The panel width for content `contentWidth` wide in `expanded` mode.
    public mutating func resolve(contentWidth: CGFloat, expanded: Bool) -> CGFloat {
        if mode != expanded {
            currentWidth = 0
            mode = expanded
        }
        let width = contentWidth.isFinite ? contentWidth : minWidth
        let clamped = min(max(width, minWidth), maxWidth)
        let quantized = min(maxWidth, (clamped / step).rounded(.up) * step)
        currentWidth = max(currentWidth, quantized)
        return currentWidth
    }

    public mutating func reset() {
        currentWidth = 0
        mode = nil
    }
}
