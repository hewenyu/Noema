import Foundation
import NoemaCore

/// The IME's only producer of IPC traffic on the key path. It turns a composition change
/// into a `compositionStateChanged` with metadata only (no preedit, candidates, or
/// committed text) and hands it to `IPCConnectionManager.sendFireAndForget(_:)`.
///
/// While `isSecureInputEnabled()` is true it sends nothing at all, not even metadata:
/// every report is counted in `suppressedForSecureInput` and dropped.
@MainActor
public final class CompositionIPCReporter {
    private let sink: @Sendable (IMEToAgent) -> Void
    private let isSecureInputEnabled: @MainActor () -> Bool
    private var lastGenerationID: UInt64?

    public private(set) var reportedCount = 0
    public private(set) var suppressedForSecureInput = 0

    /// `sink` receives each message on the main actor and must not block
    /// (`IPCConnectionManager.sendFireAndForget(_:)`).
    public init(sink: @escaping @Sendable (IMEToAgent) -> Void, isSecureInputEnabled: @escaping @MainActor () -> Bool) {
        self.sink = sink
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    public convenience init(manager: IPCConnectionManager, isSecureInputEnabled: @escaping @MainActor () -> Bool) {
        self.init(sink: { [manager] in manager.sendFireAndForget($0) }, isSecureInputEnabled: isSecureInputEnabled)
    }

    /// Reports `state` once per `generationID`.
    public func report(_ state: CompositionState) {
        guard !isSecureInputEnabled() else {
            suppressedForSecureInput += 1
            return
        }
        guard state.generationID != lastGenerationID else { return }
        lastGenerationID = state.generationID
        reportedCount += 1
        // The manager stamps the connection epoch when it sends.
        sink(.compositionStateChanged(CompositionSnapshot(
            sessionEpoch: Self.unstampedEpoch, generationID: state.generationID, isComposing: state.isComposing,
            candidateCount: state.candidates.count, isASCIIMode: state.isASCIIMode)))
    }

    /// Asks the agent to open its Settings window; suppressed under secure input too.
    public func requestOpenSettings(section: SettingsSectionID? = nil) {
        guard !isSecureInputEnabled() else {
            suppressedForSecureInput += 1
            return
        }
        reportedCount += 1
        sink(.openSettingsRequested(section: section))
    }

    static let unstampedEpoch = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
