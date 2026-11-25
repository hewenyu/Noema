import CRime
import Foundation
import NoemaCore
import Synchronization

/// Process-wide librime lifecycle. librime is a singleton (one deployer, one service, one
/// set of sessions per process), so:
/// - `RimeApi.setup` runs at most once per process (`setupIfNeeded`);
/// - at most one owner holds an initialized librime at a time (`claim`/`release`); a second
///   `RimeEngine` created while the first still owns librime fails deterministically.
enum RimeProcessLifecycle {
    private struct State {
        var hasSetup = false
        var activeOwner: UUID?
    }

    private static let state = Mutex(State())

    /// Claims librime for `owner`. Throws when another owner holds it.
    static func claim(_ owner: UUID) throws(NoemaError) {
        let claimed = state.withLock { state -> Bool in
            if let active = state.activeOwner, active != owner { return false }
            state.activeOwner = owner
            return true
        }
        guard claimed else {
            throw .engineUnavailable(reason: "another RimeEngine owns librime in this process; shut it down first")
        }
    }

    /// Releases librime if `owner` holds it. Idempotent.
    static func release(_ owner: UUID) {
        state.withLock { state in
            if state.activeOwner == owner { state.activeOwner = nil }
        }
    }

    static func isOwned(by owner: UUID) -> Bool {
        state.withLock { $0.activeOwner == owner }
    }

    /// Calls `RimeApi.setup` the first time any engine boots in this process. Only the
    /// current owner may call it.
    static func setupIfNeeded(owner: UUID, api: UnsafeMutablePointer<RimeApi>, traits: inout RimeTraits) {
        state.withLock { state in
            guard state.activeOwner == owner, !state.hasSetup else { return }
            api.pointee.setup(&traits)
            state.hasSetup = true
        }
    }
}

/// What a live engine holds: its librime session, the user-data lock, and its claim on
/// librime. `RimeEngine` releases it in `shutdown()`; if an engine is dropped without
/// that, `deinit` here returns everything (destroy session, finalize, unlock, unclaim),
/// so a leaked engine never blocks the next one.
///
/// `@unchecked Sendable`: the owning engine touches it only on the main actor, and
/// `deinit` runs only after the last reference is gone.
final class RimeEngineResources: @unchecked Sendable {
    let owner = UUID()
    let bootGuard: BootGuard
    var session: RimeSessionId = 0
    /// True between a successful `initialize` and `finalize`.
    var isInitialized = false

    init(bootGuard: BootGuard) {
        self.bootGuard = bootGuard
    }

    /// Destroys the session and finalizes librime if initialized. Keeps the claim and lock.
    func finalizeRime() {
        guard let api = noema_rime_get_api() else { return }
        if session != 0 {
            _ = api.pointee.destroy_session(session)
            session = 0
        }
        if isInitialized {
            api.pointee.finalize()
            isInitialized = false
        }
    }

    /// Finalizes librime, drops the user-data lock, and releases the process claim.
    func releaseAll() {
        if RimeProcessLifecycle.isOwned(by: owner) { finalizeRime() }
        bootGuard.releaseLock()
        RimeProcessLifecycle.release(owner)
    }

    deinit {
        releaseAll()
    }
}
