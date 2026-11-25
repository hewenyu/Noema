import Foundation
import NoemaCore

/// How the presenter shows one composition.
public struct CandidatePresentationOptions: Sendable, Hashable {
    /// True when the client receives no marked text, so the panel draws the preedit and
    /// its caret itself (clients listed in `inlinePreeditDisabledBundleIDs`).
    public var rendersPreeditInPanel: Bool
    /// The session that owns the composition; the presenter keys per-client state by the
    /// client's unique identifier and falls back to this token.
    public var sessionToken: UUID?

    public init(rendersPreeditInPanel: Bool = false, sessionToken: UUID? = nil) {
        self.rendersPreeditInPanel = rendersPreeditInPanel
        self.sessionToken = sessionToken
    }
}

/// Shows the candidate menu for a composition. `NoemaUI.CandidatePanelController` is the
/// shipped implementation.
@MainActor
public protocol CandidatePresenting: AnyObject {
    /// Shows or refreshes the menu for `state` next to `client`'s caret.
    func update(state: CompositionState, client: any TextInputClient, options: CandidatePresentationOptions)
    /// Hides the menu. Idempotent.
    func hide()
}

extension CandidatePresenting {
    /// Shows `state` with inline marked text (default options).
    public func update(state: CompositionState, client: any TextInputClient) {
        update(state: state, client: client, options: CandidatePresentationOptions())
    }
}

/// Presents nothing: for hosts without a window server and for tests of other parts.
@MainActor
public final class NoOpCandidatePresenter: CandidatePresenting {
    public init() {}
    public func update(state: CompositionState, client: any TextInputClient, options: CandidatePresentationOptions) {}
    public func hide() {}
}
