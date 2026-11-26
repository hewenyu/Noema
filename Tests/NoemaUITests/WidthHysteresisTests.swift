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

    /// A composition moved from a wide screen to a narrow one (Codex review of PR #19): the
    /// width grown under the 720 pt style bound re-clamps to the 624 pt screen ceiling at
    /// once and never exceeds it, then grows again only within it.
    @Test func screenCeilingReClampsAWidthGrownOnAWiderScreen() {
        var h = machine()
        #expect(h.resolve(contentWidth: 700, expanded: false) == 704)
        #expect(h.resolve(contentWidth: 700, expanded: false, maxWidth: 720) == 704, "a ceiling at the style bound changes nothing")
        #expect(h.resolve(contentWidth: 700, expanded: false, maxWidth: 624) == 624, "re-clamped to the narrow screen")
        #expect(h.currentWidth == 624)
        #expect(h.resolve(contentWidth: 300, expanded: false, maxWidth: 624) == 624, "still never shrinks within the ceiling")
        #expect(h.resolve(contentWidth: 10_000, expanded: false, maxWidth: 624) == 624)
        #expect(h.resolve(contentWidth: 300, expanded: false, maxWidth: 2_000) == 624, "a wider ceiling than the style bound is ignored")
        #expect(h.resolve(contentWidth: 700, expanded: false, maxWidth: 2_000) == 704)
        // A ceiling below minWidth wins; a non-finite one is ignored.
        h.reset()
        #expect(h.resolve(contentWidth: 10, expanded: false, maxWidth: 60) == 60)
        #expect(h.resolve(contentWidth: 10, expanded: false, maxWidth: .nan) == 96)
        #expect(h.resolve(contentWidth: 10, expanded: false, maxWidth: -5) == 0)
    }

    @Test func toleratesDegenerateInputs() {
        var h = WidthHysteresis(step: 0, minWidth: -5, maxWidth: .nan)
        #expect(h.step == 1 && h.minWidth == 0 && h.maxWidth == 0)
        var g = machine()
        #expect(g.resolve(contentWidth: .nan, expanded: false) == 96)
        #expect(g.resolve(contentWidth: .infinity, expanded: false) == 96)
    }
}
