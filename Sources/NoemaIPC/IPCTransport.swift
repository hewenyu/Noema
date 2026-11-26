import Dispatch
import Foundation
import os

// Transports move opaque frames (one `IPCWireCodec`-encoded envelope each) and report
// lifecycle events; they know nothing about message kinds, generations, or retries, which
// `IPCConnectionManager` and `AgentServiceCoordinator` own. `XPCTransport.swift` holds the
// libxpc implementation; `InMemoryClientTransport`/`InMemoryServerTransport` below are the
// deterministic in-process pair with fault injection.

/// What a client transport reports for one connection attempt.
public enum IPCClientEvent: Sendable, Equatable {
    /// A verified inbound frame: a reply or a server push.
    case received(Data, PeerIdentity?)
    /// The connection ended (peer died, interrupted, invalidated).
    case disconnected(IPCDegradationReason)
    /// A frame's sender failed `PeerIdentityVerifier`.
    case peerRejected(String)
    /// A frame was dropped before decoding (oversized, missing payload).
    case droppedFrame(IPCError)
}

/// Delivers events tagged with the `attemptID` passed to `connect`, from any thread.
public typealias IPCClientEventHandler = @Sendable (_ attemptID: UInt64, _ event: IPCClientEvent) -> Void

public protocol IPCClientTransport: AnyObject, Sendable {
    /// Starts connection attempt `attemptID`. Throws when the attempt fails at once; a
    /// transport may also report `.disconnected` for the same attempt (libxpc does both on
    /// a Mach lookup failure), which the caller must ignore for a thrown attempt.
    func connect(attemptID: UInt64, events: @escaping IPCClientEventHandler) throws(IPCError)
    /// Sends one frame without waiting. With `expectingReply`, the reply arrives as
    /// `.received` for the current attempt.
    func send(_ frame: Data, expectingReply: Bool) throws(IPCError)
    /// Ends the current attempt; events of that attempt may still arrive and are stale.
    func disconnect(reason: String)
}

/// A connected client as the server sees it.
public struct IPCPeerID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "peer#\(rawValue)" }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum IPCServerEvent: Sendable, Equatable {
    case peerConnected(IPCPeerID)
    case peerDisconnected(IPCPeerID)
    /// A peer, or one of its frames, failed verification; the peer is disconnected.
    case peerRejected(String)
}

/// Callbacks a server transport invokes on its queue.
public struct IPCServerHandlers: Sendable {
    /// A verified frame from `peer`; the returned frame is the reply (an XPC reply when
    /// the message expects one, otherwise a push to the same peer).
    public var onFrame: @Sendable (_ frame: Data, _ peer: IPCPeerID, _ identity: PeerIdentity?) -> Data?
    public var onEvent: @Sendable (IPCServerEvent) -> Void

    public init(
        onFrame: @escaping @Sendable (Data, IPCPeerID, PeerIdentity?) -> Data?,
        onEvent: @escaping @Sendable (IPCServerEvent) -> Void = { _ in }
    ) {
        self.onFrame = onFrame
        self.onEvent = onEvent
    }
}

public protocol IPCServerTransport: AnyObject, Sendable {
    /// Starts accepting peers. Throws when the listener cannot start (for a Mach service,
    /// a process launchd did not start cannot check in).
    func start(_ handlers: IPCServerHandlers) throws
    /// Pushes one frame to `peer` without waiting.
    func push(_ frame: Data, to peer: IPCPeerID) throws(IPCError)
    /// Stops listening and disconnects every peer. Idempotent.
    func stop()
    var connectedPeers: [IPCPeerID] { get }
}

// MARK: - In-memory transport

/// Faults an `InMemoryClientTransport` injects, all deterministic.
public struct InMemoryFaults: Sendable, Equatable {
    /// The next N `connect` calls throw `.connectionUnavailable(.agentUnavailable)`.
    public var failingConnects = 0
    /// A failing `connect` also reports `.disconnected` for its attempt before throwing,
    /// like libxpc on a Mach lookup failure (the double-callback case).
    public var reportsDisconnectOnConnectFailure = false
    /// `connect` succeeds, then the attempt is rejected like a failed peer requirement.
    public var rejectsPeer = false
    /// Inbound frames wait in `heldInbound` until `releaseHeld(reversed:)`.
    public var holdsInbound = false
    /// Every inbound frame is delivered twice.
    public var duplicatesInbound = false
    /// Inbound frames are delivered after this delay on the transport's clock.
    public var inboundLatency: Duration = .zero

    public init() {}
}

/// The server half of the in-memory pair. Frames are handled synchronously on the
/// caller's thread; `simulatedClientIdentity` stands in for the verified sender.
public final class InMemoryServerTransport: IPCServerTransport, @unchecked Sendable {
    private struct State {
        var handlers: IPCServerHandlers?
        var peers: [IPCPeerID: InMemoryClientTransport] = [:]
        var nextPeer: UInt64 = 1
        var receivedFrames: [Data] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    public let simulatedClientIdentity: PeerIdentity?

    public init(simulatedClientIdentity: PeerIdentity? = nil) {
        self.simulatedClientIdentity = simulatedClientIdentity
    }

    public func start(_ handlers: IPCServerHandlers) throws {
        state.withLock { $0.handlers = handlers }
    }

    public var isRunning: Bool { state.withLock { $0.handlers != nil } }
    public var connectedPeers: [IPCPeerID] { state.withLock { $0.peers.keys.sorted() } }
    /// Every frame the server has received, in order.
    public var receivedFrames: [Data] { state.withLock { $0.receivedFrames } }

    public func push(_ frame: Data, to peer: IPCPeerID) throws(IPCError) {
        guard let client = state.withLock({ $0.peers[peer] }) else { throw .connectionUnavailable(.agentUnavailable) }
        client.deliverInbound(frame)
    }

    /// Like the agent process dying: every peer sees `.disconnected(.directASCII)`.
    public func stop() {
        let (peers, handlers) = state.withLock { state -> ([IPCPeerID: InMemoryClientTransport], IPCServerHandlers?) in
            defer { state.handlers = nil; state.peers = [:] }
            return (state.peers, state.handlers)
        }
        for (peer, client) in peers.sorted(by: { $0.key < $1.key }) {
            client.serverDropped()
            handlers?.onEvent(.peerDisconnected(peer))
        }
    }

    /// Drops one peer, as when the server cancels its session.
    public func disconnect(_ peer: IPCPeerID) {
        let (client, handlers) = state.withLock { ($0.peers.removeValue(forKey: peer), $0.handlers) }
        client?.serverDropped()
        if client != nil { handlers?.onEvent(.peerDisconnected(peer)) }
    }

    fileprivate func attach(_ client: InMemoryClientTransport) throws(IPCError) -> IPCPeerID {
        let attached = state.withLock { state -> (IPCPeerID, IPCServerHandlers)? in
            guard let handlers = state.handlers else { return nil }
            let peer = IPCPeerID(rawValue: state.nextPeer)
            state.nextPeer += 1
            state.peers[peer] = client
            return (peer, handlers)
        }
        guard let (peer, handlers) = attached else { throw .connectionUnavailable(.agentUnavailable) }
        handlers.onEvent(.peerConnected(peer))
        return peer
    }

    fileprivate func detach(_ peer: IPCPeerID) {
        let (removed, handlers) = state.withLock { ($0.peers.removeValue(forKey: peer), $0.handlers) }
        if removed != nil { handlers?.onEvent(.peerDisconnected(peer)) }
    }

    fileprivate func handle(_ frame: Data, from peer: IPCPeerID) throws(IPCError) -> Data? {
        let handlers = state.withLock { state -> IPCServerHandlers? in
            guard state.peers[peer] != nil else { return nil }
            state.receivedFrames.append(frame)
            return state.handlers
        }
        guard let handlers else { throw .connectionUnavailable(.agentUnavailable) }
        return handlers.onFrame(frame, peer, simulatedClientIdentity)
    }
}

/// The client half of the in-memory pair, with `faults` applied to every call.
public final class InMemoryClientTransport: IPCClientTransport, @unchecked Sendable {
    private struct State {
        var faults = InMemoryFaults()
        var server: InMemoryServerTransport?
        var peer: IPCPeerID?
        var attemptID: UInt64 = 0
        var events: IPCClientEventHandler?
        var held: [Data] = []
        var sentFrames: [Data] = []
        var connectCalls = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let clock: any IPCClock
    private let latencyQueue = DispatchQueue(label: "dev.noema.ipc.inmemory.latency")
    public let simulatedServerIdentity: PeerIdentity?

    public init(server: InMemoryServerTransport?, clock: any IPCClock = SystemIPCClock(), simulatedServerIdentity: PeerIdentity? = nil) {
        var initial = State()
        initial.server = server
        state = OSAllocatedUnfairLock(initialState: initial)
        self.clock = clock
        self.simulatedServerIdentity = simulatedServerIdentity
    }

    public var faults: InMemoryFaults {
        get { state.withLock { $0.faults } }
        set { state.withLock { $0.faults = newValue } }
    }

    /// Points later `connect` calls at another server (an agent that came back).
    public func setServer(_ server: InMemoryServerTransport?) { state.withLock { $0.server = server } }

    public var isConnected: Bool { state.withLock { $0.peer != nil } }
    public var connectCalls: Int { state.withLock { $0.connectCalls } }
    /// Every frame `send` accepted, in order.
    public var sentFrames: [Data] { state.withLock { $0.sentFrames } }
    public var heldInbound: [Data] { state.withLock { $0.held } }

    public func connect(attemptID: UInt64, events: @escaping IPCClientEventHandler) throws(IPCError) {
        let (faults, server) = state.withLock { state -> (InMemoryFaults, InMemoryServerTransport?) in
            state.connectCalls += 1
            let snapshot = state.faults
            if state.faults.failingConnects > 0 { state.faults.failingConnects -= 1 }
            return (snapshot, state.server)
        }
        if faults.failingConnects > 0 {
            if faults.reportsDisconnectOnConnectFailure { events(attemptID, .disconnected(.agentUnavailable)) }
            throw .connectionUnavailable(.agentUnavailable)
        }
        guard let server else { throw .connectionUnavailable(.agentUnavailable) }
        let peer = try server.attach(self)
        state.withLock {
            $0.peer = peer
            $0.attemptID = attemptID
            $0.events = events
        }
        if faults.rejectsPeer {
            events(attemptID, .peerRejected("simulated peer requirement failure"))
        }
    }

    public func send(_ frame: Data, expectingReply: Bool) throws(IPCError) {
        guard frame.count <= IPCWireLimits.maxPayloadBytes else {
            throw .payloadTooLarge(bytes: frame.count, limit: IPCWireLimits.maxPayloadBytes)
        }
        let target = state.withLock { state -> (InMemoryServerTransport, IPCPeerID)? in
            guard let server = state.server, let peer = state.peer else { return nil }
            state.sentFrames.append(frame)
            return (server, peer)
        }
        guard let (server, peer) = target else { throw .connectionUnavailable(.agentUnavailable) }
        if let reply = try server.handle(frame, from: peer) {
            deliverInbound(reply)
        }
    }

    public func disconnect(reason: String) {
        let detached = state.withLock { state -> (InMemoryServerTransport, IPCPeerID)? in
            defer { state.peer = nil; state.events = nil; state.held = [] }
            guard let server = state.server, let peer = state.peer else { return nil }
            return (server, peer)
        }
        if let (server, peer) = detached { server.detach(peer) }
    }

    /// Delivers a frame the test crafted (a stale generation, a prior epoch) as if the
    /// server had sent it, through the same fault pipeline.
    public func injectInbound(_ frame: Data) { deliverInbound(frame) }

    /// Delivers held frames, newest first when `reversed` (out-of-order replies).
    public func releaseHeld(reversed: Bool = false) {
        let (held, attemptID, events) = state.withLock { state -> ([Data], UInt64, IPCClientEventHandler?) in
            defer { state.held = [] }
            return (state.held, state.attemptID, state.events)
        }
        guard let events else { return }
        for frame in reversed ? held.reversed() : held {
            events(attemptID, .received(frame, simulatedServerIdentity))
        }
    }

    fileprivate func deliverInbound(_ frame: Data) {
        let delivery = state.withLock { state -> (UInt64, IPCClientEventHandler, InMemoryFaults)? in
            guard let events = state.events else { return nil }
            if state.faults.holdsInbound {
                state.held.append(frame)
                return nil
            }
            return (state.attemptID, events, state.faults)
        }
        guard let (attemptID, events, faults) = delivery else { return }
        let identity = simulatedServerIdentity
        let deliver: @Sendable () -> Void = {
            events(attemptID, .received(frame, identity))
            if faults.duplicatesInbound { events(attemptID, .received(frame, identity)) }
        }
        if faults.inboundLatency > .zero {
            _ = clock.schedule(after: faults.inboundLatency, on: latencyQueue, deliver)
        } else {
            deliver()
        }
    }

    fileprivate func serverDropped() {
        let delivery = state.withLock { state -> (UInt64, IPCClientEventHandler)? in
            defer { state.peer = nil; state.events = nil; state.held = [] }
            guard let events = state.events else { return nil }
            return (state.attemptID, events)
        }
        if let (attemptID, events) = delivery { events(attemptID, .disconnected(.directASCII)) }
    }
}
