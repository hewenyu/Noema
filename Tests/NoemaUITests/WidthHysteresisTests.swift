import CoreGraphics
import NoemaUI
import Testing

/// The panel width snaps up to 32 pt tiers and never shrinks within one composition.
@Suite struct WidthHysteresisTests {
    private func machine() -> WidthHysteresis { WidthHysteresis(step: 32, minWidth: 96, maxWidth: 720) }

    @Test func quantizesUpToTheNextStepWithinBounds() {
        var h = machine()
        #expect(h.resolve(contentWidth: 100, expanded: false) == 128)
        h.reset()
        #expect(h.resolve(contentWidth: 10, expanded: false) == 96, "minWidth")
        h.reset()
        #expect(h.resolve(contentWidth: 96, expanded: false) == 96, "an exact tier stays")
        h.reset()
        #expect(h.resolve(contentWidth: 10_000, expanded: false) == 720, "maxWidth")
        var odd = WidthHysteresis(step: 32, minWidth: 0, maxWidth: 700)
        #expect(odd.resolve(contentWidth: 690, expanded: false) == 700, "a tier past maxWidth clamps to it")
    }

    @Test func neverShrinksWithinOneComposition() {
        var h = machine()
        var widths: [CGFloat] = []
        for content in [100, 180, 140, 230, 120, 96] as [CGFloat] {
            widths.append(h.resolve(contentWidth: content, expanded: false))
        }
        #expect(widths == [128, 192, 192, 256, 256, 256])
        #expect(h.currentWidth == 256)
    }

    @Test func resetAndModeChangesStartOver() {
        var h = machine()
        #expect(h.resolve(contentWidth: 300, expanded: false) == 320)
        h.reset()
        #expect(h.currentWidth == 0 && h.mode == nil)
        #expect(h.resolve(contentWidth: 100, expanded: false) == 128, "a new composition may be narrower")

        #expect(h.resolve(contentWidth: 400, expanded: true) == 416)
        #expect(h.resolve(contentWidth: 150, expanded: false) == 160, "collapsing does not keep the expanded width")
        #expect(h.resolve(contentWidth: 100, expanded: true) == 128, "re-expanding starts from its own content")
    }

    @Test func toleratesDegenerateInputs() {
        var h = WidthHysteresis(step: 0, minWidth: -5, maxWidth: .nan)
        #expect(h.step == 1 && h.minWidth == 0 && h.maxWidth == 0)
        var g = machine()
        #expect(g.resolve(contentWidth: .nan, expanded: false) == 96)
        #expect(g.resolve(contentWidth: .infinity, expanded: false) == 96)
    }
}
