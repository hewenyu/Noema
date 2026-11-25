import CoreGraphics
import NoemaCore
import NoemaIMEShell
import NoemaUI
import Testing

/// The panel layout measured with real CoreText fonts, headlessly.
@Suite struct CandidateLayoutEngineTests {
    let style = CandidatePanelStyle()
    var engine: CandidateLayoutEngine { CandidateLayoutEngine(style: style) }

    private func state(
        _ texts: [String], comments: [String?]? = nil, preedit: String = "nihao", caret: Int? = nil,
        highlighted: Int = 0, generation: UInt64 = 7
    ) -> CompositionState {
        let items = texts.enumerated().map { i, text in
            CandidateItem(text: text, comment: comments?[i] ?? nil, label: String(i + 1))
        }
        return CompositionState(
            preedit: preedit, caretUTF16Offset: caret ?? preedit.utf16.count, candidates: items,
            highlightedIndex: highlighted, isComposing: true, generationID: generation)
    }

    private let inline = CandidatePresentationOptions()
    private let floating = CandidatePresentationOptions(rendersPreeditInPanel: true)

    // MARK: Shape

    @Test func singleRowIsACapsuleWithTheButtonOnTheTrailingEdge() throws {
        let layout = engine.layout(state: state(["你好", "拟好", "你", "尼", "泥"]), options: inline, expanded: false)
        #expect(layout.cornerRadius == (layout.panelSize.height / 2).rounded(.down))
        #expect(layout.preeditStrip == nil && !layout.isExpanded)
        #expect(layout.items.map(\.index) == [0, 1, 2, 3, 4])
        for (a, b) in zip(layout.items, layout.items.dropFirst()) {
            #expect(a.pillFrame.maxX < b.pillFrame.minX, "capsules do not overlap")
            #expect(a.pillFrame.minY == b.pillFrame.minY, "one row")
        }
        let button = try #require(layout.expandButtonFrame)
        #expect(button.maxX == layout.panelSize.width - style.horizontalPadding)
        #expect(try #require(layout.items.last).pillFrame.maxX <= button.minX)
        #expect(layout.panelSize.width.truncatingRemainder(dividingBy: style.widthQuantizationStep) == 0)
        #expect(layout.panelSize.width >= layout.contentWidth)
        #expect(layout.highlightedPillFrame == layout.items[0].pillFrame && layout.items[0].isHighlighted)
        #expect(layout.generationID == 7)
        // Text sits inside its capsule, label first.
        for item in layout.items {
            #expect(item.pillFrame.contains(item.labelOrigin) && item.pillFrame.contains(item.textOrigin))
            #expect(item.labelOrigin.x < item.textOrigin.x)
        }
    }

    @Test func expandedListUsesTheBoundedCornerRadius() throws {
        let layout = engine.layout(state: state(["你好", "拟好", "你", "尼", "泥"], highlighted: 2), options: inline, expanded: true)
        #expect(layout.isExpanded && layout.cornerRadius == style.expandedCornerRadius)
        #expect(layout.panelSize.height > 5 * layout.items[0].pillFrame.height)
        for (a, b) in zip(layout.items, layout.items.dropFirst()) {
            #expect(a.pillFrame.maxY <= b.pillFrame.minY, "one candidate per row")
            #expect(a.pillFrame.width == b.pillFrame.width)
        }
        let button = try #require(layout.expandButtonFrame)
        #expect(button.maxX == layout.panelSize.width - style.horizontalPadding)
        #expect(layout.highlightedPillFrame == layout.items[2].pillFrame)
    }

    @Test func floatingPreeditStripPlacesTheCaretWithCoreText() throws {
        let start = try #require(engine.layout(state: state(["你好"], caret: 0), options: floating, expanded: false).preeditStrip)
        let middle = try #require(engine.layout(state: state(["你好"], caret: 2), options: floating, expanded: false).preeditStrip)
        let full = engine.layout(state: state(["你好"]), options: floating, expanded: false)
        let end = try #require(full.preeditStrip)
        #expect(start.caretRect.minX == start.textOrigin.x)
        #expect(start.caretRect.minX < middle.caretRect.minX && middle.caretRect.minX < end.caretRect.minX)
        #expect(end.caretRect.maxX <= end.frame.maxX)
        #expect(end.text == "nihao" && end.dividerY != nil)
        #expect(full.cornerRadius == style.expandedCornerRadius, "two rows are not a capsule")
        #expect(try #require(full.items.first).pillFrame.minY > end.frame.maxY)

        // Preedit with no candidates: just the strip, no button.
        let bare = engine.layout(state: state([], preedit: "xq"), options: floating, expanded: false)
        #expect(bare.items.isEmpty && bare.expandButtonFrame == nil && bare.preeditStrip?.dividerY == nil)
        #expect(engine.layout(state: state(["你好"]), options: inline, expanded: false).preeditStrip == nil)
    }

    // MARK: Clamping, emoji

    @Test func longCandidatesAreTruncatedWithinTheMaximumWidth() throws {
        let long = String(repeating: "很长的候选词", count: 30)
        let one = engine.layout(state: state([long, "短"]), options: inline, expanded: false)
        #expect(one.panelSize.width <= style.maxPanelWidth)
        #expect(one.items[0].displayText.hasSuffix("…") && one.items[1].displayText == "短")
        let many = engine.layout(
            state: state(Array(repeating: String(repeating: "候选", count: 20), count: 5), comments: Array(repeating: "comment", count: 5)),
            options: inline, expanded: false)
        #expect(many.contentWidth <= style.maxPanelWidth && many.panelSize.width <= style.maxPanelWidth)
        let lastPill = try #require(many.items.last).pillFrame
        let manyButton = try #require(many.expandButtonFrame)
        #expect(lastPill.maxX <= manyButton.minX)
        let expanded = engine.layout(state: state([long]), options: inline, expanded: true)
        #expect(expanded.panelSize.width <= style.maxPanelWidth)
    }

    @Test func emojiCandidatesAreDetectedAndNeverSplit() throws {
        #expect(CandidateLayoutEngine.isEmoji("😀") && CandidateLayoutEngine.isEmoji("❤️"))
        #expect(CandidateLayoutEngine.isEmoji("👨‍👩‍👧‍👦") && !CandidateLayoutEngine.isEmoji("你好") && !CandidateLayoutEngine.isEmoji("1"))
        let family = "👨‍👩‍👧‍👦"
        let layout = engine.layout(state: state(["你好", "😀", String(repeating: family, count: 40)]), options: inline, expanded: false)
        #expect(layout.items[1].isEmoji && !layout.items[0].isEmoji)
        let truncated = layout.items[2].displayText
        #expect(truncated.hasSuffix("…"))
        #expect(truncated.dropLast().allSatisfy { String($0) == family }, "ZWJ sequences stay whole")
        // The emoji is vertically inside its capsule like the Han text.
        let pill = layout.items[1].pillFrame
        #expect(layout.items[1].textOrigin.y > pill.minY && layout.items[1].textOrigin.y < pill.maxY)
    }

    // MARK: Hit testing, hysteresis

    @Test func hitTestFindsCandidatesAndTheButton() throws {
        let layout = engine.layout(state: state(["你好", "拟好", "你"]), options: inline, expanded: false)
        let pill = layout.items[2].pillFrame
        #expect(layout.hitTest(CGPoint(x: pill.midX, y: pill.midY)) == .candidate(2))
        let button = try #require(layout.expandButtonFrame)
        #expect(layout.hitTest(CGPoint(x: button.midX, y: button.midY)) == .expandButton)
        #expect(layout.hitTest(CGPoint(x: -10, y: -10)) == .none)
        let expanded = engine.layout(state: state(["你好", "拟好", "你"]), options: inline, expanded: true)
        let row = expanded.items[1].pillFrame
        #expect(expanded.hitTest(CGPoint(x: row.minX + 10, y: row.midY)) == .candidate(1))
    }

    /// Typing a longer then a shorter composition keeps the panel width; the button stays
    /// on the trailing edge of the wider panel.
    @Test func hysteresisKeepsTheWidthWhileTyping() throws {
        var hysteresis = WidthHysteresis(style: style)
        let wide = engine.layout(
            state: state(["你好世界", "你好", "拟好", "你", "尼"]), options: inline, expanded: false, hysteresis: &hysteresis)
        let narrow = engine.layout(state: state(["你", "尼"]), options: inline, expanded: false, hysteresis: &hysteresis)
        #expect(narrow.contentWidth < wide.contentWidth)
        #expect(narrow.panelSize.width == wide.panelSize.width)
        #expect(try #require(narrow.expandButtonFrame).maxX == narrow.panelSize.width - style.horizontalPadding)
        hysteresis.reset()
        let fresh = engine.layout(state: state(["你", "尼"]), options: inline, expanded: false, hysteresis: &hysteresis)
        #expect(fresh.panelSize.width < wide.panelSize.width)
        #expect(fresh.panelSize.height == wide.panelSize.height, "height never depends on the text")
    }
}
