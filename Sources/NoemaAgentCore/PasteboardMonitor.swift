import AppKit
import Carbon.HIToolbox
import Foundation
import NoemaClipboardCore
import NoemaCore

/// `NSPasteboard.AccessBehavior` (macOS 15.4+) as the Settings window and panel show it.
public enum PasteboardAccessStatus: String, Sendable, Hashable {
    case `default`
    case ask
    case alwaysAllow
    case alwaysDeny

    public var title: String {
        switch self {
        case .default: "未设置（首次读取时系统会询问）"
        case .ask: "每次询问"
        case .alwaysAllow: "始终允许"
        case .alwaysDeny: "始终拒绝（已暂停记录）"
        }
    }
}

/// Outcome of writing a self-paste entry to the pasteboard.
public struct PasteboardWriteResult: Sendable, Hashable {
    /// Whether `writeObjects` succeeded AND our unique `self-paste` token was still present
    /// at a stable `changeCount` immediately after writing.
    public var owned: Bool
    /// The verified `changeCount` when `owned` is true (`nil` if another process took over).
    public var ownedChangeCount: Int?
    /// `changeCount` values known to belong to our write (`prepared`, plus `ownedChangeCount`
    /// only when ownership was verified). Never includes an unverified foreign `changeCount`.
    public var ownChangeCounts: [Int]
    /// The unique per-write token placed under `dev.noema.clipboard.self-paste`.
    public var token: Data

    public init(owned: Bool, ownedChangeCount: Int?, ownChangeCounts: [Int], token: Data) {
        self.owned = owned
        self.ownedChangeCount = ownedChangeCount
        self.ownChangeCounts = ownChangeCounts
        self.token = token
    }
}

/// The general pasteboard and the facts the monitor checks around it. Metadata calls
/// (`changeCount`, types, secure input, access behavior, frontmost app) never read a
/// payload; `readString` and `readData` do, and run only after the privacy filter allows.
@MainActor
public protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    var isSecureInputActive: Bool { get }
    var accessStatus: PasteboardAccessStatus { get }
    func pasteboardTypes() -> [String]
    func itemTypes() -> [[String]]
    /// The frontmost app other than Noema, as a value snapshot.
    func frontmostSource() -> ClipboardSourceApp?
    func readString() -> String?
    func readData(forType type: String) -> Data?
    /// Clears the pasteboard for this host only, writes one item (`content` plus every
    /// `markers` type), and verifies our unique self-paste marker is still present at a
    /// stable `changeCount`.
    func write(_ content: ClipboardEntryContent, markers: [String: Data]) -> PasteboardWriteResult
    /// Confirms the pasteboard is still at `expectedChangeCount` and carries our exact
    /// self-paste `token`.
    func ownsSelfPaste(expectedChangeCount: Int, token: Data) -> Bool
}

/// `NSPasteboard.general`, `IsSecureEventInputEnabled()`, and `NSWorkspace`.
@MainActor
public final class SystemPasteboardReader: PasteboardReading {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }
    public var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    public var accessStatus: PasteboardAccessStatus {
        switch pasteboard.accessBehavior {
        case .ask: .ask
        case .alwaysAllow: .alwaysAllow
        case .alwaysDeny: .alwaysDeny
        default: .default
        }
    }

    public func pasteboardTypes() -> [String] { pasteboard.types?.map(\.rawValue) ?? [] }
    public func itemTypes() -> [[String]] { pasteboard.pasteboardItems?.map { $0.types.map(\.rawValue) } ?? [] }

    public func frontmostSource() -> ClipboardSourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != NoemaPaths.agentBundleID else { return nil }
        return ClipboardSourceApp(bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier)
    }

    public func readString() -> String? { pasteboard.string(forType: .string) }
    public func readData(forType type: String) -> Data? { pasteboard.data(forType: NSPasteboard.PasteboardType(type)) }

    public func write(_ content: ClipboardEntryContent, markers: [String: Data]) -> PasteboardWriteResult {
        let token = markers[ClipboardPrivacyFilter.selfPasteType] ?? Data()
        let prepared = pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        switch content {
        case .text(let text): item.setString(text, forType: .string)
        case .image(let png, _, _, _): item.setData(png, forType: .png)
        }
        for (type, data) in markers.sorted(by: { $0.key < $1.key }) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        guard pasteboard.writeObjects([item]) else {
            return PasteboardWriteResult(owned: false, ownedChangeCount: nil, ownChangeCounts: [prepared], token: token)
        }
        let afterWrite = pasteboard.changeCount
        guard ownsSelfPaste(expectedChangeCount: afterWrite, token: token) else {
            return PasteboardWriteResult(owned: false, ownedChangeCount: nil, ownChangeCounts: [prepared], token: token)
        }
        let ownCounts = afterWrite == prepared ? [prepared] : [prepared, afterWrite]
        return PasteboardWriteResult(owned: true, ownedChangeCount: afterWrite, ownChangeCounts: ownCounts, token: token)
    }

    public func ownsSelfPaste(expectedChangeCount: Int, token: Data) -> Bool {
        guard !token.isEmpty, pasteboard.changeCount == expectedChangeCount else { return false }
        let markerType = NSPasteboard.PasteboardType(ClipboardPrivacyFilter.selfPasteType)
        // Check metadata types first so a foreign pasteboard item is rejected without
        // requesting any payload data from another process.
        guard pasteboard.types?.contains(markerType) == true else { return false }
        guard pasteboard.data(forType: markerType) == token else { return false }
        return pasteboard.changeCount == expectedChangeCount
    }
}

/// A recorded copy, read after the privacy filter allowed it.
public struct ClipboardCapture: Sendable, Hashable {
    public enum Payload: Sendable, Hashable {
        case text(String)
        case imageData(Data, type: String)
    }

    public var changeCount: Int
    public var payload: Payload
    public var source: ClipboardSourceApp?
}

/// Polls the general pasteboard every `pollInterval` (400 ms), `changeCount` first.
///
/// - Every new `changeCount` advances `lastSeenChangeCount` before anything else, so a
///   change is examined once and never retried.
/// - Under secure input the change is only counted and tainted: leaving the password field
///   later can never capture it.
/// - Otherwise the snapshot's metadata goes through `ClipboardPrivacyFilter`; only
///   `.capture` reads the payload.
/// - While paused (screen locked, asleep, keychain locked, access denied) nothing is read;
///   resuming takes the current `changeCount` as the baseline, so changes made meanwhile
///   are skipped.
@MainActor
public final class PasteboardMonitor {
    public enum PauseReason: String, Sendable, Hashable, CaseIterable {
        case screenLocked
        case sleeping
        case keychainLocked
        case user
    }

    public struct Counters: Sendable, Hashable {
        public var polls = 0
        public var captured = 0
        public var secureInput = 0
        public var selfPaste = 0
        public var privacyMarker = 0
        public var blockedSource = 0
        public var fileOnly = 0
        public var unsupported = 0
        public var accessDenied = 0
        public var emptyReads = 0
        public var staleSnapshot = 0
    }

    public static let selfChangeCountLimit = 32
    public static let taintedLimit = 64

    public let pollInterval: Duration
    public var filter: ClipboardPrivacyFilter
    public var onCapture: (ClipboardCapture) -> Void = { _ in }
    public var onStatusChange: () -> Void = {}

    public private(set) var lastSeenChangeCount: Int
    public private(set) var accessStatus: PasteboardAccessStatus
    public private(set) var pauseReasons: Set<PauseReason> = []
    public private(set) var counters = Counters()
    public private(set) var ignoredSelfChangeCounts: [Int] = []
    public private(set) var taintedChangeCounts: [Int] = []
    public var isRunning: Bool { pollTask != nil }
    /// The pasteboard's live `changeCount` (metadata only; never reads a payload).
    public var currentChangeCount: Int { reader.changeCount }

    private let reader: any PasteboardReading
    private var pollTask: Task<Void, Never>?

    /// The baseline is the current `changeCount`: what was copied before launch is never
    /// recorded.
    public init(reader: any PasteboardReading, filter: ClipboardPrivacyFilter = ClipboardPrivacyFilter(), pollInterval: Duration = .milliseconds(400)) {
        self.reader = reader
        self.filter = filter
        self.pollInterval = pollInterval
        lastSeenChangeCount = reader.changeCount
        accessStatus = reader.accessStatus
    }

    public func start() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval, tolerance: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.poll()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func setPaused(_ reason: PauseReason, _ paused: Bool) {
        let wasPaused = !pauseReasons.isEmpty
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        if wasPaused, pauseReasons.isEmpty {
            // Whatever changed while paused stays unrecorded.
            let current = reader.changeCount
            if current != lastSeenChangeCount { taint(current) }
            lastSeenChangeCount = current
        }
        onStatusChange()
    }

    /// One poll; the timer calls it, tests call it directly.
    public func poll() {
        counters.polls += 1
        guard pauseReasons.isEmpty else { return }
        let count = reader.changeCount
        guard count != lastSeenChangeCount else { return }

        if reader.isSecureInputActive {
            taint(count)
            lastSeenChangeCount = count
            counters.secureInput += 1
            return
        }
        guard !taintedChangeCounts.contains(count) else {
            lastSeenChangeCount = count
            return
        }
        let access = reader.accessStatus
        if access != accessStatus {
            accessStatus = access
            onStatusChange()
        }
        if access == .alwaysDeny {
            lastSeenChangeCount = count
            counters.accessDenied += 1
            return
        }

        let pasteboardTypes = reader.pasteboardTypes()
        let itemTypes = reader.itemTypes()
        let source = reader.frontmostSource()

        // Re-verify pasteboard generation and secure input before reading any payload so
        // another process replacing the pasteboard (e.g. a password manager writing
        // `ConcealedType`) can never have its payload evaluated under stale metadata.
        if !confirmSnapshotUnchanged(expectedCount: count) { return }

        let reader = reader
        let snapshot = ClipboardCaptureSnapshot(
            changeCount: count, pasteboardTypes: pasteboardTypes, itemTypes: itemTypes,
            source: source, isSecureInputActive: false,
            readString: { reader.readString() }, readData: { reader.readData(forType: $0) })
        switch filter.evaluate(snapshot, ignoredSelfChangeCounts: Set(ignoredSelfChangeCounts)) {
        case .skip(let reason):
            lastSeenChangeCount = count
            record(reason)
        case .capture(.text):
            guard let text = snapshot.readString(), !text.isEmpty else {
                lastSeenChangeCount = count
                counters.emptyReads += 1
                return
            }
            guard confirmSnapshotUnchanged(expectedCount: count) else { return }
            lastSeenChangeCount = count
            counters.captured += 1
            onCapture(ClipboardCapture(changeCount: count, payload: .text(text), source: snapshot.source))
        case .capture(.image(let type)):
            guard let data = snapshot.readData(type), !data.isEmpty else {
                lastSeenChangeCount = count
                counters.emptyReads += 1
                return
            }
            guard confirmSnapshotUnchanged(expectedCount: count) else { return }
            lastSeenChangeCount = count
            counters.captured += 1
            onCapture(ClipboardCapture(changeCount: count, payload: .imageData(data, type: type), source: snapshot.source))
        }
    }

    /// Confirms that secure input did not activate and `changeCount` stayed at
    /// `expectedCount`. On mismatch, leaves `lastSeenChangeCount` at `expectedCount` (unless
    /// secure input activated, in which case the current count is tainted) so the next poll
    /// evaluates the newer pasteboard generation against its own metadata.
    private func confirmSnapshotUnchanged(expectedCount: Int) -> Bool {
        if reader.isSecureInputActive {
            let current = reader.changeCount
            taint(current)
            lastSeenChangeCount = current
            counters.secureInput += 1
            return false
        }
        guard reader.changeCount == expectedCount else {
            lastSeenChangeCount = expectedCount
            counters.staleSnapshot += 1
            return false
        }
        return true
    }

    /// Writes `content` for a paste-back with three guards against recording it again:
    /// a current-host-only pasteboard, `org.nspasteboard.TransientType` plus
    /// `dev.noema.clipboard.self-paste` (unique per write) on the item, and only the
    /// verified `changeCount`s produced by our own write recorded in `ignoredSelfChangeCounts`
    /// and `lastSeenChangeCount` before this returns (if another process overwrites the
    /// pasteboard mid-write, `result.owned` is `false` and the foreign generation is never
    /// claimed as our own).
    @discardableResult
    public func writeSelfPaste(_ content: ClipboardEntryContent) -> PasteboardWriteResult {
        let token = Data(UUID().uuidString.utf8)
        let result = reader.write(content, markers: [
            ClipboardPrivacyFilter.transientType: Data(),
            ClipboardPrivacyFilter.selfPasteType: token,
        ])
        for count in result.ownChangeCounts where !ignoredSelfChangeCounts.contains(count) {
            ignoredSelfChangeCounts.append(count)
        }
        if ignoredSelfChangeCounts.count > Self.selfChangeCountLimit {
            ignoredSelfChangeCounts.removeFirst(ignoredSelfChangeCounts.count - Self.selfChangeCountLimit)
        }
        if let ownedCount = result.ownedChangeCount {
            lastSeenChangeCount = ownedCount
        }
        return result
    }

    /// Confirms the pasteboard still holds our verified self-paste generation and unique token.
    public func ownsSelfPaste(expectedChangeCount: Int, token: Data) -> Bool {
        reader.ownsSelfPaste(expectedChangeCount: expectedChangeCount, token: token)
    }

    private func taint(_ count: Int) {
        guard !taintedChangeCounts.contains(count) else { return }
        taintedChangeCounts.append(count)
        if taintedChangeCounts.count > Self.taintedLimit {
            taintedChangeCounts.removeFirst(taintedChangeCounts.count - Self.taintedLimit)
        }
    }

    private func record(_ reason: ClipboardSkipReason) {
        switch reason {
        case .secureInput: counters.secureInput += 1
        case .selfPaste: counters.selfPaste += 1
        case .privacyMarker: counters.privacyMarker += 1
        case .blockedSource: counters.blockedSource += 1
        case .fileOnly: counters.fileOnly += 1
        case .unsupported: counters.unsupported += 1
        }
    }
}
