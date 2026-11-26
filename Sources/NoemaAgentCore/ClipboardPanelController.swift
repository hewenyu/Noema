import AppKit
import NoemaClipboardCore
import NoemaCore
import Observation
import SwiftUI

/// A borderless, non-activating panel that can become key (for the search field) but never
/// main, so opening it leaves the user's app active and frontmost.
final class ClipboardPanel: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

/// The date groups of the list, in display order.
public enum ClipboardListSection: String, Sendable, Hashable, CaseIterable {
    case pinned
    case today
    case yesterday
    case lastSevenDays
    case earlier

    public var title: String {
        switch self {
        case .pinned: "已固定"
        case .today: "今天"
        case .yesterday: "昨天"
        case .lastSevenDays: "最近 7 天"
        case .earlier: "更早"
        }
    }

    public static func of(_ item: ClipboardEntryMetadata, now: Date, calendar: Calendar = .current) -> ClipboardListSection {
        if item.isPinned { return .pinned }
        if calendar.isDate(item.lastUsedAt, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(item.lastUsedAt, inSameDayAs: yesterday) {
            return .yesterday
        }
        if let week = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)), item.lastUsedAt >= week {
            return .lastSevenDays
        }
        return .earlier
    }
}

/// The panel's state: search, filter, selection, revealed sensitive entries, and a cache
/// of decrypted previews that is dropped whenever the panel closes.
@MainActor
@Observable
public final class ClipboardPanelModel {
    public var query = ""
    public var filter: ClipboardFilter = .all
    public private(set) var items: [ClipboardEntryMetadata] = []
    public var selectedID: String?
    public var revealedIDs: Set<String> = []
    public var showsActions = false
    /// The app the panel will paste into: frontmost before it opened.
    public internal(set) var target: ClipboardSourceApp?
    /// Bumped each time the panel opens, so the view refocuses the search field.
    public internal(set) var openGeneration = 0

    @ObservationIgnored weak var history: ClipboardHistoryController?
    @ObservationIgnored var onClose: (_ restoreFocus: Bool) -> Void = { _ in }
    @ObservationIgnored private var contentCache: [String: ClipboardEntryContent] = [:]
    @ObservationIgnored private var imageCache: [String: NSImage] = [:]

    init(history: ClipboardHistoryController?) {
        self.history = history
    }

    public var storeState: ClipboardStoreState? { history?.storeState }
    public var accessStatus: PasteboardAccessStatus { history?.accessStatus ?? .default }
    public var isAccessibilityTrusted: Bool { history?.isAccessibilityTrusted ?? false }
    public var storeError: String? { history?.storeError }

    public var selected: ClipboardEntryMetadata? {
        guard let selectedID else { return items.first }
        return items.first { $0.id == selectedID } ?? items.first
    }

    public var primaryActionTitle: String {
        if let name = target?.name, !name.isEmpty { return "粘贴到 \(name)" }
        return "复制到剪贴板"
    }

    /// The list grouped by `ClipboardListSection`, in display order.
    public func sections(now: Date = Date()) -> [(ClipboardListSection, [ClipboardEntryMetadata])] {
        let grouped = Dictionary(grouping: items) { ClipboardListSection.of($0, now: now) }
        return ClipboardListSection.allCases.compactMap { section in grouped[section].map { (section, $0) } }
    }

    /// Items in the order the list shows them (sections flattened), for ↑/↓.
    public var orderedItems: [ClipboardEntryMetadata] { sections().flatMap(\.1) }

    public func reload() {
        items = history?.items(filter: filter, query: query) ?? []
        let ordered = orderedItems
        if let selectedID, ordered.contains(where: { $0.id == selectedID }) { return }
        selectedID = ordered.first?.id
    }

    public func moveSelection(_ delta: Int) {
        let ordered = orderedItems
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selectedID } ?? -1
        selectedID = ordered[min(max(current + delta, 0), ordered.count - 1)].id
    }

    public func isMasked(_ item: ClipboardEntryMetadata) -> Bool {
        item.sensitivity == .sensitive && !revealedIDs.contains(item.id)
    }

    public func toggleReveal(_ item: ClipboardEntryMetadata) {
        if revealedIDs.contains(item.id) { revealedIDs.remove(item.id) } else { revealedIDs.insert(item.id) }
    }

    public func content(for item: ClipboardEntryMetadata) -> ClipboardEntryContent? {
        if let cached = contentCache[item.id] { return cached }
        guard let content = history?.content(id: item.id) else { return nil }
        contentCache[item.id] = content
        return content
    }

    public func image(for item: ClipboardEntryMetadata) -> NSImage? {
        if let cached = imageCache[item.id] { return cached }
        guard case .image(let png, _, _, _)? = content(for: item), let image = NSImage(data: png) else { return nil }
        imageCache[item.id] = image
        return image
    }

    public func thumbnail(for item: ClipboardEntryMetadata) -> NSImage? {
        let key = "thumb:" + item.id
        if let cached = imageCache[key] { return cached }
        guard let data = history?.thumbnail(id: item.id), let image = NSImage(data: data) else { return nil }
        imageCache[key] = image
        return image
    }

    /// Drops every decrypted payload and image.
    public func clearCaches() {
        contentCache = [:]
        imageCache = [:]
        revealedIDs = []
    }

    // MARK: Actions

    public func performPrimary() { use(.paste) }
    public func copyOnly() { use(.copyOnly) }

    private func use(_ mode: ClipboardHistoryController.PasteMode) {
        guard let item = selected, let history else { return }
        let target = target
        onClose(false)
        Task { @MainActor in _ = await history.use(id: item.id, mode: mode, target: target) }
    }

    public func togglePin() {
        guard let item = selected else { return }
        history?.setPinned(id: item.id, pinned: !item.isPinned)
        reload()
    }

    public func deleteSelected() {
        guard let item = selected else { return }
        let ordered = orderedItems
        let index = ordered.firstIndex { $0.id == item.id } ?? 0
        history?.delete(id: item.id)
        contentCache.removeValue(forKey: item.id)
        reload()
        let next = orderedItems
        if !next.isEmpty { selectedID = next[min(index, next.count - 1)].id }
    }

    public func clearUnpinned() {
        history?.clearUnpinned()
        clearCaches()
        reload()
    }

    public func openAccessibilitySettings() {
        onClose(false)
        history?.openAccessibilitySettings()
    }

    public func close() { onClose(true) }
}

/// Shows and hides the clipboard panel. Before it orders front it records the frontmost
/// app (never Noema itself); `Esc` reactivates that app, a click elsewhere just hides the
/// panel, and neither touches the pasteboard. Closing drops every decrypted preview.
@MainActor
public final class ClipboardPanelController: NSObject, NSWindowDelegate {
    public static let panelSize = CGSize(width: 760, height: 480)

    public let model: ClipboardPanelModel
    public private(set) var isVisible = false
    public private(set) var previousFrontmostApp: ClipboardSourceApp?
    /// `false` keeps the panel off screen (headless tests); everything else still runs.
    public var shouldOrderFront = true

    private let panel: ClipboardPanel
    private let frontmost: @MainActor () -> ClipboardSourceApp?

    init(history: ClipboardHistoryController?, frontmost: @escaping @MainActor () -> ClipboardSourceApp? = ClipboardPanelController.currentFrontmost) {
        model = ClipboardPanelModel(history: history)
        self.frontmost = frontmost
        panel = ClipboardPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide(restoreFocus: true) }
        model.onClose = { [weak self] restore in self?.hide(restoreFocus: restore) }

        let hosting = NSHostingView(rootView: ClipboardPanelView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            // Reduce Transparency: a HUD material instead of Liquid Glass.
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            effect.layer?.masksToBounds = true
            hosting.frame = effect.bounds
            effect.addSubview(hosting)
            panel.contentView = effect
        } else {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 18
            glass.contentView = hosting
            panel.contentView = glass
        }
    }

    /// The frontmost app other than Noema, as a value snapshot.
    public static func currentFrontmost() -> ClipboardSourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != NoemaPaths.agentBundleID else { return nil }
        return ClipboardSourceApp(bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier)
    }

    public func toggle() {
        if isVisible { hide(restoreFocus: true) } else { show() }
    }

    public func show() {
        if !isVisible { previousFrontmostApp = frontmost() }
        model.target = previousFrontmostApp
        model.query = ""
        model.filter = .all
        model.showsActions = false
        model.selectedID = nil
        model.history?.refreshStatus()
        model.reload()
        model.openGeneration &+= 1
        isVisible = true
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = Self.panelSize
            panel.setFrame(
                CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.1, width: size.width, height: size.height),
                display: false)
        }
        guard shouldOrderFront else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Hides the panel; `restoreFocus` reactivates the app that was frontmost before.
    public func hide(restoreFocus: Bool) {
        guard isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
        model.clearCaches()
        model.showsActions = false
        if restoreFocus, let pid = previousFrontmostApp?.pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        // A click outside: the clicked app already has focus.
        hide(restoreFocus: false)
    }

    /// The panel, for tests.
    var panelForTesting: NSPanel { panel }
}
