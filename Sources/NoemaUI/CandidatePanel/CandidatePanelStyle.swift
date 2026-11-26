import AppKit
import CoreGraphics

/// Metrics and backdrop of the candidate panel. Plain values only: fonts are created and
/// colors resolved where they are used, on the main actor, so the style stays `Sendable`.
public struct CandidatePanelStyle: Sendable, Hashable {
    /// What sits behind the candidates.
    public enum BackdropMode: String, Sendable, Hashable, Codable {
        /// `NSGlassEffectView` (Liquid Glass), no window shadow.
        case glass
        /// `NSVisualEffectView` (`.hudWindow`) with a window shadow.
        case visualEffect
    }

    public var backdropMode: BackdropMode = .glass

    // Fonts (system UI font for zh-Hans; CoreText cascades to Apple Color Emoji and Latin).
    public var candidateFontSize: CGFloat = 15
    public var labelFontSize: CGFloat = 12
    public var commentFontSize: CGFloat = 12
    public var preeditFontSize: CGFloat = 13

    // Panel padding around the candidate row(s) and the preedit strip.
    public var horizontalPadding: CGFloat = 4
    public var verticalPadding: CGFloat = 4
    /// Space between two candidate capsules.
    public var itemSpacing: CGFloat = 2
    /// Horizontal inset of a candidate's content inside its capsule.
    public var pillHorizontalInset: CGFloat = 8
    /// Vertical inset of a candidate's text inside its capsule.
    public var pillVerticalInset: CGFloat = 5
    /// Gap between a label and its candidate, and between a candidate and its comment.
    public var labelGap: CGFloat = 4
    public var commentGap: CGFloat = 5

    // Width bounds and hysteresis.
    public var minPanelWidth: CGFloat = 96
    public var maxPanelWidth: CGFloat = 720
    public var widthQuantizationStep: CGFloat = 32
    /// Widest a single candidate's text may be before it is truncated with "…".
    public var maxCandidateTextWidth: CGFloat = 280
    public var maxCommentWidth: CGFloat = 140

    // Shape.
    /// Corner radius once the panel has more than one row (expanded or with a preedit strip).
    public var expandedCornerRadius: CGFloat = 14
    /// Expand/collapse button at the trailing edge.
    public var expandButtonWidth: CGFloat = 22
    public var expandButtonGap: CGFloat = 2

    // Floating preedit strip (inline-preedit-disabled clients).
    public var preeditVerticalInset: CGFloat = 4
    public var caretWidth: CGFloat = 1.5
    public var dividerInset: CGFloat = 3

    // Placement.
    public var caretGap: CGFloat = 6
    public var screenMargin: CGFloat = 8
    public var fallbackLineHeight: CGFloat = 18

    public init() {}
}

/// The panel's colors resolved for one appearance. Built only inside
/// `NSAppearance.performAsCurrentDrawingAppearance`, so dynamic system colors turn into the
/// right light or dark `CGColor`.
@MainActor
struct CandidatePanelPalette {
    var selectionFill: CGColor
    var selectedText: CGColor
    var selectedSecondary: CGColor
    var text: CGColor
    var secondary: CGColor
    var preeditText: CGColor
    var caret: CGColor
    var divider: CGColor
    var chevron: CGColor

    static func resolve(for appearance: NSAppearance) -> CandidatePanelPalette {
        var palette: CandidatePanelPalette?
        appearance.performAsCurrentDrawingAppearance {
            palette = CandidatePanelPalette(
                selectionFill: NSColor.systemBlue.cgColor,
                selectedText: NSColor.white.cgColor,
                selectedSecondary: NSColor.white.withAlphaComponent(0.78).cgColor,
                text: NSColor.labelColor.cgColor,
                secondary: NSColor.secondaryLabelColor.cgColor,
                preeditText: NSColor.labelColor.cgColor,
                caret: NSColor.controlAccentColor.cgColor,
                divider: NSColor.separatorColor.cgColor,
                chevron: NSColor.secondaryLabelColor.cgColor
            )
        }
        // performAsCurrentDrawingAppearance runs its block synchronously exactly once.
        return palette!
    }
}
