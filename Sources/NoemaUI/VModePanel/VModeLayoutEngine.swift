import CoreGraphics
import CoreText
import Foundation
import NoemaCore
import NoemaIMEShell

/// One menu cell or sub-mode row, in the panel's flipped (top-left origin) coordinates.
/// Origins are text baselines.
public struct VModeItemLayout: Sendable, Hashable {
    /// The menu cell or the row on the current page (0-based); what a click selects.
    public let index: Int
    /// Hit-test area: the capsule plus half the spacing around it.
    public let frame: CGRect
    /// The capsule drawn behind a highlighted item.
    public let pillFrame: CGRect
    public let labelOrigin: CGPoint
    public let textOrigin: CGPoint
    public let displayLabel: String
    /// The text, truncated with "…" when wider than its cell.
    public let displayText: String
    public let isEmoji: Bool
    public let isHighlighted: Bool
    /// An agent action that ships in a later milestone: drawn dimmed, still selectable.
    public let isDimmed: Bool
}

/// The title strip of a sub-mode: title at the leading edge, page info at the trailing
/// edge, and the query hint on its own line below.
public struct VModeHeaderLayout: Sendable, Hashable {
    public let frame: CGRect
    public let title: String
    public let titleOrigin: CGPoint
    public let pageInfo: String?
    public let pageInfoOrigin: CGPoint?
    public let hint: String?
    public let hintOrigin: CGPoint?
    /// The hairline between the header and the rows.
    public let dividerY: CGFloat
}

/// Everything the v-mode view draws for one `VModePanelState`. Pure values, like
/// `CandidatePanelLayout`, so it is compared, cached, and tested headlessly.
public struct VModePanelLayout: Sendable, Hashable {
    public let panelSize: CGSize
    public let cornerRadius: CGFloat
    public let isMenu: Bool
    public let preeditStrip: PreeditStripLayout?
    public let header: VModeHeaderLayout?
    public let items: [VModeItemLayout]
    public let highlightedPillFrame: CGRect?
    /// The `VModePanelState.generationID` laid out; clicks carry it to reject stale panels.
    public let generationID: UInt64
    /// The visible band of items taller than `maxHeight`; nil when everything fits. Items are
    /// shifted up by `verticalScrollOffset`; drawing, the highlight, and hit testing are
    /// clipped to it.
    public let itemsViewport: CGRect?
    public let verticalScrollOffset: CGFloat
    public let maxVerticalScrollOffset: CGFloat

    /// The item a click at `point` (flipped panel coordinates) selects, if any. Items
    /// scrolled out of `itemsViewport` are never hit.
    public func hitTest(_ point: CGPoint) -> Int? {
        if let viewport = itemsViewport, !viewport.contains(point) { return nil }
        return items.first { $0.frame.contains(point) }?.index
    }
}

/// Lays out the v-mode panel with the candidate panel's CoreText fonts and metrics.
///
/// - Menu: a 2-column grid of equal capsules in row-major order (`1 2 / 3 4 / 5 6 / 7 8 /
///   9`), each column as wide as the widest cell, cells never overlapping.
/// - Sub-mode: a header (title, page info, query hint), a hairline, then one row per item.
///
/// `maxWidth` (the screen's usable width) bounds the panel; cell and row texts truncate
/// with "…" to fit. `maxHeight` bounds it too: a taller grid or list scrolls inside
/// `itemsViewport`, following the highlighted item.
public struct VModeLayoutEngine: Sendable, Hashable {
    public let style: CandidatePanelStyle
    /// Smallest width of one menu column.
    public var minColumnWidth: CGFloat = 104
    /// Smallest width of a sub-mode panel.
    public var minSubModeWidth: CGFloat = 220

    public init(style: CandidatePanelStyle = CandidatePanelStyle()) {
        self.style = style
    }

    public func layout(
        state: VModePanelState,
        options: CandidatePresentationOptions,
        maxWidth maxWidthCap: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        verticalScrollOffset: CGFloat = 0,
        ensureHighlightVisible: Bool = true
    ) -> VModePanelLayout {
        let fonts = CandidateTypesetter.Fonts(style: style)
        let s = style
        let styleMax = max(s.maxPanelWidth, s.minPanelWidth)
        let maxWidth: CGFloat = {
            guard let cap = maxWidthCap, cap.isFinite else { return styleMax }
            return min(styleMax, max(cap, 0))
        }()
        let candidateLineHeight = fonts.candidate.ascent + fonts.candidate.descent
        let contentHeight = ceil(max(candidateLineHeight, fonts.label.ascent + fonts.label.descent))
        let pillHeight = contentHeight + 2 * s.pillVerticalInset
        let baselineInPill = s.pillVerticalInset + (contentHeight - candidateLineHeight) / 2 + fonts.candidate.ascent

        // Entries to lay out: (label, text, highlighted, dimmed).
        struct Entry { let label: String; let text: String; let dimmed: Bool }
        let entries: [Entry]
        let highlighted: Int
        var isMenu = false
        var header: (title: String, pageInfo: String?, hint: String?)?
        switch state {
        case .menu(let cells, let index, _, _):
            isMenu = true
            entries = cells.map { Entry(label: String($0.number), text: $0.title, dimmed: !$0.isAvailable) }
            highlighted = index
        case .subMode(let title, _, let hint, let rows, let index, let pageInfo, _):
            entries = rows.map { Entry(label: $0.label, text: $0.text, dimmed: false) }
            highlighted = index
            header = (title, pageInfo, hint)
        }
        let preedit = state.preedit

        func labelWidth(_ label: String) -> CGFloat { ceil(CandidateTypesetter.measure(label, font: fonts.label.font).width) }
        func textWidth(_ text: String) -> CGFloat { ceil(CandidateTypesetter.measure(text, font: fonts.candidate.font).width) }
        func itemWidth(_ entry: Entry) -> CGFloat {
            2 * s.pillHorizontalInset + labelWidth(entry.label) + s.labelGap + textWidth(entry.text)
        }

        // 1. Widths.
        let columns = isMenu ? VMenuItem.columns : 1
        var naturalItemWidth = entries.map(itemWidth).max() ?? 0
        if isMenu { naturalItemWidth = max(naturalItemWidth, minColumnWidth) }
        var headerWidth: CGFloat = 0
        if let header {
            let title = textWidth(header.title)
            let page = header.pageInfo.map { ceil(CandidateTypesetter.measure($0, font: fonts.label.font).width) + 12 } ?? 0
            let hint = header.hint.map { ceil(CandidateTypesetter.measure($0, font: fonts.comment.font).width) } ?? 0
            headerWidth = 2 * s.pillHorizontalInset + max(title + page, hint)
        }
        var stripWidth: CGFloat = 0
        if options.rendersPreeditInPanel && !preedit.isEmpty {
            let line = CandidateTypesetter.measure(preedit, font: fonts.preedit.font)
            stripWidth = 2 * s.pillHorizontalInset + ceil(line.width) + s.caretWidth
        }
        let gridWidth = CGFloat(columns) * naturalItemWidth + CGFloat(columns - 1) * s.itemSpacing
        var width = 2 * s.horizontalPadding + max(gridWidth, headerWidth, stripWidth)
        width = max(width, isMenu ? s.minPanelWidth : minSubModeWidth)
        width = ceil(min(width, maxWidth))
        let innerWidth = max(width - 2 * s.horizontalPadding, 0)
        let columnWidth = max(floor((innerWidth - CGFloat(columns - 1) * s.itemSpacing) / CGFloat(columns)), 0)

        // 2. Top-down: preedit strip, header, items.
        var y = s.verticalPadding
        var stripLayout: PreeditStripLayout?
        if options.rendersPreeditInPanel && !preedit.isEmpty {
            let height = ceil(fonts.preedit.ascent + fonts.preedit.descent) + 2 * s.preeditVerticalInset
            let frame = CGRect(x: s.horizontalPadding, y: y, width: innerWidth, height: height)
            let clip = CGRect(x: frame.minX + s.pillHorizontalInset, y: y, width: max(frame.width - 2 * s.pillHorizontalInset, 0), height: height)
            let caretX = CandidateTypesetter.caretOffset(preedit, font: fonts.preedit.font, utf16Offset: preedit.utf16.count)
            let lineWidth = CandidateTypesetter.measure(preedit, font: fonts.preedit.font).width
            let scroll = CandidateLayoutEngine.preeditScrollOffset(
                textWidth: max(lineWidth, caretX), caretX: caretX, viewport: max(clip.width - s.caretWidth, 0))
            let origin = CGPoint(x: clip.minX - scroll, y: (y + s.preeditVerticalInset + fonts.preedit.ascent).rounded())
            let caret = CGRect(
                x: clip.minX + caretX - scroll, y: y + s.preeditVerticalInset, width: s.caretWidth,
                height: ceil(fonts.preedit.ascent + fonts.preedit.descent))
            y += height
            let dividerY = y + s.dividerInset
            y += 2 * s.dividerInset
            stripLayout = PreeditStripLayout(
                frame: frame, clipRect: clip, scrollOffset: scroll, textOrigin: origin, caretRect: caret, text: preedit,
                dividerY: dividerY)
        }
        var headerLayout: VModeHeaderLayout?
        if let header {
            let top = y
            let titleBaseline = (y + s.pillVerticalInset + fonts.candidate.ascent).rounded()
            let titleText = CandidateTypesetter.fit(header.title, font: fonts.candidate.font, maxWidth: max(innerWidth - 2 * s.pillHorizontalInset - 48, 24)).text
            let pageOrigin = header.pageInfo.map { info in
                CGPoint(x: s.horizontalPadding + innerWidth - s.pillHorizontalInset - ceil(CandidateTypesetter.measure(info, font: fonts.label.font).width), y: titleBaseline)
            }
            y += pillHeight
            var hintOrigin: CGPoint?
            var hintText: String?
            if let hint = header.hint {
                hintText = CandidateTypesetter.fit(hint, font: fonts.comment.font, maxWidth: max(innerWidth - 2 * s.pillHorizontalInset, 0)).text
                hintOrigin = CGPoint(x: s.horizontalPadding + s.pillHorizontalInset, y: (y + fonts.comment.ascent).rounded())
                y += ceil(fonts.comment.ascent + fonts.comment.descent) + 2
            }
            let dividerY = y + s.dividerInset
            y += 2 * s.dividerInset
            headerLayout = VModeHeaderLayout(
                frame: CGRect(x: s.horizontalPadding, y: top, width: innerWidth, height: y - top), title: titleText,
                titleOrigin: CGPoint(x: s.horizontalPadding + s.pillHorizontalInset, y: titleBaseline),
                pageInfo: header.pageInfo, pageInfoOrigin: pageOrigin, hint: hintText, hintOrigin: hintOrigin, dividerY: dividerY)
        }

        // 3. Items, scrolled inside a viewport when taller than maxHeight.
        let firstRowY = y
        let rowCount = (entries.count + columns - 1) / columns
        let rowStride = pillHeight + s.itemSpacing
        let listHeight = rowCount == 0 ? 0 : CGFloat(rowCount) * pillHeight + CGFloat(rowCount - 1) * s.itemSpacing
        var viewport: CGRect?
        var scrollY: CGFloat = 0
        var maxScrollY: CGFloat = 0
        var visibleHeight = listHeight
        if let maxHeight, maxHeight.isFinite, rowCount > 0, ceil(firstRowY + listHeight + s.verticalPadding) > maxHeight {
            let available = floor(maxHeight - firstRowY - s.verticalPadding)
            visibleHeight = max(min(listHeight, available), min(listHeight, pillHeight))
            maxScrollY = max(listHeight - visibleHeight, 0)
            scrollY = min(max(verticalScrollOffset.isFinite ? verticalScrollOffset : 0, 0), maxScrollY)
            if ensureHighlightVisible, entries.indices.contains(highlighted) {
                let top = CGFloat(highlighted / columns) * rowStride
                if top < scrollY { scrollY = top } else if top + pillHeight > scrollY + visibleHeight { scrollY = top + pillHeight - visibleHeight }
                scrollY = min(max(scrollY, 0), maxScrollY)
            }
            if maxScrollY > 0 { viewport = CGRect(x: 0, y: firstRowY, width: width, height: visibleHeight) } else { scrollY = 0 }
        }
        var items: [VModeItemLayout] = []
        for (index, entry) in entries.enumerated() {
            let row = index / columns, column = index % columns
            let pill = CGRect(
                x: s.horizontalPadding + CGFloat(column) * (columnWidth + s.itemSpacing),
                y: firstRowY + CGFloat(row) * rowStride - scrollY, width: columnWidth, height: pillHeight)
            let label = entry.label
            let lw = labelWidth(label)
            let textBudget = max(columnWidth - 2 * s.pillHorizontalInset - lw - s.labelGap, 0)
            let fitted = CandidateTypesetter.fit(entry.text, font: fonts.candidate.font, maxWidth: textBudget)
            let isEmoji = CandidateLayoutEngine.isEmoji(entry.text)
            let baseline = (pill.minY + baselineInPill).rounded()
            let textBaseline = isEmoji
                ? (pill.minY + (pill.height - (fitted.ascent + fitted.descent)) / 2 + fitted.ascent).rounded() : baseline
            let labelX = pill.minX + s.pillHorizontalInset
            items.append(VModeItemLayout(
                index: index, frame: pill.insetBy(dx: -s.itemSpacing / 2, dy: -s.itemSpacing / 2), pillFrame: pill,
                labelOrigin: CGPoint(x: labelX, y: baseline), textOrigin: CGPoint(x: labelX + lw + s.labelGap, y: textBaseline),
                displayLabel: label, displayText: fitted.text, isEmoji: isEmoji, isHighlighted: index == highlighted,
                isDimmed: entry.dimmed))
        }
        y = firstRowY + visibleHeight
        let height = ceil(y + s.verticalPadding)
        let radius = min(s.expandedCornerRadius, floor(height / 2))
        return VModePanelLayout(
            panelSize: CGSize(width: width, height: height), cornerRadius: radius, isMenu: isMenu, preeditStrip: stripLayout,
            header: headerLayout, items: items, highlightedPillFrame: items.first(where: \.isHighlighted)?.pillFrame,
            generationID: state.generationID, itemsViewport: viewport, verticalScrollOffset: scrollY,
            maxVerticalScrollOffset: maxScrollY)
    }
}
