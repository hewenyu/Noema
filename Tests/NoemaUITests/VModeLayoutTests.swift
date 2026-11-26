import AppKit
import CoreGraphics
import NoemaCore
import NoemaIMEShell
import NoemaUI
import Testing

/// The v-mode panel layout measured with real CoreText fonts, headlessly, and the real
/// `VModePanelView` turning mouse events into generation-bound selections.
@Suite struct VModeLayoutTests {
    let style = CandidatePanelStyle()
    var engine: VModeLayoutEngine { VModeLayoutEngine(style: style) }
    let inline = CandidatePresentationOptions()

    func menu(highlighted: Int = 0, generation: UInt64 = 3) -> VModePanelState {
        .menu(items: VModeMenuCell.all, highlightedIndex: highlighted, preedit: "v", generationID: generation)
    }

    func list(_ count: Int, highlighted: Int = 0, text: (Int) -> String = { "常用语 \($0)" }) -> VModePanelState {
        .subMode(
            title: "常用语", preedit: "v3", queryHint: "输入字母筛选",
            rows: (0..<count).map { VModeSubRow(label: String($0 + 1), text: text($0)) }, highlightedIndex: highlighted,
            pageInfo: "1/2", generationID: 9)
    }

    @Test func menuIsATwoColumnGridOfNineNonOverlappingCells() throws {
        let layout = engine.layout(state: menu(highlighted: 4), options: inline)
        #expect(layout.isMenu && layout.header == nil && layout.preeditStrip == nil && layout.generationID == 3)
        #expect(layout.items.map(\.index) == Array(0..<9))
        #expect(layout.items.map(\.displayLabel) == (1...9).map(String.init))
        #expect(layout.items.map(\.displayText) == VMenuItem.allCases.map(\.title))
        let left = layout.items.filter { $0.index % 2 == 0 }
        let right = layout.items.filter { $0.index % 2 == 1 }
        #expect(Set(left.map(\.frame.minX)).count == 1 && Set(right.map(\.frame.minX)).count == 1, "two aligned columns")
        #expect(Set(layout.items.map(\.frame.width)).count == 1, "equal cells")
        #expect(left[0].frame.maxX <= right[0].frame.minX)
        for row in 0..<4 {
            #expect(layout.items[2 * row].frame.minY == layout.items[2 * row + 1].frame.minY, "row \(row)")
            #expect(layout.items[2 * row].frame.maxY <= layout.items[2 * row + 2].frame.minY)
        }
        for a in layout.items {
            #expect(a.pillFrame.minX >= 0 && a.pillFrame.maxX <= layout.panelSize.width && a.pillFrame.maxY <= layout.panelSize.height)
            for b in layout.items where b.index > a.index { #expect(!a.pillFrame.intersects(b.pillFrame), "\(a.index)/\(b.index)") }
            #expect(layout.hitTest(CGPoint(x: a.pillFrame.midX, y: a.pillFrame.midY)) == a.index)
        }
        #expect(layout.highlightedPillFrame == layout.items[4].pillFrame && layout.items[4].isHighlighted)
        // Agent actions that ship later are dimmed; the clipboard (v2), settings, and the
        // offline tools are not.
        #expect(layout.items.filter(\.isDimmed).map(\.index) == [3, 5, 6])
        #expect(layout.hitTest(CGPoint(x: -5, y: -5)) == nil)
        #expect(layout.itemsViewport == nil && layout.maxVerticalScrollOffset == 0)
    }

    @Test func panelPreeditAddsAStripAboveTheGrid() throws {
        let layout = engine.layout(state: menu(), options: CandidatePresentationOptions(rendersPreeditInPanel: true))
        let strip = try #require(layout.preeditStrip)
        #expect(strip.text == "v")
        #expect(layout.items.allSatisfy { $0.frame.minY >= strip.frame.maxY })
    }

    @Test func subModeHasAHeaderThenOneRowPerItem() throws {
        let layout = engine.layout(state: list(5, highlighted: 2), options: inline)
        #expect(!layout.isMenu && layout.generationID == 9)
        let header = try #require(layout.header)
        #expect(header.title == "常用语" && header.pageInfo == "1/2" && header.hint == "输入字母筛选")
        #expect(layout.items.count == 5 && layout.items.map(\.displayLabel) == ["1", "2", "3", "4", "5"])
        #expect(layout.items.allSatisfy { $0.frame.minY >= header.dividerY })
        for (a, b) in zip(layout.items, layout.items.dropFirst()) {
            #expect(a.frame.maxY <= b.frame.minY && a.frame.minX == b.frame.minX, "one column")
        }
        #expect(layout.panelSize.width >= engine.minSubModeWidth)
        #expect(layout.highlightedPillFrame == layout.items[2].pillFrame)
        let empty = engine.layout(state: list(0), options: inline)
        #expect(empty.items.isEmpty && empty.highlightedPillFrame == nil && empty.header != nil)
    }

    @Test func narrowScreensTruncateInsteadOfOverflowing() {
        let long = list(3) { _ in String(repeating: "很长的常用语", count: 30) }
        let layout = engine.layout(state: long, options: inline, maxWidth: 300)
        #expect(layout.panelSize.width <= 300)
        for item in layout.items {
            #expect(item.pillFrame.maxX <= layout.panelSize.width && item.displayText.hasSuffix("…"), "\(item.displayText)")
        }
        let grid = engine.layout(state: menu(), options: inline, maxWidth: 150)
        #expect(grid.panelSize.width <= 150)
        for a in grid.items {
            #expect(a.pillFrame.maxX <= grid.panelSize.width)
            for b in grid.items where b.index > a.index { #expect(!a.pillFrame.intersects(b.pillFrame)) }
        }
    }

    @Test func shortScreensScrollTheItemsAndFollowTheHighlight() throws {
        let full = engine.layout(state: menu(), options: inline)
        let bound = full.panelSize.height * 0.6
        let top = engine.layout(state: menu(highlighted: 0), options: inline, maxHeight: bound)
        #expect(top.panelSize.height <= bound)
        let viewport = try #require(top.itemsViewport)
        #expect(top.maxVerticalScrollOffset > 0 && top.verticalScrollOffset == 0)
        #expect(viewport.contains(top.items[0].pillFrame))
        let hidden = try #require(top.items.last)
        #expect(top.hitTest(CGPoint(x: hidden.pillFrame.midX, y: hidden.pillFrame.midY)) == nil, "scrolled out of view")

        let bottom = engine.layout(state: menu(highlighted: 8), options: inline, maxHeight: bound)
        let scrolled = try #require(bottom.itemsViewport)
        #expect(bottom.verticalScrollOffset > 0 && scrolled.contains(bottom.items[8].pillFrame))
        #expect(bottom.hitTest(CGPoint(x: bottom.items[8].pillFrame.midX, y: bottom.items[8].pillFrame.midY)) == 8)
    }

    /// The real view: a press and release on one item fire once with the generation shown;
    /// a refresh to another generation between them cancels the click.
    @MainActor
    @Test func clicksAreBoundToTheGenerationShown() throws {
        let view = VModePanelView(style: style)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        var fired: [(Int, UInt64)] = []
        view.onSelectItem = { fired.append(($0, $1)) }
        let first = engine.layout(state: menu(generation: 3), options: inline)
        view.frame = CGRect(origin: .zero, size: first.panelSize)
        view.apply(first)

        func click(_ index: Int, refreshingTo refresh: VModePanelLayout? = nil) throws {
            let pill = try #require(view.panelLayout?.items[index].pillFrame)
            let point = view.convert(CGPoint(x: pill.midX, y: pill.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                if type == .leftMouseDown {
                    view.mouseDown(with: event)
                    if let refresh { view.apply(refresh) }
                } else {
                    view.mouseUp(with: event)
                }
            }
        }
        try click(4)
        #expect(fired.map(\.0) == [4] && fired.map(\.1) == [3])
        try click(2, refreshingTo: engine.layout(state: menu(highlighted: 1, generation: 4), options: inline))
        #expect(fired.count == 1, "the panel changed under the press")
        try click(2)
        #expect(fired.map(\.0) == [4, 2] && fired.last?.1 == 4)
        view.reset()
        #expect(view.panelLayout == nil)
    }
}
