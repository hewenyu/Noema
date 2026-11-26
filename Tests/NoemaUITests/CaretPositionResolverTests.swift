import CoreGraphics
import NoemaUI
import Testing

/// Caret validation and panel placement on the rectangles real clients report.
@Suite struct CaretPositionResolverTests {
    /// A 1440×900 main display with a 25 pt menu bar.
    static let main = ScreenFrame(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
    /// A 1920×1080 display left of and below the main one (negative coordinates).
    static let left = ScreenFrame(
        frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1080))
    static let panel = CGSize(width: 200, height: 36)

    private func normalize(_ rect: CGRect?, screens: [ScreenFrame] = [main]) -> CGRect? {
        CaretPositionResolver.normalizeCaretRect(rect, screens: screens, fallbackLineHeight: 18)
    }

    // MARK: Validation

    @Test func rejectsMissingNonFiniteZeroAndOffScreenRects() {
        #expect(normalize(nil) == nil)
        #expect(normalize(.zero) == nil, "Chrome and Electron report .zero")
        #expect(normalize(CGRect(x: CGFloat.nan, y: 10, width: 1, height: 18)) == nil)
        #expect(normalize(CGRect(x: 10, y: CGFloat.infinity, width: 1, height: 18)) == nil)
        #expect(normalize(CGRect(x: 99_999, y: 99_999, width: 1, height: 18)) == nil)
        #expect(normalize(CGRect(x: 10, y: 10, width: 1, height: 18), screens: []) == nil)
        #expect(normalize(CGRect(x: 0, y: 0, width: 2, height: 18)) != nil, "origin .zero with a size is a real caret")
    }

    /// `targetScreen` picks the screen `resolve` places on (valid caret, then this client's
    /// cache, then the mouse) without touching the cache.
    @Test func targetScreenFollowsTheResolvePriorityWithoutCaching() throws {
        var resolver = CaretPositionResolver()
        let screens = [Self.main, Self.left]
        let onLeft = CGRect(x: -800, y: 300, width: 1, height: 18)
        #expect(resolver.targetScreen(caretRect: onLeft, clientKey: "a", screens: screens, fallbackMouseLocation: nil) == Self.left)
        #expect(resolver.cachedClientCount == 0, "the query never caches")
        #expect(resolver.targetScreen(caretRect: .zero, clientKey: "a", screens: screens, fallbackMouseLocation: CGPoint(x: 700, y: 400)) == Self.main)
        _ = resolver.resolve(caretRect: onLeft, clientKey: "a", panelSize: Self.panel, screens: screens, fallbackMouseLocation: nil)
        #expect(resolver.targetScreen(caretRect: .zero, clientKey: "a", screens: screens, fallbackMouseLocation: CGPoint(x: 700, y: 400)) == Self.left,
                "the cached caret wins over the mouse")
        #expect(resolver.targetScreen(caretRect: .zero, clientKey: "b", screens: screens, fallbackMouseLocation: nil) == nil)
        #expect(resolver.targetScreen(caretRect: onLeft, clientKey: "a", screens: [], fallbackMouseLocation: nil) == nil)
    }

    /// A 0-width vertical caret: `CGRect.intersects` treats it as empty and would reject it.
    @Test func acceptsZeroWidthCaretsIncludingOnScreenEdges() {
        let caret = CGRect(x: 300, y: 500, width: 0, height: 18)
        #expect(normalize(caret) == caret)
        #expect(normalize(CGRect(x: 0, y: 400, width: 0, height: 18)) != nil, "left edge")
        #expect(normalize(CGRect(x: 1440, y: 400, width: 0, height: 18)) != nil, "right edge")
    }

    @Test func standardizesRightToLeftRectsAndFillsZeroHeight() {
        #expect(normalize(CGRect(x: 310, y: 518, width: -10, height: -18)) == CGRect(x: 300, y: 500, width: 10, height: 18))
        #expect(normalize(CGRect(x: 300, y: 500, width: 2, height: 0)) == CGRect(x: 300, y: 500, width: 2, height: 18))
    }

    // MARK: Placement

    @Test func placesBelowTheCaretByDefault() throws {
        let resolver = Placer()
        let r = try #require(resolver.resolve(
            caretRect: CGRect(x: 100, y: 500, width: 1, height: 18), clientKey: "a", panelSize: Self.panel,
            screens: [Self.main], fallbackMouseLocation: nil))
        #expect(r.origin == CGPoint(x: 100, y: 458))
        #expect(!r.flippedAbove && !r.usedCache && !r.usedMouseFallback)
    }

    @Test func flipsAboveTheCaretNearTheBottom() throws {
        let resolver = Placer()
        let r = try #require(resolver.resolve(
            caretRect: CGRect(x: 100, y: 20, width: 1, height: 18), clientKey: "a", panelSize: Self.panel,
            screens: [Self.main], fallbackMouseLocation: nil))
        #expect(r.flippedAbove && r.origin.y == 44)
        // A tall panel at the top of the screen is clamped into the visible frame.
        let tall = try #require(resolver.resolve(
            caretRect: CGRect(x: 100, y: 30, width: 1, height: 18), clientKey: "a", panelSize: CGSize(width: 200, height: 860),
            screens: [Self.main], fallbackMouseLocation: nil))
        #expect(tall.origin.y == 15, "maxY 875 - 860")
    }

    @Test func clampsHorizontallyWithoutTrappingOnNarrowScreens() throws {
        let resolver = Placer()
        let r = try #require(resolver.resolve(
            caretRect: CGRect(x: 1430, y: 500, width: 1, height: 18), clientKey: "a", panelSize: Self.panel,
            screens: [Self.main], fallbackMouseLocation: nil))
        #expect(r.origin.x == 1232)
        let narrow = ScreenFrame(frame: CGRect(x: 0, y: 0, width: 100, height: 300), visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 300))
        let n = try #require(resolver.resolve(
            caretRect: CGRect(x: 50, y: 150, width: 1, height: 18), clientKey: "a", panelSize: Self.panel,
            screens: [narrow], fallbackMouseLocation: nil))
        #expect(n.origin.x == 0)
    }

    @Test func usesTheCaretsDisplayAtNegativeCoordinates() throws {
        let resolver = Placer()
        let r = try #require(resolver.resolve(
            caretRect: CGRect(x: -500, y: 300, width: 1, height: 18), clientKey: "a", panelSize: Self.panel,
            screens: [Self.main, Self.left], fallbackMouseLocation: nil))
        #expect(r.origin == CGPoint(x: -500, y: 258))
        let bottom = try #require(resolver.resolve(
            caretRect: CGRect(x: -1900, y: -190, width: 1, height: 18), clientKey: "a", panelSize: Self.panel,
            screens: [Self.main, Self.left], fallbackMouseLocation: nil))
        #expect(bottom.flippedAbove && bottom.origin == CGPoint(x: -1900, y: -166))
    }

    // MARK: Cache and fallbacks

    @Test func reusesTheLastValidCaretOfTheSameClient() throws {
        let resolver = Placer()
        let good = try #require(resolver.resolve(
            caretRect: CGRect(x: 100, y: 500, width: 1, height: 18), clientKey: "chrome-window-1", panelSize: Self.panel,
            screens: [Self.main], fallbackMouseLocation: CGPoint(x: 900, y: 900)))
        let cached = try #require(resolver.resolve(
            caretRect: .zero, clientKey: "chrome-window-1", panelSize: Self.panel,
            screens: [Self.main], fallbackMouseLocation: CGPoint(x: 900, y: 900)))
        #expect(cached.usedCache && !cached.usedMouseFallback && cached.origin == good.origin)
    }

    /// Two windows of one application have different keys: one window's caret never
    /// places the other's panel.
    @Test func neverSharesCachedCaretsAcrossClientKeys() throws {
        let resolver = Placer()
        _ = resolver.resolve(
            caretRect: CGRect(x: 100, y: 500, width: 1, height: 18), clientKey: "chrome-window-1", panelSize: Self.panel,
            screens: [Self.main], fallbackMouseLocation: nil)
        #expect(resolver.resolve(
            caretRect: .zero, clientKey: "chrome-window-2", panelSize: Self.panel,
            screens: [Self.main], fallbackMouseLocation: nil) == nil)
        let mouse = try #require(resolver.resolve(
            caretRect: .zero, clientKey: "chrome-window-2", panelSize: Self.panel,
            screens: [Self.main], fallbackMouseLocation: CGPoint(x: 700, y: 600)))
        #expect(mouse.usedMouseFallback && !mouse.usedCache && mouse.origin == CGPoint(x: 700, y: 540))
    }

    @Test func mouseFallbackOnlyWithoutAValidCaret() throws {
        let resolver = Placer()
        let r = try #require(resolver.resolve(
            caretRect: CGRect(x: 100, y: 500, width: 0, height: 18), clientKey: "a", panelSize: Self.panel,
            screens: [Self.main], fallbackMouseLocation: CGPoint(x: 700, y: 600)))
        #expect(!r.usedMouseFallback && r.origin.x == 100)
        #expect(resolver.resolve(caretRect: nil, clientKey: "a", panelSize: Self.panel, screens: [], fallbackMouseLocation: .zero) == nil)
    }

    @Test func boundsTheCacheLeastRecentlyUsedFirst() {
        let resolver = Placer(cacheCapacity: 32)
        for i in 0..<40 {
            _ = resolver.resolve(
                caretRect: CGRect(x: CGFloat(10 + i), y: 500, width: 1, height: 18), clientKey: "client-\(i)",
                panelSize: Self.panel, screens: [Self.main], fallbackMouseLocation: nil)
        }
        #expect(resolver.cachedClientCount == 32)
        #expect(resolver.cachedRect(for: "client-0") == nil && resolver.cachedRect(for: "client-7") == nil)
        #expect(resolver.cachedRect(for: "client-8") != nil && resolver.cachedRect(for: "client-39") != nil)
    }
}

/// A reference wrapper, so `#expect`/`#require` can call the mutating resolver.
private final class Placer {
    var resolver: CaretPositionResolver

    init(cacheCapacity: Int = 32) {
        resolver = CaretPositionResolver(cacheCapacity: cacheCapacity)
    }

    var cachedClientCount: Int { resolver.cachedClientCount }
    func cachedRect(for key: String) -> CGRect? { resolver.cachedRect(for: key) }

    func resolve(
        caretRect: CGRect?, clientKey: String, panelSize: CGSize, screens: [ScreenFrame], fallbackMouseLocation: CGPoint?
    ) -> CaretResolution? {
        resolver.resolve(
            caretRect: caretRect, clientKey: clientKey, panelSize: panelSize, screens: screens,
            fallbackMouseLocation: fallbackMouseLocation)
    }
}
