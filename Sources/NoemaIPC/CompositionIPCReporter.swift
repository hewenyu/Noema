import Foundation
import NoemaCore

/// The IME's only producer of IPC traffic on the key path. It turns a composition change
/// into a `compositionStateChanged` with metadata only (no preedit, candidates, or
/// committed text) and hands it to `IPCConnectionManager.sendFireAndForget(_:)`.
///
/// While `isSecureInputEnabled()` is true it sends nothing at all, not even metadata:
/// every report is counted in `suppressedForSecureInput` and dropped. Every report, sent
/// or not, first updates the local `GenerationGate` through `onLocalComposition`, so a
/// late AI suggestion for a composition the IME no longer shows is dropped either way.
@MainActor
public final class CompositionIPCReporter {
    private let sink: @Sendable (IMEToAgent) -> Void
    private let isSecureInputEnabled: @MainActor () -> Bool
    private let onLocalComposition: (@Sendable (_ generationID: UInt64, _ isComposing: Bool) -> Void)?
    /// The last generation actually sent; a suppressed report never advances it, so the
    /// first state after secure input ends is reported.
    private var lastReportedGenerationID: UInt64?

    public private(set) var reportedCount = 0
    public private(set) var suppressedForSecureInput = 0

    /// `sink` receives each message on the main actor and must not block
    /// (`IPCConnectionManager.sendFireAndForget(_:)`).
    /// `onLocalComposition` must not block either
    /// (`IPCConnectionManager.updateLocalComposition(generationID:isComposing:)`).
    public init(
        sink: @escaping @Sendable (IMEToAgent) -> Void,
        isSecureInputEnabled: @escaping @MainActor () -> Bool,
        onLocalComposition: (@Sendable (_ generationID: UInt64, _ isComposing: Bool) -> Void)? = nil
    ) {
        self.sink = sink
        self.isSecureInputEnabled = isSecureInputEnabled
        self.onLocalComposition = onLocalComposition
    }

    public convenience init(manager: IPCConnectionManager, isSecureInputEnabled: @escaping @MainActor () -> Bool) {
        self.init(
            sink: { [manager] in manager.sendFireAndForget($0) }, isSecureInputEnabled: isSecureInputEnabled,
            onLocalComposition: { [manager] generationID, isComposing in
                manager.updateLocalComposition(generationID: generationID, isComposing: isComposing)
            })
    }

    /// Updates the local gate with `state`, then sends it once per `generationID` unless
    /// secure input is on.
    public func report(_ state: CompositionState) {
        onLocalComposition?(state.generationID, state.isComposing)
        guard !isSecureInputEnabled() else {
            suppressedForSecureInput += 1
            return
        }
        guard state.generationID != lastReportedGenerationID else { return }
        lastReportedGenerationID = state.generationID
        reportedCount += 1
        // The manager stamps the connection epoch when it sends.
        sink(.compositionStateChanged(CompositionSnapshot(
            sessionEpoch: IPCConnectionManager.unstampedEpoch, generationID: state.generationID, isComposing: state.isComposing,
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
}
