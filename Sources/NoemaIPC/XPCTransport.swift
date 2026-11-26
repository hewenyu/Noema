import Dispatch
import Foundation
import NoemaCore
import os
import XPC

// libxpc transports (`XPCSession` / `XPCListener`, macOS 26):
//
// - Framing: one `IPCWireCodec` frame per message, as data under key "e" of an
//   `XPCDictionary`, so `SecCodeCreateWithXPCMessage` can resolve the sender of every
//   message. The size cap is checked before a byte is copied out.
// - Identity: the policy's `xpcPeerRequirement` is set on the client session and on every
//   accepted peer session, and `PeerIdentityVerifier.verify(xpcMessage:)` runs on every
//   received message in both directions (server requests, client replies and pushes).
// - Lifetime: an `XPCSession` that is released without `cancel` traps, so sessions are
//   only ever held through `ManagedXPCSession`, which cancels exactly once (explicitly or
//   in `deinit`).

/// The one frame of an XPC message.
public enum XPCFraming {
    public static let envelopeKey = "e"
    /// Set on requests sent with a reply handler, so the server answers with an XPC reply
    /// rather than a push. (Probing with `xpc_dictionary_create_reply` would consume the
    /// reply the XPC overlay builds from the handler's returned dictionary.)
    public static let expectsReplyKey = "r"

    /// A new message dictionary carrying `frame`.
    public static func message(carrying frame: Data, expectingReply: Bool = false) throws(IPCError) -> XPCDictionary {
        let dictionary = xpc_dictionary_create_empty()
        try set(frame, in: dictionary)
        if expectingReply { xpc_dictionary_set_bool(dictionary, expectsReplyKey, true) }
        return XPCDictionary(dictionary)
    }

    static func expectsReply(_ message: xpc_object_t) -> Bool {
        xpc_dictionary_get_bool(message, expectsReplyKey)
    }

    static func set(_ frame: Data, in dictionary: xpc_object_t) throws(IPCError) {
        guard frame.count <= IPCWireLimits.maxPayloadBytes else {
            throw .payloadTooLarge(bytes: frame.count, limit: IPCWireLimits.maxPayloadBytes)
        }
        guard !frame.isEmpty else { throw .malformedFrame }
        frame.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(dictionary, envelopeKey, bytes.baseAddress!, bytes.count)
        }
    }

    /// The frame of a received message; the length is checked before copying.
    public static func frame(of message: xpc_object_t) -> Result<Data, IPCError> {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return .failure(.malformedFrame) }
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, envelopeKey, &length), length > 0 else {
            return .failure(.malformedFrame)
        }
        guard length <= IPCWireLimits.maxPayloadBytes else {
            return .failure(.payloadTooLarge(bytes: length, limit: IPCWireLimits.maxPayloadBytes))
        }
        return .success(Data(bytes: bytes, count: length))
    }
}

/// Owns one `XPCSession` and guarantees it is cancelled exactly once: by `cancel(reason:)`
/// or, failing that, in `deinit`, so dropping the last reference never traps.
///
/// libxpc traps when a session is released uncancelled, and also when a session that was
/// never activated is cancelled or released. So a `ManagedXPCSession` only ever holds an
/// activated session: `init(activating:requirement:)` activates it (a failed activation
/// leaves it invalidated, which is safe to release), and `init(acceptedSession:)` takes a
/// listener-accepted session, which libxpc activates once the accept handler returns.
public final class ManagedXPCSession: @unchecked Sendable {
    private let session: XPCSession
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    /// Sets `requirement` on the inactive `session`, then activates it.
    public init(activating session: XPCSession, requirement: XPCPeerRequirement?) throws {
        if let requirement { session.setPeerRequirement(requirement) }
        try session.activate()
        self.session = session
    }

    init(acceptedSession session: XPCSession) {
        self.session = session
    }

    public var isCancelled: Bool { cancelled.withLock { $0 } }

    /// Idempotent; returns whether this call cancelled the session.
    @discardableResult
    public func cancel(reason: String) -> Bool {
        let first = cancelled.withLock { wasCancelled -> Bool in
            defer { wasCancelled = true }
            return !wasCancelled
        }
        if first { session.cancel(reason: reason) }
        return first
    }

    public func send(_ message: XPCDictionary) throws(IPCError) {
        guard !isCancelled else { throw .cancelled }
        do {
            try session.send(message: message)
        } catch {
            throw .connectionUnavailable(.directASCII)
        }
    }

    public func send(_ message: XPCDictionary, replyHandler: @escaping @Sendable (Result<XPCDictionary, XPCRichError>) -> Void) throws(IPCError) {
        guard !isCancelled else { throw .cancelled }
        session.send(message: message, replyHandler: replyHandler)
    }

    deinit {
        cancel(reason: "deinit")
    }
}

/// Where an `XPCClientTransport` connects.
/// `@unchecked Sendable` keeps Swift 6.2 SDKs (where `XPCEndpoint` lacked a `Sendable`
/// declaration) compiling alongside Swift 6.3 SDKs without warnings.
public enum XPCConnectionTarget: @unchecked Sendable {
    /// The launchd Mach service, e.g. `NoemaPaths.agentMachServiceName`.
    case machService(String)
    /// An anonymous listener's endpoint (tests, or an endpoint handed over by a broker).
    case endpoint(XPCEndpoint)
}

/// `IPCClientTransport` over `XPCSession`. `target` is read on every `connect`, so a
/// restarted anonymous listener is picked up on the next attempt.
public final class XPCClientTransport: IPCClientTransport, @unchecked Sendable {
    private struct State {
        var session: ManagedXPCSession?
        var attemptID: UInt64 = 0
        var events: IPCClientEventHandler?
    }

    private let target: @Sendable () -> XPCConnectionTarget?
    public let policy: PeerIdentityPolicy
    private let queue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = NoemaLog.ipc("xpc-client")

    public init(policy: PeerIdentityPolicy, queue: DispatchQueue, target: @escaping @Sendable () -> XPCConnectionTarget?) {
        self.policy = policy
        self.queue = queue
        self.target = target
    }

    public convenience init(machService: String, policy: PeerIdentityPolicy, queue: DispatchQueue) {
        self.init(policy: policy, queue: queue, target: { .machService(machService) })
    }

    public func connect(attemptID: UInt64, events: @escaping IPCClientEventHandler) throws(IPCError) {
        disconnect(reason: "reconnect")
        // Fail closed before any session exists: no `ime.hello` leaves this process under
        // a policy that would reject every peer anyway.
        guard !policy.isUnpinnedStrict else {
            throw .peerRejected(PeerVerificationError.unpinnedStrictPolicy.description)
        }
        guard let target = target() else { throw .connectionUnavailable(.agentUnavailable) }
        guard let requirement = policy.xpcPeerRequirement else {
            throw .peerRejected(PeerVerificationError.noExpectedSigningIdentifiers.description)
        }
        let policy = policy
        let incoming: @Sendable (XPCDictionary) -> XPCDictionary? = { message in
            Self.receive(message, policy: policy, attemptID: attemptID, events: events)
            return nil
        }
        let cancellation: @Sendable (XPCRichError) -> Void = { error in
            events(attemptID, .disconnected(Self.reason(for: error)))
        }
        let session: XPCSession
        do {
            switch target {
            case .machService(let name):
                session = try XPCSession(
                    machService: name, targetQueue: queue, options: .inactive,
                    incomingMessageHandler: incoming, cancellationHandler: cancellation)
            case .endpoint(let endpoint):
                session = try XPCSession(
                    endpoint: endpoint, targetQueue: queue, options: .inactive,
                    incomingMessageHandler: incoming, cancellationHandler: cancellation)
            }
        } catch {
            throw .connectionUnavailable(.agentUnavailable)
        }
        let managed: ManagedXPCSession
        do {
            managed = try ManagedXPCSession(activating: session, requirement: requirement)
        } catch {
            throw .connectionUnavailable(.agentUnavailable)
        }
        state.withLock {
            $0.session = managed
            $0.attemptID = attemptID
            $0.events = events
        }
    }

    public func send(_ frame: Data, expectingReply: Bool) throws(IPCError) {
        let current = state.withLock { state -> (ManagedXPCSession, UInt64, IPCClientEventHandler)? in
            guard let session = state.session, let events = state.events else { return nil }
            return (session, state.attemptID, events)
        }
        guard let (session, attemptID, events) = current else { throw .connectionUnavailable(.agentUnavailable) }
        let message = try XPCFraming.message(carrying: frame, expectingReply: expectingReply)
        if expectingReply {
            let policy = policy
            try session.send(message) { result in
                // A failed reply means the connection ended; the cancellation handler reports it.
                if case .success(let reply) = result {
                    Self.receive(reply, policy: policy, attemptID: attemptID, events: events)
                }
            }
        } else {
            try session.send(message)
        }
    }

    public func disconnect(reason: String) {
        let session = state.withLock { state -> ManagedXPCSession? in
            defer { state.session = nil; state.events = nil }
            return state.session
        }
        session?.cancel(reason: reason)
    }

    /// Layer 2 on a received message, then the frame.
    static func receive(_ message: XPCDictionary, policy: PeerIdentityPolicy, attemptID: UInt64, events: IPCClientEventHandler) {
        message.withUnsafeUnderlyingDictionary { object in
            switch PeerIdentityVerifier.verify(xpcMessage: object, policy: policy) {
            case .failure(let error):
                events(attemptID, .peerRejected(error.description))
            case .success(let identity):
                switch XPCFraming.frame(of: object) {
                case .success(let frame): events(attemptID, .received(frame, identity))
                case .failure(let error): events(attemptID, .droppedFrame(error))
                }
            }
        }
    }

    static func reason(for error: XPCRichError) -> IPCDegradationReason {
        let description = error.debugDescription.lowercased()
        if description.contains("requirement") || description.contains("code sign") { return .peerRejected }
        if description.contains("lookup") { return .agentUnavailable }
        return .directASCII
    }
}

/// `IPCServerTransport` over `XPCListener`: the launchd Mach service, or an anonymous
/// listener whose `endpoint` tests hand to `XPCClientTransport`.
public final class XPCListenerServerTransport: IPCServerTransport, @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        case machService(String)
        case anonymous
    }

    public enum StartError: Error, Sendable, Equatable {
        /// The Mach service check-in failed; `permissionDenied` (EPERM) means the process
        /// was not started by launchd for that service.
        case checkInFailed(description: String, permissionDenied: Bool)
        case noExpectedSigningIdentifiers
        /// `.strict` without a Team ID or certificate pin: no listener is created.
        case unpinnedStrictPolicy
        case alreadyStarted
    }

    private struct State {
        var listener: XPCListener?
        var handlers: IPCServerHandlers?
        var peers: [IPCPeerID: ManagedXPCSession] = [:]
        var nextPeer: UInt64 = 1
    }

    public let mode: Mode
    public let policy: PeerIdentityPolicy
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = NoemaLog.ipc("xpc-server")

    public init(mode: Mode, policy: PeerIdentityPolicy, queue: DispatchQueue = DispatchQueue(label: "dev.noema.ipc.server")) {
        self.mode = mode
        self.policy = policy
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
    }

    public convenience init(machService: String, policy: PeerIdentityPolicy, queue: DispatchQueue = DispatchQueue(label: "dev.noema.ipc.server")) {
        self.init(mode: .machService(machService), policy: policy, queue: queue)
    }

    /// The anonymous listener's endpoint once started; nil for a Mach service.
    public var endpoint: XPCEndpoint? {
        guard mode == .anonymous else { return nil }
        return state.withLockUnchecked { $0.listener?.endpoint }
    }

    public var connectedPeers: [IPCPeerID] { state.withLock { $0.peers.keys.sorted() } }

    public func start(_ handlers: IPCServerHandlers) throws {
        // Fail closed before the listener exists: no check-in, so the agent never reports
        // `.listening` or posts the ready notification under such a policy.
        guard !policy.isUnpinnedStrict else { throw StartError.unpinnedStrictPolicy }
        guard let requirement = policy.xpcPeerRequirement else { throw StartError.noExpectedSigningIdentifiers }
        guard state.withLock({ $0.listener == nil }) else { throw StartError.alreadyStarted }
        let accept: @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision = { [weak self] request in
            guard let self, self.state.withLock({ $0.listener != nil }) else { return request.reject(reason: "server stopped") }
            return request.accept { session in self.adopt(session) }
        }
        let listener: XPCListener
        switch mode {
        case .machService(let name):
            do {
                listener = try XPCListener(
                    service: name, targetQueue: queue, options: .inactive, requirement: requirement,
                    incomingSessionHandler: accept)
            } catch {
                throw StartError.checkInFailed(description: "\(error)", permissionDenied: Self.isPermissionDenied(error))
            }
        case .anonymous:
            listener = XPCListener(targetQueue: queue, options: .inactive, incomingSessionHandler: accept)
        }
        state.withLock {
            $0.listener = listener
            $0.handlers = handlers
        }
        do {
            try listener.activate()
        } catch {
            state.withLock { $0.listener = nil; $0.handlers = nil }
            listener.cancel()
            throw StartError.checkInFailed(description: "\(error)", permissionDenied: Self.isPermissionDenied(error))
        }
    }

    public func push(_ frame: Data, to peer: IPCPeerID) throws(IPCError) {
        guard let session = state.withLock({ $0.peers[peer] }) else { throw .connectionUnavailable(.agentUnavailable) }
        try session.send(try XPCFraming.message(carrying: frame))
    }

    /// Cancels the listener, waits for any `accept`/`adopt` already running on `queue`
    /// (a session adopted after the listener is gone is cancelled, never tracked), then
    /// cancels every tracked peer session. So no active peer session outlives `stop()`,
    /// and each peer's `peerConnected` precedes its `peerDisconnected`.
    public func stop() {
        let listener = state.withLock { state -> XPCListener? in
            defer { state.listener = nil }
            return state.listener
        }
        listener?.cancel()
        // Barrier, skipped on `queue` itself, where no accept handler can be in flight.
        if listener != nil, DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
        let (peers, handlers) = state.withLock { state -> ([IPCPeerID: ManagedXPCSession], IPCServerHandlers?) in
            defer { state.peers = [:]; state.handlers = nil }
            return (state.peers, state.handlers)
        }
        for (peer, session) in peers.sorted(by: { $0.key < $1.key }) {
            session.cancel(reason: "server stopped")
            handlers?.onEvent(.peerDisconnected(peer))
        }
    }

    /// Cancels one peer's session.
    public func disconnect(_ peer: IPCPeerID, reason: String) {
        let (session, handlers) = state.withLock { ($0.peers.removeValue(forKey: peer), $0.handlers) }
        guard let session else { return }
        session.cancel(reason: reason)
        handlers?.onEvent(.peerDisconnected(peer))
    }

    deinit {
        stop()
    }

    // MARK: - Peers

    private func adopt(_ session: XPCSession) -> PeerSessionHandler {
        // Accepted sessions do not inherit the listener's requirement (<xpc/listener.h>).
        // Rebuild from the Sendable `policy` here instead of capturing `XPCPeerRequirement`
        // across `@Sendable` boundaries (Swift 6.2 SDK compatibility).
        let hasRequirement: Bool
        if let requirement = policy.xpcPeerRequirement {
            session.setPeerRequirement(requirement)
            hasRequirement = true
        } else {
            hasRequirement = false
        }
        let managed = ManagedXPCSession(acceptedSession: session)
        let adopted = state.withLock { state -> (IPCPeerID, IPCServerHandlers?)? in
            let peer = IPCPeerID(rawValue: state.nextPeer)
            state.nextPeer += 1
            // `stop()` ran between accept and adopt, or policy cannot pin peers: never track.
            guard state.listener != nil, hasRequirement else { return nil }
            state.peers[peer] = managed
            return (peer, state.handlers)
        }
        guard let (peer, handlers) = adopted else {
            // libxpc activates the session once the accept handler returns; cancelling it
            // before then would trap, so cancel right after, on the same queue.
            queue.async { managed.cancel(reason: "server stopped") }
            return PeerSessionHandler(transport: nil, peer: IPCPeerID(rawValue: 0))
        }
        handlers?.onEvent(.peerConnected(peer))
        return PeerSessionHandler(transport: self, peer: peer)
    }

    fileprivate func handle(_ message: XPCDictionary, from peer: IPCPeerID) -> XPCDictionary? {
        guard let handlers = state.withLock({ $0.handlers }) else { return nil }
        return message.withUnsafeUnderlyingDictionary { object -> XPCDictionary? in
            let identity: PeerIdentity
            switch PeerIdentityVerifier.verify(xpcMessage: object, policy: policy) {
            case .failure(let error):
                log.error("rejected a message from \(peer.description, privacy: .public): \(error.description, privacy: .public)")
                disconnect(peer, reason: "peer rejected")
                handlers.onEvent(.peerRejected(error.description))
                return nil
            case .success(let verified):
                identity = verified
            }
            guard case .success(let frame) = XPCFraming.frame(of: object) else {
                log.error("dropped a malformed frame from \(peer.description, privacy: .public)")
                return nil
            }
            guard let reply = handlers.onFrame(frame, peer, identity) else { return nil }
            // The XPC overlay builds the reply from the returned fresh dictionary.
            if XPCFraming.expectsReply(object) {
                return try? XPCFraming.message(carrying: reply)
            }
            try? push(reply, to: peer)
            return nil
        }
    }

    fileprivate func peerEnded(_ peer: IPCPeerID) {
        let (session, handlers) = state.withLock { ($0.peers.removeValue(forKey: peer), $0.handlers) }
        guard let session else { return }
        session.cancel(reason: "peer ended")
        handlers?.onEvent(.peerDisconnected(peer))
    }

    static func isPermissionDenied(_ error: any Error) -> Bool {
        let description = "\(error)".lowercased()
        return description.contains("operation not permitted") || description.contains("error 1 ")
    }
}

/// Routes one accepted peer session's messages and cancellation to its transport.
struct PeerSessionHandler: XPCPeerHandler {
    weak var transport: XPCListenerServerTransport?
    let peer: IPCPeerID

    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        transport?.handle(message, from: peer)
    }

    func handleCancellation(error: XPCRichError) {
        transport?.peerEnded(peer)
    }
}
