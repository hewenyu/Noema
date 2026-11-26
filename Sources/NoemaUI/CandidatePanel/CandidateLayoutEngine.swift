import CoreGraphics
import CoreText
import Foundation
import NoemaCore
import NoemaIMEShell

/// One candidate's capsule and text positions, in the panel's flipped (top-left origin)
/// coordinates. Origins are text baselines.
public struct CandidateItemLayout: Sendable, Hashable {
    public let index: Int
    /// Hit-test area: the capsule plus half the spacing around it.
    public let frame: CGRect
    /// The capsule drawn behind a highlighted candidate.
    public let pillFrame: CGRect
    public let labelOrigin: CGPoint
    public let textOrigin: CGPoint
    public let commentOrigin: CGPoint?
    public let displayLabel: String
    /// The candidate text, truncated with "…" when wider than the panel allows.
    public let displayText: String
    public let displayComment: String?
    /// The text contains an emoji-presentation scalar: centered on its own line metrics.
    public let isEmoji: Bool
    public let isHighlighted: Bool
}

/// The floating preedit drawn for inline-preedit-disabled clients.
public struct PreeditStripLayout: Sendable, Hashable {
    public let frame: CGRect
    /// The text area inside `frame`; text and caret are drawn clipped to it.
    public let clipRect: CGRect
    /// How far the text is scrolled left so the caret stays inside `clipRect` (0 when it fits).
    public let scrollOffset: CGFloat
    /// The text baseline origin, already shifted left by `scrollOffset`.
    public let textOrigin: CGPoint
    /// The caret bar at the engine's UTF-16 caret offset, always inside `clipRect`.
    public let caretRect: CGRect
    public let text: String
    /// The hairline between the strip and the candidates; nil without candidates.
    public let dividerY: CGFloat?
}

public enum CandidateHitTarget: Sendable, Hashable {
    case candidate(Int)
    case expandButton
    case none
}

/// Everything the panel view draws for one `CompositionState`. Pure values: no CoreText
/// or CoreGraphics objects, so a layout can be compared, cached, and tested headlessly.
public struct CandidatePanelLayout: Sendable, Hashable {
    public let panelSize: CGSize
    /// The width the content needs before width hysteresis; `panelSize.width` is at least this.
    public let contentWidth: CGFloat
    public let cornerRadius: CGFloat
    public let isExpanded: Bool
    public let preeditStrip: PreeditStripLayout?
    public let items: [CandidateItemLayout]
    public let highlightedPillFrame: CGRect?
    public let expandButtonFrame: CGRect?
    /// The `CompositionState.generationID` laid out; clicks carry it to reject stale panels.
    public let generationID: UInt64
    /// The visible band of an expanded list taller than `maxHeight`, full panel width, in
    /// flipped panel coordinates; nil when every candidate fits. Items are shifted up by
    /// `verticalScrollOffset`; drawing, the highlight, and hit testing are clipped to it.
    public let candidatesViewport: CGRect?
    /// How far the expanded list is scrolled, in `0...maxVerticalScrollOffset`.
    public let verticalScrollOffset: CGFloat
    /// The list height hidden below the viewport at offset 0; 0 when nothing scrolls.
    public let maxVerticalScrollOffset: CGFloat

    /// What a click at `point` (flipped panel coordinates) hits. Candidates scrolled out of
    /// `candidatesViewport` are never hit, even where their shifted frames lie.
    public func hitTest(_ point: CGPoint) -> CandidateHitTarget {
        if let button = expandButtonFrame, button.insetBy(dx: -2, dy: -2).contains(point) { return .expandButton }
        if let viewport = candidatesViewport, !viewport.contains(point) { return .none }
        if let item = items.first(where: { $0.frame.contains(point) }) { return .candidate(item.index) }
        return .none
    }
}

/// Lays out the candidate panel with CoreText measurements. Single-row (collapsed, no
/// preedit strip) panels are capsules: the corner radius is half the height. Expanded
/// panels list one candidate per row; any multi-row panel uses `expandedCornerRadius`.
/// The expand button is pinned to the trailing edge of the hysteresis width, so the slack
/// sits between the last candidate and the button. A page whose single row cannot fit in
/// `maxPanelWidth` even after truncation is always laid out expanded, without the button.
/// An expanded list taller than `maxHeight` (the screen's visible height) shows a scrolled
/// viewport instead, which by default follows the highlighted candidate.
public struct CandidateLayoutEngine: Sendable {
    public let style: CandidatePanelStyle

    public init(style: CandidatePanelStyle = CandidatePanelStyle()) {
        self.style = style
    }

    /// Lays out `state` without hysteresis (a fresh state machine): for tests and previews.
    public func layout(
        state: CompositionState,
        options: CandidatePresentationOptions,
        expanded: Bool,
        maxHeight: CGFloat? = nil,
        verticalScrollOffset: CGFloat = 0,
        ensureHighlightVisible: Bool = true
    ) -> CandidatePanelLayout {
        var hysteresis = WidthHysteresis(style: style)
        return layout(
            state: state, options: options, expanded: expanded, hysteresis: &hysteresis, maxHeight: maxHeight,
            verticalScrollOffset: verticalScrollOffset, ensureHighlightVisible: ensureHighlightVisible)
    }

    /// `maxHeight` bounds an expanded panel's height (nil: unbounded). When the list does
    /// not fit, it scrolls by `verticalScrollOffset` (clamped); `ensureHighlightVisible`
    /// then scrolls the least amount that shows the whole highlighted candidate.
    public func layout(
        state: CompositionState,
        options: CandidatePresentationOptions,
        expanded: Bool,
        hysteresis: inout WidthHysteresis,
        maxHeight: CGFloat? = nil,
        verticalScrollOffset: CGFloat = 0,
        ensureHighlightVisible: Bool = true
    ) -> CandidatePanelLayout {
        let fonts = CandidateTypesetter.Fonts(style: style)
        let s = style
        let candidateLineHeight = fonts.candidate.ascent + fonts.candidate.descent
        let contentHeight = ceil(max(candidateLineHeight, fonts.label.ascent + fonts.label.descent))
        let pillHeight = contentHeight + 2 * s.pillVerticalInset
        let baselineInPill = s.pillVerticalInset + (contentHeight - candidateLineHeight) / 2 + fonts.candidate.ascent
        let hasCandidates = !state.candidates.isEmpty
        let maxWidth = max(s.maxPanelWidth, s.minPanelWidth)

        // 1. Measure every candidate.
        let originalMeasured = state.candidates.enumerated().map { index, item in
            MeasuredItem(index: index, item: item, fonts: fonts, style: s)
        }

        // 2. Fit the page into one row within maxPanelWidth (with room for the button):
        //    drop comments, then truncate text to a common cap, then re-measure. Labels,
        //    insets, spacing, and the "…" itself never shrink, so a large page (Rime
        //    `menu/page_size: 20`) can still overflow; such a page cannot collapse.
        let collapsedFixed = 2 * s.horizontalPadding + (hasCandidates ? s.expandButtonGap + s.expandButtonWidth : 0)
        func rowWidth(_ items: [MeasuredItem]) -> CGFloat {
            collapsedFixed + items.reduce(0) { $0 + $1.width } + s.itemSpacing * CGFloat(max(items.count - 1, 0))
        }
        var collapsedMeasured = originalMeasured
        if rowWidth(collapsedMeasured) > maxWidth {
            for i in collapsedMeasured.indices { collapsedMeasured[i].dropComment() }
        }
        let overflow = rowWidth(collapsedMeasured) - maxWidth
        if overflow > 0 {
            let textBudget = collapsedMeasured.reduce(0) { $0 + $1.textWidth } - overflow
            let cap = Self.waterLevel(collapsedMeasured.map(\.textWidth), budget: textBudget)
            for i in collapsedMeasured.indices { collapsedMeasured[i].truncate(toTextWidth: cap, font: fonts.candidate.font) }
        }
        let canCollapse = !hasCandidates || rowWidth(collapsedMeasured) <= maxWidth

        // A page that cannot collapse is laid out expanded, without the (dead) button.
        let effectiveExpanded = expanded || !canCollapse
        let showExpandButton = hasCandidates && canCollapse
        let buttonArea = showExpandButton ? s.expandButtonGap + s.expandButtonWidth : 0
        let fixed = 2 * s.horizontalPadding + buttonArea
        var measured: [MeasuredItem]
        if effectiveExpanded {
            // Expanded rows start from the untruncated measurements; each row fits on its own.
            measured = originalMeasured
            for i in measured.indices where fixed + measured[i].width > maxWidth {
                measured[i].dropComment()
                let cap = maxWidth - fixed - (measured[i].width - measured[i].textWidth)
                measured[i].truncate(toTextWidth: cap, font: fonts.candidate.font)
            }
        } else {
            measured = collapsedMeasured
        }

        // 3. Measure the preedit strip.
        var strip: (line: CandidateTypesetter.Measured, caretX: CGFloat, height: CGFloat)?
        if options.rendersPreeditInPanel && !state.preedit.isEmpty {
            let line = CandidateTypesetter.measure(state.preedit, font: fonts.preedit.font)
            let caretX = CandidateTypesetter.caretOffset(state.preedit, font: fonts.preedit.font, utf16Offset: state.caretUTF16Offset)
            let height = ceil(fonts.preedit.ascent + fonts.preedit.descent) + 2 * s.preeditVerticalInset
            strip = (line, caretX, height)
        }

        // 4. Content width, then the hysteresis width.
        var contentWidth: CGFloat
        if effectiveExpanded {
            contentWidth = fixed + (measured.map(\.width).max() ?? 0)
        } else {
            contentWidth = fixed + measured.reduce(0) { $0 + $1.width } + s.itemSpacing * CGFloat(max(measured.count - 1, 0))
        }
        if let strip {
            let stripWidth = 2 * s.horizontalPadding + 2 * s.pillHorizontalInset + max(strip.line.width, strip.caretX) + s.caretWidth
            contentWidth = max(contentWidth, min(stripWidth, maxWidth))
        }
        contentWidth = ceil(contentWidth)
        let width = hysteresis.resolve(contentWidth: contentWidth, expanded: effectiveExpanded)

        // 5. Position, top-down.
        var y = s.verticalPadding
        var stripLayout: PreeditStripLayout?
        if let strip {
            let frame = CGRect(x: s.horizontalPadding, y: y, width: width - 2 * s.horizontalPadding, height: strip.height)
            let clipRect = CGRect(
                x: frame.minX + s.pillHorizontalInset, y: frame.minY,
                width: max(frame.width - 2 * s.pillHorizontalInset, 0), height: frame.height)
            let scrollOffset = Self.preeditScrollOffset(
                textWidth: max(strip.line.width, strip.caretX), caretX: strip.caretX,
                viewport: max(clipRect.width - s.caretWidth, 0))
            let origin = CGPoint(x: clipRect.minX - scrollOffset, y: (y + s.preeditVerticalInset + fonts.preedit.ascent).rounded())
            let caret = CGRect(
                x: clipRect.minX + strip.caretX - scrollOffset, y: y + s.preeditVerticalInset,
                width: s.caretWidth, height: ceil(fonts.preedit.ascent + fonts.preedit.descent))
            y += strip.height
            var dividerY: CGFloat?
            if hasCandidates {
                dividerY = y + s.dividerInset
                y += 2 * s.dividerInset
            }
            stripLayout = PreeditStripLayout(
                frame: frame, clipRect: clipRect, scrollOffset: scrollOffset, textOrigin: origin,
                caretRect: caret, text: state.preedit, dividerY: dividerY)
        }

        let firstRowY = y
        // An expanded list taller than `maxHeight` scrolls inside a viewport.
        var viewport: CGRect?
        var scrollY: CGFloat = 0
        var maxScrollY: CGFloat = 0
        var viewportHeight: CGFloat?
        let rowStride = pillHeight + s.itemSpacing
        if effectiveExpanded && hasCandidates, let maxHeight, maxHeight.isFinite {
            let totalListHeight = CGFloat(measured.count) * pillHeight + CGFloat(max(measured.count - 1, 0)) * s.itemSpacing
            if ceil(firstRowY + totalListHeight + s.verticalPadding) > maxHeight {
                let available = floor(maxHeight - firstRowY - s.verticalPadding)
                let visible = max(min(totalListHeight, available), min(totalListHeight, pillHeight))
                maxScrollY = max(totalListHeight - visible, 0)
                scrollY = min(max(verticalScrollOffset.isFinite ? verticalScrollOffset : 0, 0), maxScrollY)
                if ensureHighlightVisible, let highlightedIndex = state.highlightedIndex,
                   measured.indices.contains(highlightedIndex) {
                    let itemTop = CGFloat(highlightedIndex) * rowStride
                    let itemBottom = itemTop + pillHeight
                    if itemTop < scrollY {
                        scrollY = itemTop
                    } else if itemBottom > scrollY + visible {
                        scrollY = itemBottom - visible
                    }
                    scrollY = min(max(scrollY, 0), maxScrollY)
                }
                viewportHeight = visible
                if maxScrollY > 0 {
                    viewport = CGRect(x: 0, y: firstRowY, width: width, height: visible)
                } else {
                    scrollY = 0
                }
            }
        }
        var items: [CandidateItemLayout] = []
        var x = s.horizontalPadding
        let expandedPillWidth = width - fixed
        for (position, item) in measured.enumerated() {
            let pill: CGRect
            if effectiveExpanded {
                pill = CGRect(x: s.horizontalPadding, y: y - scrollY, width: expandedPillWidth, height: pillHeight)
                y += pillHeight + (position == measured.count - 1 ? 0 : s.itemSpacing)
            } else {
                pill = CGRect(x: x, y: y, width: item.width, height: pillHeight)
                x += item.width + s.itemSpacing
            }
            items.append(item.layout(
                pill: pill, baselineInPill: baselineInPill, style: s,
                highlighted: state.highlightedIndex == item.index))
        }
        if hasCandidates && !effectiveExpanded { y += pillHeight }
        if let viewportHeight { y = firstRowY + viewportHeight }

        let height = ceil(y + s.verticalPadding)
        let isCapsule = !effectiveExpanded && stripLayout == nil
        let radius = isCapsule ? floor(height / 2) : min(s.expandedCornerRadius, floor(height / 2))
        let button = showExpandButton
            ? CGRect(x: width - s.horizontalPadding - s.expandButtonWidth, y: firstRowY, width: s.expandButtonWidth, height: pillHeight)
            : nil
        let highlighted = items.first(where: \.isHighlighted)?.pillFrame
        return CandidatePanelLayout(
            panelSize: CGSize(width: width, height: height), contentWidth: contentWidth, cornerRadius: radius,
            isExpanded: effectiveExpanded, preeditStrip: stripLayout, items: items, highlightedPillFrame: highlighted,
            expandButtonFrame: button, generationID: state.generationID, candidatesViewport: viewport,
            verticalScrollOffset: scrollY, maxVerticalScrollOffset: maxScrollY)
    }

    /// How far to scroll a floating preedit of `textWidth` so the caret at `caretX` stays in
    /// `[0, viewport]`: 0 while the caret is left of the trailing margin, otherwise just
    /// enough to put it at the margin, never past the end of the text. Since
    /// `caretX <= textWidth`, the scrolled caret is always within `[0, viewport]`.
    static func preeditScrollOffset(textWidth: CGFloat, caretX: CGFloat, viewport: CGFloat) -> CGFloat {
        let maxScroll = max(textWidth - viewport, 0)
        guard maxScroll > 0 else { return 0 }
        let margin = min(24, viewport * 0.25)
        guard caretX > viewport - margin else { return 0 }
        return min(maxScroll, max(caretX - (viewport - margin), 0))
    }

    /// The largest cap `c` with `sum(min(w, c)) <= budget` (water-filling), never below 0.
    static func waterLevel(_ widths: [CGFloat], budget: CGFloat) -> CGFloat {
        guard budget > 0 else { return 0 }
        let sorted = widths.sorted()
        var remaining = budget
        for (i, w) in sorted.enumerated() {
            let count = CGFloat(sorted.count - i)
            if w * count > remaining { return max(floor(remaining / count), 0) }
            remaining -= w
        }
        return sorted.last ?? 0
    }

    /// True when `text` renders as an emoji: an emoji-presentation scalar or VS16.
    public static func isEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
    }
}

/// One candidate measured with CoreText (widths rounded up to whole points).
private struct MeasuredItem {
    let index: Int
    let label: String
    var text: String
    var textWidth: CGFloat
    var textAscent: CGFloat
    var textDescent: CGFloat
    var comment: String?
    var commentWidth: CGFloat
    let labelWidth: CGFloat
    let isEmoji: Bool
    let style: CandidatePanelStyle

    init(index: Int, item: CandidateItem, fonts: CandidateTypesetter.Fonts, style: CandidatePanelStyle) {
        self.index = index
        self.style = style
        label = item.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(index + 1)
        labelWidth = ceil(CandidateTypesetter.measure(label, font: fonts.label.font).width)
        let fitted = CandidateTypesetter.fit(item.text, font: fonts.candidate.font, maxWidth: style.maxCandidateTextWidth)
        text = fitted.text
        textWidth = ceil(fitted.width)
        textAscent = fitted.ascent
        textDescent = fitted.descent
        isEmoji = CandidateLayoutEngine.isEmoji(item.text)
        if let raw = item.comment, !raw.isEmpty {
            let fittedComment = CandidateTypesetter.fit(raw, font: fonts.comment.font, maxWidth: style.maxCommentWidth)
            comment = fittedComment.text
            commentWidth = ceil(fittedComment.width)
        } else {
            comment = nil
            commentWidth = 0
        }
    }

    var width: CGFloat {
        2 * style.pillHorizontalInset + labelWidth + style.labelGap + textWidth
            + (comment == nil ? 0 : style.commentGap + commentWidth)
    }

    mutating func dropComment() {
        comment = nil
        commentWidth = 0
    }

    mutating func truncate(toTextWidth cap: CGFloat, font: CTFont) {
        guard textWidth > cap else { return }
        let fitted = CandidateTypesetter.fit(text, font: font, maxWidth: max(cap, 0))
        text = fitted.text
        textWidth = ceil(fitted.width)
        textAscent = fitted.ascent
        textDescent = fitted.descent
    }

    func layout(pill: CGRect, baselineInPill: CGFloat, style s: CandidatePanelStyle, highlighted: Bool) -> CandidateItemLayout {
        let baseline = (pill.minY + baselineInPill).rounded()
        let textBaseline: CGFloat
        if isEmoji {
            // Optical centering on the emoji line's own (taller) metrics.
            textBaseline = (pill.minY + (pill.height - (textAscent + textDescent)) / 2 + textAscent).rounded()
        } else {
            textBaseline = baseline
        }
        let labelX = pill.minX + s.pillHorizontalInset
        let textX = labelX + labelWidth + s.labelGap
        let commentOrigin = comment.map { _ in CGPoint(x: textX + textWidth + s.commentGap, y: baseline) }
        return CandidateItemLayout(
            index: index,
            frame: pill.insetBy(dx: -s.itemSpacing / 2, dy: -s.itemSpacing / 2),
            pillFrame: pill,
            labelOrigin: CGPoint(x: labelX, y: baseline),
            textOrigin: CGPoint(x: textX, y: textBaseline),
            commentOrigin: commentOrigin,
            displayLabel: label,
            displayText: text,
            displayComment: comment,
            isEmoji: isEmoji,
            isHighlighted: highlighted)
    }
}

/// CoreText fonts, lines, and measurements shared by layout and drawing, so both see the
/// same glyph widths.
enum CandidateTypesetter {
    struct FontMetrics {
        let font: CTFont
        let ascent: CGFloat
        let descent: CGFloat

        init(size: CGFloat) {
            // The system UI font for zh-Hans (PingFang SC); CoreText's cascade list covers
            // Latin, CJK extensions, and Apple Color Emoji.
            font = CTFontCreateUIFontForLanguage(.system, size, "zh-Hans" as CFString)
                ?? CTFontCreateWithName("PingFang SC" as CFString, size, nil)
            ascent = CTFontGetAscent(font)
            descent = CTFontGetDescent(font)
        }
    }

    struct Fonts {
        let candidate: FontMetrics
        let label: FontMetrics
        let comment: FontMetrics
        let preedit: FontMetrics

        init(style: CandidatePanelStyle) {
            candidate = FontMetrics(size: style.candidateFontSize)
            label = FontMetrics(size: style.labelFontSize)
            comment = FontMetrics(size: style.commentFontSize)
            preedit = FontMetrics(size: style.preeditFontSize)
        }
    }

    struct Measured {
        let text: String
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    static func line(_ text: String, font: CTFont, color: CGColor? = nil) -> CTLine {
        var attributes: [CFString: Any] = [kCTFontAttributeName: font]
        if let color { attributes[kCTForegroundColorAttributeName] = color }
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(string)
    }

    static func measure(_ text: String, font: CTFont) -> Measured {
        let line = line(text, font: font)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return Measured(text: text, width: width, ascent: ascent, descent: descent)
    }

    /// The x offset of the caret before UTF-16 offset `utf16Offset` of `text`.
    static func caretOffset(_ text: String, font: CTFont, utf16Offset: Int) -> CGFloat {
        let line = line(text, font: font)
        let index = min(max(utf16Offset, 0), text.utf16.count)
        return CTLineGetOffsetForStringIndex(line, CFIndex(index), nil)
    }

    /// `text`, or its longest grapheme-cluster prefix plus "…", that fits in `maxWidth`.
    /// Never splits a ZWJ emoji sequence or a combining mark.
    static func fit(_ text: String, font: CTFont, maxWidth: CGFloat) -> Measured {
        let full = measure(text, font: font)
        guard full.width > maxWidth else { return full }
        let characters = Array(text)
        var best = measure("…", font: font)
        var low = 1, high = characters.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = measure(String(characters[0..<mid]) + "…", font: font)
            if candidate.width <= maxWidth {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}
