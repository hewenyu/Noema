import NoemaCore

/// Shows the candidate menu for a composition. Issue #6 plugs in the real panel.
@MainActor
public protocol CandidatePresenting: AnyObject {
    /// Shows or refreshes the menu for `state` next to `client`'s marked text.
    func update(state: CompositionState, client: any TextInputClient)
    /// Hides the menu. Idempotent.
    func hide()
}

/// Presents nothing: the placeholder until the candidate panel lands.
@MainActor
public final class NoOpCandidatePresenter: CandidatePresenting {
    public init() {}
    public func update(state: CompositionState, client: any TextInputClient) {}
    public func hide() {}
}
