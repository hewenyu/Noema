import AppKit
import Foundation
import NoemaClipboardCore
import NoemaCore
import Observation

/// The agent's clipboard history: owns the `ClipboardStore`, the `PasteboardMonitor`, the
/// paste-back service, and the panel. Captures are encrypted and stored on one serial
/// utility queue; everything the UI reads is published on the main actor.
@MainActor
@Observable
public final class ClipboardHistoryController {
    public enum PasteMode: Sendable, Hashable {
        /// Write to the pasteboard, reactivate the previous app, and post ⌘V.
        case paste
        /// Write to the pasteboard and reactivate the previous app only.
        case copyOnly
    }

    public static let customBlockedBundleIDsKey = "ClipboardCustomBlockedBundleIDs"
    public static let fallbackToastMessage = "已复制到剪贴板，请按 ⌘V 粘贴"

    public private(set) var storeState: ClipboardStoreState?
    public private(set) var storeError: String?
    public private(set) var accessStatus: PasteboardAccessStatus
    public private(set) var isAccessibilityTrusted: Bool
    public private(set) var itemCount = 0
    /// Bumped on every change to the history, so views reload.
    public private(set) var revision = 0
    public private(set) var customBlockedBundleIDs: [String]
    public private(set) var lastPasteOutcome: ClipboardPasteOutcome?

    @ObservationIgnored public private(set) var store: ClipboardStore?
    @ObservationIgnored public let monitor: PasteboardMonitor
    @ObservationIgnored public let pasteService: AccessibilityPasteService
    /// Shows a non-activating HUD (the agent's `QuickActionToastController`).
    @ObservationIgnored public var onToast: (String) -> Void = { _ in }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ingestQueue = DispatchQueue(label: "dev.noema.clipboard.ingest", qos: .utility)
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var purgeTask: Task<Void, Never>?
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private let log = NoemaLog.agent("clipboard")
    @ObservationIgnored private var panelStorage: ClipboardPanelController?
    @ObservationIgnored private var changeObservers: [WeakChangeObserver] = []

    private final class WeakChangeObserver {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
        init(owner: AnyObject, handler: @escaping @MainActor () -> Void) {
            self.owner = owner
            self.handler = handler
        }
    }

    /// Registers a main-actor callback weakly owned by `owner`, fired on every history or
    /// status change; pruned automatically once `owner` is deallocated.
    func addChangeObserver(owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        changeObservers.removeAll { $0.owner == nil || $0.owner === owner }
        changeObservers.append(WeakChangeObserver(owner: owner, handler: handler))
    }

    /// The panel, created on first use.
    public var panel: ClipboardPanelController {
        if let panelStorage { return panelStorage }
        let panel = ClipboardPanelController(history: self)
        panelStorage = panel
        return panel
    }

    public init(reader: any PasteboardReading, pasteDriver: any AccessibilityPasteDriver, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let custom = defaults.stringArray(forKey: Self.customBlockedBundleIDsKey) ?? []
        customBlockedBundleIDs = custom
        monitor = PasteboardMonitor(reader: reader, filter: ClipboardPrivacyFilter(additionalBlockedBundleIDs: custom))
        pasteService = AccessibilityPasteService(driver: pasteDriver)
        accessStatus = monitor.accessStatus
        isAccessibilityTrusted = pasteService.isTrusted
        monitor.onCapture = { [weak self] capture in self?.ingest(capture) }
        monitor.onStatusChange = { [weak self] in self?.refreshStatus() }
    }

    /// Opens the store off the main thread (the keychain may prompt), then starts the
    /// monitor, the lock and sleep observers, and the periodic (5 min) TTL purge.
    public func start(directory: URL = NoemaPaths.clipboardDir(), keyStore: any ClipboardKeyStore = KeychainClipboardKeyStore()) {
        monitor.setPaused(.keychainLocked, true)
        ingestQueue.async { [weak self] in
            let result = Result { () throws(ClipboardError) -> ClipboardStore in
                try ClipboardStore(directory: directory, keyStore: keyStore)
            }
            Task { @MainActor [weak self] in self?.attach(result) }
        }
        observeSessionChanges()
        monitor.start()
    }

    /// Attaches an already open store (tests and `start`).
    public func attach(_ result: Result<ClipboardStore, ClipboardError>) {
        guard !isShutDown else {
            if case .success(let store) = result { store.close() }
            return
        }
        switch result {
        case .success(let store):
            self.store = store
            storeError = nil
        case .failure(let error):
            storeError = "\(error)"
            log.error("clipboard store unavailable: \(String(describing: error), privacy: .public)")
        }
        refreshStatus()
        purgeTask?.cancel()
        purgeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self else { return }
                self.purgeExpired()
            }
        }
    }

    /// Stops the monitor and the observers, waits for pending captures, and closes the
    /// store (WAL checkpoint).
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        monitor.stop()
        purgeTask?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        panelStorage?.hide(restoreFocus: false)
        let store = store
        ingestQueue.sync { store?.close() }
    }

    /// Blocks until every queued capture is stored (tests).
    func waitForIngest() {
        ingestQueue.sync {}
    }

    // MARK: Status

    public func refreshStatus() {
        storeState = store?.state
        accessStatus = monitor.accessStatus
        isAccessibilityTrusted = pasteService.isTrusted
        itemCount = store?.itemCount ?? 0
        monitor.setPausedSilently(.keychainLocked, store?.state != .ready)
        revision &+= 1
        changeObservers.removeAll { $0.owner == nil }
        for observer in changeObservers where observer.owner != nil { observer.handler() }
    }

    /// Retries the keychain after the screen unlocks or on request.
    public func retryUnlock() {
        guard let store else { return }
        ingestQueue.async { [weak self] in
            store.retryUnlock()
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    /// Non-interactively verifies keychain access when the store is currently `.ready` (e.g.
    /// on `com.apple.security.keychain.lock`), transitioning to `.keychainLocked` without ever
    /// prompting interactively or creating a key.
    public func verifyKeychainAccess() {
        guard let store else { return }
        ingestQueue.async { [weak self] in
            _ = store.verifyKeychainAccess()
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    // MARK: Capture

    private func ingest(_ capture: ClipboardCapture) {
        guard let store else { return }
        let log = log
        ingestQueue.async { [weak self] in
            // Non-interactively verify keychain availability before persisting: if the user
            // locked the login keychain while running, transition immediately to
            // `.keychainLocked` without writing and let `refreshStatus()` pause monitoring.
            guard store.verifyKeychainAccess() == .ready else {
                Task { @MainActor [weak self] in self?.refreshStatus() }
                return
            }
            do {
                switch capture.payload {
                case .text(let text):
                    try store.insertText(text, source: capture.source)
                case .imageData(let data, _):
                    let image = try ClipboardImageProcessor.process(data, quota: store.quota)
                    try store.insertImage(image, source: capture.source)
                }
            } catch {
                // Never log content: the error names a size or a code only.
                log.info("clipboard capture skipped: \(String(describing: error), privacy: .public)")
            }
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    func purgeExpired(now: Date = Date()) {
        guard let store else { return }
        ingestQueue.async { [weak self] in
            _ = try? store.purgeExpired(now: now)
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    // MARK: Actions

    public func items(filter: ClipboardFilter, query: String) -> [ClipboardEntryMetadata] {
        store?.items(filter: filter, query: query) ?? []
    }

    /// Writes entry `id` to the pasteboard (as Noema's own paste-back), then pastes it into
    /// or reactivates `target`. Atomically rejects expired unpinned entries and locked-keychain
    /// reads without touching the pasteboard or reviving their TTL.
    public func use(id: String, mode: PasteMode, target: ClipboardSourceApp?, now: Date = Date()) async -> ClipboardPasteOutcome? {
        guard let store, store.verifyKeychainAccess() == .ready, let content = try? store.useContent(id: id, now: now) else {
            refreshStatus()
            onToast("这条记录已过期或无法读取")
            return nil
        }
        monitor.writeSelfPaste(content)
        refreshStatus()
        let outcome: ClipboardPasteOutcome
        switch mode {
        case .paste:
            outcome = await pasteService.paste(into: target)
        case .copyOnly:
            if let pid = target?.pid { NSRunningApplication(processIdentifier: pid)?.activate() }
            outcome = .copiedNoTarget
        }
        lastPasteOutcome = outcome
        isAccessibilityTrusted = pasteService.isTrusted
        switch outcome {
        case .pasted: break
        case .copiedNeedsAccessibility, .abortedFocusLost, .abortedSecureInput: onToast(Self.fallbackToastMessage)
        case .copiedNoTarget: if mode == .copyOnly { onToast("已复制到剪贴板") } else { onToast(Self.fallbackToastMessage) }
        }
        return outcome
    }

    public func setPinned(id: String, pinned: Bool) {
        try? store?.setPinned(id: id, pinned: pinned)
        refreshStatus()
    }

    public func delete(id: String) {
        try? store?.delete(id: id)
        refreshStatus()
    }

    public func clearUnpinned() {
        _ = try? store?.clearUnpinned()
        refreshStatus()
    }

    public func content(id: String) -> ClipboardEntryContent? { try? store?.content(id: id) }
    public func thumbnail(id: String) -> Data? { try? store?.thumbnail(id: id) }

    public func togglePanel() { panel.toggle() }
    public func showPanel() { panel.show() }

    public func openAccessibilitySettings() {
        AccessibilityPasteService.openAccessibilitySettings()
    }

    /// The system Accessibility prompt, only from an explicit button.
    public func requestAccessibility() {
        AccessibilityPasteService.requestAccessibilityPrompt()
        isAccessibilityTrusted = pasteService.isTrusted
    }

    /// Replaces the user's blocked bundle IDs (trimmed, unique, case-insensitive).
    public func setCustomBlockedBundleIDs(_ ids: [String]) {
        var seen = Set<String>()
        let cleaned = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        customBlockedBundleIDs = cleaned
        defaults.set(cleaned, forKey: Self.customBlockedBundleIDsKey)
        monitor.filter = ClipboardPrivacyFilter(additionalBlockedBundleIDs: cleaned)
    }

    // MARK: Session

    private func observeSessionChanges() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (ClipboardHistoryController) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self)
                }
            }
            observers.append((center, token))
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.monitor.setPaused(.screenLocked, true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) {
            $0.monitor.setPaused(.screenLocked, false)
            $0.retryUnlock()
        }
        observe(distributed, Notification.Name("com.apple.security.keychain.lock")) { $0.verifyKeychainAccess() }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.monitor.setPaused(.sleeping, true) }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.monitor.setPaused(.sleeping, false)
            $0.retryUnlock()
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.isAccessibilityTrusted = $0.pasteService.isTrusted }
    }
}

extension PasteboardMonitor {
    /// `setPaused` without a status callback (used from `refreshStatus` itself).
    func setPausedSilently(_ reason: PauseReason, _ paused: Bool) {
        guard pauseReasons.contains(reason) != paused else { return }
        let callback = onStatusChange
        onStatusChange = {}
        setPaused(reason, paused)
        onStatusChange = callback
    }
}
