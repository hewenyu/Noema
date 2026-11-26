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

    /// A floating preedit wider than `maxPanelWidth` scrolls horizontally inside its clip
    /// rect: the caret is always visible and never drawn past the panel edge.
    @Test func overflowingFloatingPreeditScrollsToKeepTheCaretVisible() throws {
        let preedit = String(repeating: "nihao ", count: 30)
        let length = preedit.utf16.count
        func strip(caret: Int) throws -> (CandidatePanelLayout, PreeditStripLayout) {
            let layout = engine.layout(state: state(["你好"], preedit: preedit, caret: caret), options: floating, expanded: false)
            return (layout, try #require(layout.preeditStrip))
        }
        func expectInside(_ layout: CandidatePanelLayout, _ strip: PreeditStripLayout) {
            #expect(strip.caretRect.minX >= strip.clipRect.minX, "caret \(strip.caretRect) clip \(strip.clipRect)")
            #expect(strip.caretRect.maxX <= strip.clipRect.maxX, "caret \(strip.caretRect) clip \(strip.clipRect)")
            #expect(strip.clipRect.maxX <= layout.panelSize.width)
            #expect(layout.panelSize.width <= style.maxPanelWidth)
            #expect(strip.textOrigin.x == strip.clipRect.minX - strip.scrollOffset)
        }

        let (endLayout, end) = try strip(caret: length)
        #expect(end.scrollOffset > 0)
        expectInside(endLayout, end)

        let (middleLayout, middle) = try strip(caret: length / 2)
        expectInside(middleLayout, middle)
        #expect(middle.scrollOffset <= end.scrollOffset)

        let (startLayout, start) = try strip(caret: 0)
        #expect(start.scrollOffset == 0 && start.caretRect.minX == start.clipRect.minX)
        expectInside(startLayout, start)

        // A preedit that fits never scrolls.
        let short = try #require(engine.layout(state: state(["你好"]), options: floating, expanded: false).preeditStrip)
        #expect(short.scrollOffset == 0 && short.textOrigin.x == short.clipRect.minX)
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
        #expect(!many.isExpanded, "a page that fits after truncation stays a collapsed row")
        #expect(many.contentWidth <= many.panelSize.width)
        let expanded = engine.layout(state: state([long]), options: inline, expanded: true)
        #expect(expanded.panelSize.width <= style.maxPanelWidth)
    }

    /// A 20-candidate page (Rime `menu/page_size: 20`) cannot fit one row even with every
    /// text truncated to "…": labels, insets, and spacing alone overflow. The collapsed
    /// request is laid out expanded, without a dead collapse button, every capsule inside
    /// the panel and clickable (Codex review of PR #19).
    @Test func pageTooWideForOneRowExpandsWithoutTheButton() throws {
        let texts = ["是", "时", "事情", "市场", "使用", "十分", "式样", "师傅", "世界", "施工",
                     "实现", "试验", "室内", "视频", "收到", "上海", "说明", "所以", "森林", "四个"]
        let layout = engine.layout(state: state(texts, preedit: "s"), options: inline, expanded: false)
        #expect(layout.isExpanded && layout.expandButtonFrame == nil)
        #expect(layout.items.map(\.displayText) == texts, "readable, never crushed to …")
        #expect(layout.contentWidth <= layout.panelSize.width && layout.panelSize.width <= style.maxPanelWidth)
        #expect(layout.cornerRadius == style.expandedCornerRadius)
        for item in layout.items {
            #expect(item.pillFrame.minX >= style.horizontalPadding)
            #expect(item.pillFrame.maxX <= layout.panelSize.width - style.horizontalPadding, "\(item.index): \(item.pillFrame)")
            #expect(item.pillFrame.maxY <= layout.panelSize.height)
            #expect(layout.hitTest(CGPoint(x: item.pillFrame.midX, y: item.pillFrame.midY)) == .candidate(item.index))
        }
        #expect(layout.items.map(\.index) == Array(0..<20))

        // Explicitly expanded: the same rows, still no button that could not collapse.
        let requested = engine.layout(state: state(texts, preedit: "s"), options: inline, expanded: true)
        #expect(requested.isExpanded && requested.expandButtonFrame == nil)
        #expect(requested.items.map(\.pillFrame) == layout.items.map(\.pillFrame))
    }

    /// A 50-candidate page (Rime `menu/page_size: 50`) is taller than `maxHeight`: the
    /// panel stays within it and the list scrolls inside a viewport that follows the
    /// highlight; scrolled-out candidates are never hit (Codex review of PR #19).
    @Test func listTallerThanMaxHeightScrollsInsideABoundedViewport() throws {
        let texts = (0..<50).map { "候选\($0)" }
        let natural = engine.layout(state: state(texts, preedit: "shi"), options: floating, expanded: false)
        #expect(natural.isExpanded && natural.panelSize.height > 400)
        #expect(natural.candidatesViewport == nil && natural.maxVerticalScrollOffset == 0 && natural.verticalScrollOffset == 0)
        #expect(engine.layout(state: state(texts, preedit: "shi"), options: floating, expanded: false, maxHeight: 10_000) == natural,
                "a list that fits is laid out unchanged")

        func expectInside(_ rect: CGRect?, _ layout: CandidatePanelLayout, _ step: String) throws {
            let rect = try #require(rect, "\(step)")
            let viewport = try #require(layout.candidatesViewport, "\(step)")
            #expect(viewport.contains(rect), "\(step): \(rect) outside \(viewport)")
            #expect(rect.minY >= 0 && rect.maxY <= layout.panelSize.height, "\(step)")
        }

        let top = engine.layout(state: state(texts, preedit: "shi"), options: floating, expanded: false, maxHeight: 400)
        let viewport = try #require(top.candidatesViewport)
        #expect(top.panelSize.height <= 400 && top.maxVerticalScrollOffset > 0 && top.verticalScrollOffset == 0)
        #expect(top.panelSize.width == natural.panelSize.width)
        #expect(viewport.minY == natural.items[0].pillFrame.minY && viewport.maxY <= top.panelSize.height)
        try expectInside(top.highlightedPillFrame, top, "highlight 0")
        #expect(top.highlightedPillFrame == top.items[0].pillFrame)

        // Hit testing is confined to the viewport.
        let strip = try #require(top.preeditStrip)
        #expect(top.hitTest(CGPoint(x: strip.frame.midX, y: strip.frame.midY)) == .none)
        let firstVisible = top.items[0].pillFrame
        #expect(top.hitTest(CGPoint(x: firstVisible.midX, y: firstVisible.midY)) == .candidate(0))
        let hidden = try #require(top.items.first { $0.pillFrame.minY > viewport.maxY })
        #expect(top.hitTest(CGPoint(x: hidden.pillFrame.midX, y: hidden.pillFrame.midY)) == .none)

        // Highlighting the last candidate scrolls just far enough to show it whole.
        let bottom = engine.layout(state: state(texts, preedit: "shi", highlighted: 49), options: floating, expanded: false, maxHeight: 400)
        #expect(bottom.verticalScrollOffset == bottom.maxVerticalScrollOffset)
        try expectInside(bottom.highlightedPillFrame, bottom, "highlight 49")
        #expect(bottom.highlightedPillFrame == bottom.items[49].pillFrame)
        let last = bottom.items[49].pillFrame
        #expect(bottom.hitTest(CGPoint(x: last.midX, y: last.midY)) == .candidate(49))
        // Scrolled down, a candidate's shifted frame sits just above the viewport, over the
        // preedit strip's divider: still no hit.
        let above = CGPoint(x: viewport.midX, y: viewport.minY - 1)
        #expect(bottom.items.contains { $0.frame.contains(above) }, "an item is shifted under the strip")
        #expect(bottom.hitTest(above) == .none)

        // A free scroll position is kept (clamped) without highlight tracking.
        let free = engine.layout(
            state: state(texts, preedit: "shi"), options: floating, expanded: false, maxHeight: 400,
            verticalScrollOffset: 100, ensureHighlightVisible: false)
        #expect(free.verticalScrollOffset == 100 && free.items[0].pillFrame.minY == viewport.minY - 100)
        let clamped = engine.layout(
            state: state(texts, preedit: "shi"), options: floating, expanded: false, maxHeight: 400,
            verticalScrollOffset: .infinity, ensureHighlightVisible: false)
        #expect(clamped.verticalScrollOffset == 0)
        let past = engine.layout(
            state: state(texts, preedit: "shi"), options: floating, expanded: false, maxHeight: 400,
            verticalScrollOffset: 1e6, ensureHighlightVisible: false)
        #expect(past.verticalScrollOffset == past.maxVerticalScrollOffset)
        // With tracking, a free offset that hides the highlight scrolls back to it.
        let tracked = engine.layout(
            state: state(texts, preedit: "shi"), options: floating, expanded: false, maxHeight: 400, verticalScrollOffset: 300)
        #expect(tracked.verticalScrollOffset == 0)
        // Even a tiny maxHeight shows one whole row.
        let tiny = engine.layout(state: state(texts, preedit: "shi"), options: floating, expanded: false, maxHeight: 20)
        #expect(try #require(tiny.candidatesViewport).height == tiny.items[0].pillFrame.height)
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
