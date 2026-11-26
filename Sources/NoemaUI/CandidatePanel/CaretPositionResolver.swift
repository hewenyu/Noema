import CoreGraphics

/// One display, in Cocoa global coordinates (bottom-left origin; secondary displays may sit
/// at negative coordinates).
public struct ScreenFrame: Sendable, Hashable {
    public let frame: CGRect
    /// The frame minus the menu bar and Dock.
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Where the panel goes, and how that was decided.
public struct CaretResolution: Sendable, Hashable {
    /// The panel's bottom-left corner in Cocoa global coordinates.
    public let origin: CGPoint
    /// The panel sits above the caret because below it would leave the visible frame.
    public let flippedAbove: Bool
    /// The client's caret rectangle was invalid; the last valid one for this client was used.
    public let usedCache: Bool
    /// No valid or cached caret: the panel follows the mouse location.
    public let usedMouseFallback: Bool
}

/// Places the panel next to a client's caret, tolerating the rectangles clients really
/// report: `.zero`, NaN, negative sizes (right-to-left text), 0-width or 0-height carets,
/// and rectangles on no screen. A valid rectangle is cached per client key (a window or
/// document, never a whole application) and reused when that client later reports garbage;
/// the mouse location is the last resort.
public struct CaretPositionResolver: Sendable {
    public var gap: CGFloat
    public var margin: CGFloat
    public var fallbackLineHeight: CGFloat
    public let cacheCapacity: Int

    private var cache: [String: CGRect] = [:]
    /// Least recently used first.
    private var recency: [String] = []

    public init(gap: CGFloat = 6, margin: CGFloat = 8, fallbackLineHeight: CGFloat = 18, cacheCapacity: Int = 32) {
        self.gap = gap
        self.margin = margin
        self.fallbackLineHeight = fallbackLineHeight
        self.cacheCapacity = max(cacheCapacity, 1)
    }

    public init(style: CandidatePanelStyle) {
        self.init(gap: style.caretGap, margin: style.screenMargin, fallbackLineHeight: style.fallbackLineHeight)
    }

    /// The number of clients with a cached caret.
    public var cachedClientCount: Int { cache.count }

    /// The last valid caret rectangle of `clientKey`, if any.
    public func cachedRect(for clientKey: String) -> CGRect? { cache[clientKey] }

    /// `rect` standardized and with a usable height, or nil when it is missing, non-finite,
    /// exactly `.zero`, or on no screen. Containment uses a probe of at least 1×1 points
    /// grown by 2 points, so a 0-width vertical caret on a screen edge still counts.
    public static func normalizeCaretRect(_ rect: CGRect?, screens: [ScreenFrame], fallbackLineHeight: CGFloat) -> CGRect? {
        guard let rect else { return nil }
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        guard values.allSatisfy(\.isFinite) else { return nil }
        guard !(rect.origin == .zero && rect.size == .zero) else { return nil }
        var r = rect.standardized
        guard screens.contains(where: { $0.frame.intersects(probe(r)) }) else { return nil }
        if r.height == 0 { r.size.height = fallbackLineHeight }
        return r
    }

    /// The panel origin for a `panelSize` panel at `caretRect` of `clientKey`, or nil when
    /// there is no screen or nothing to anchor to.
    public mutating func resolve(
        caretRect: CGRect?,
        clientKey: String,
        panelSize: CGSize,
        screens: [ScreenFrame],
        fallbackMouseLocation: CGPoint?
    ) -> CaretResolution? {
        guard let anchor = anchor(caretRect: caretRect, clientKey: clientKey, screens: screens, fallbackMouseLocation: fallbackMouseLocation)
        else { return nil }
        let caret = anchor.caret
        let usedCache = anchor.source == .cache
        let usedMouse = anchor.source == .mouse
        switch anchor.source {
        case .valid: remember(caret, for: clientKey)
        case .cache: touch(clientKey)
        case .mouse: break
        }

        let visible = Self.screen(for: caret, in: screens).visibleFrame
        let width = max(panelSize.width, 0), height = max(panelSize.height, 0)

        var y = caret.minY - gap - height
        var flipped = false
        if y < visible.minY {
            y = caret.maxY + gap
            flipped = true
        }
        let maxY = max(visible.minY, visible.maxY - height)
        y = min(max(y, visible.minY), maxY)

        let maxX = max(visible.minX, visible.maxX - margin - width)
        let minX = min(visible.minX + margin, maxX)
        let x = min(max(caret.minX, minX), maxX)

        return CaretResolution(origin: CGPoint(x: x, y: y), flippedAbove: flipped, usedCache: usedCache, usedMouseFallback: usedMouse)
    }

    /// The screen `resolve` would place the panel on, by the same priority (valid caret,
    /// this client's cached caret, then the mouse), without touching the cache; nil when
    /// there is no screen or nothing to anchor to. The panel controller bounds the panel
    /// height to this screen's visible frame before resolving the origin.
    public func targetScreen(
        caretRect: CGRect?,
        clientKey: String,
        screens: [ScreenFrame],
        fallbackMouseLocation: CGPoint?
    ) -> ScreenFrame? {
        guard let anchor = anchor(caretRect: caretRect, clientKey: clientKey, screens: screens, fallbackMouseLocation: fallbackMouseLocation)
        else { return nil }
        return Self.screen(for: anchor.caret, in: screens)
    }

    /// Forgets every cached caret.
    public mutating func removeAll() {
        cache.removeAll()
        recency.removeAll()
    }

    // MARK: - Private

    private enum AnchorSource { case valid, cache, mouse }

    /// The caret rectangle to place against, and where it came from; nil when `screens` is
    /// empty or there is no valid caret, cached caret, or finite mouse location.
    private func anchor(
        caretRect: CGRect?, clientKey: String, screens: [ScreenFrame], fallbackMouseLocation: CGPoint?
    ) -> (caret: CGRect, source: AnchorSource)? {
        guard !screens.isEmpty else { return nil }
        if let valid = Self.normalizeCaretRect(caretRect, screens: screens, fallbackLineHeight: fallbackLineHeight) {
            return (valid, .valid)
        }
        if let cached = cache[clientKey] { return (cached, .cache) }
        if let mouse = fallbackMouseLocation, mouse.x.isFinite, mouse.y.isFinite {
            return (CGRect(x: mouse.x, y: mouse.y - fallbackLineHeight, width: 0, height: fallbackLineHeight), .mouse)
        }
        return nil
    }

    private static func probe(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: r.minY, width: max(r.width, 1), height: max(r.height, 1)).insetBy(dx: -2, dy: -2)
    }

    /// The screen holding most of the caret probe, else the nearest one.
    private static func screen(for caret: CGRect, in screens: [ScreenFrame]) -> ScreenFrame {
        let p = probe(caret)
        var best: ScreenFrame?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.frame.intersection(p)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                best = screen
                bestArea = area
            }
        }
        if let best { return best }
        let point = CGPoint(x: caret.midX, y: caret.midY)
        return screens.min { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) } ?? screens[0]
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private mutating func remember(_ rect: CGRect, for key: String) {
        cache[key] = rect
        touch(key)
        while recency.count > cacheCapacity {
            cache.removeValue(forKey: recency.removeFirst())
        }
    }

    private mutating func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
