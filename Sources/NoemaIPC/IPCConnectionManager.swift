import Darwin
import Dispatch
import Foundation
import NoemaCore
import notify
import os

/// Why the IME is not talking to the agent. Typing never depends on the agent: in every
/// degraded state the IME keeps its local `RimeEngine` and sends nothing.
public enum IPCDegradationReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The connection dropped (agent killed, interrupted, invalidated).
    case directASCII
    /// The agent could not be reached (no Mach service, lookup failed).
    case agentUnavailable
    /// The agent's code signature failed the peer policy.
    case peerRejected
    /// No `helloAck` or `heartbeatAck` within `IPCReconnectPolicy.handshakeTimeout`.
    case timeout
    case circuitOpen
}

public enum IPCConnectionState: Sendable, Hashable {
    /// Not started, or stopped.
    case idle
    /// Attempt `attempt` is waiting for `helloAck`.
    case connecting(attempt: Int)
    case healthy
    /// The connection failed; a retry is scheduled next.
    case degraded(IPCDegradationReason)
    /// Retry `attempt` runs after `nextRetryDelay` (exponential backoff plus jitter).
    case reconnecting(attempt: Int, nextRetryDelay: Duration)
    /// `failures` consecutive failures: no attempt until `cooldownUntil`, then one probe.
    case circuitOpen(failures: Int, cooldownUntil: IPCInstant)

    public var isHealthy: Bool { self == .healthy }
}

/// Backoff, circuit breaker, liveness, and hot-path buffer limits.
public struct IPCReconnectPolicy: Sendable, Hashable {
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// Jitter up to `delay * jitterFraction` is added to every backoff delay.
    public var jitterFraction: Double
    /// Consecutive failures that open the circuit.
    public var circuitBreakerThreshold: Int
    public var circuitCooldown: Duration
    /// Wait for `helloAck` and each `heartbeatAck`.
    public var handshakeTimeout: Duration
    /// Heartbeat period while healthy; nil disables heartbeats.
    public var heartbeatInterval: Duration?
    /// Agent-ready notifications closer together than this are ignored.
    public var readyDebounce: Duration
    /// Messages waiting for the IPC queue; composition updates coalesce in place.
    public var outboxCapacity: Int

    public init(
        baseDelay: Duration = .milliseconds(200), maxDelay: Duration = .seconds(10), jitterFraction: Double = 0.2,
        circuitBreakerThreshold: Int = 5, circuitCooldown: Duration = .seconds(30),
        handshakeTimeout: Duration = .milliseconds(500), heartbeatInterval: Duration? = .seconds(15),
        readyDebounce: Duration = .milliseconds(100), outboxCapacity: Int = 32
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
        self.circuitBreakerThreshold = max(1, circuitBreakerThreshold)
        self.circuitCooldown = circuitCooldown
        self.handshakeTimeout = handshakeTimeout
        self.heartbeatInterval = heartbeatInterval
        self.readyDebounce = max(readyDebounce, .milliseconds(100))
        self.outboxCapacity = max(1, outboxCapacity)
    }

    public static let `default` = IPCReconnectPolicy()

    /// `baseDelay * 2^(failures - 1)`, capped at `maxDelay`, before jitter.
    public func backoff(afterFailures failures: Int) -> Duration {
        let exponent = min(max(failures - 1, 0), 30)
        let delay = baseDelay * (1 << exponent)
        return min(delay, maxDelay)
    }
}

/// Drops agent messages that belong to another connection or that a newer message of the
/// same kind already superseded, and AI suggestions for a composition that moved on.
public struct GenerationGate: Sendable, Hashable {
    public enum Decision: String, Sendable, Hashable, CaseIterable {
        case accept
        /// The message names another `sessionEpoch` (a previous connection).
        case epochMismatch
        /// `generationID` is below the kind's watermark (out of order).
        case stale
        /// `generationID` equals the kind's watermark (delivered twice).
        case duplicate
        /// An AI suggestion for a composition generation other than the current one.
        case notCurrentComposition
        /// The envelope carries no `generationID`.
        case missingGeneration
    }

    public private(set) var sessionEpoch: UUID
    public private(set) var currentCompositionGenerationID: UInt64?
    public private(set) var watermarks: [String: UInt64] = [:]
    public private(set) var drops: [Decision: Int] = [:]

    public init(sessionEpoch: UUID) {
        self.sessionEpoch = sessionEpoch
    }

    /// Every dropped message since creation.
    public var droppedCount: Int { drops.values.reduce(0, +) }

    /// A new connection: new epoch, no watermarks. Drop counters persist.
    public mutating func reset(sessionEpoch: UUID) {
        self.sessionEpoch = sessionEpoch
        watermarks = [:]
    }

    /// The composition the IME shows now; only suggestions for it are admitted.
    public mutating func noteComposition(generationID: UInt64) {
        currentCompositionGenerationID = generationID
    }

    public mutating func admit(_ envelope: IPCEnvelope<AgentToIME>) -> Decision {
        let decision = decide(envelope)
        if decision == .accept {
            watermarks[envelope.kind] = generation(of: envelope)
        } else {
            drops[decision, default: 0] += 1
        }
        return decision
    }

    private func generation(of envelope: IPCEnvelope<AgentToIME>) -> UInt64? {
        if case .aiSuggestion(let suggestion) = envelope.payload { return suggestion.generationID }
        return envelope.generationID
    }

    private func decide(_ envelope: IPCEnvelope<AgentToIME>) -> Decision {
        guard envelope.payload.sessionEpoch == sessionEpoch else { return .epochMismatch }
        guard let generation = generation(of: envelope) else { return .missingGeneration }
        if case .aiSuggestion = envelope.payload, let declared = envelope.generationID, declared != generation {
            return .stale
        }
        if let watermark = watermarks[envelope.kind] {
            if generation < watermark { return .stale }
            if generation == watermark { return .duplicate }
        }
        if case .aiSuggestion = envelope.payload, generation != currentCompositionGenerationID {
            return .notCurrentComposition
        }
        return .accept
    }
}

/// Counters for observability and tests.
public struct IPCStatistics: Sendable, Hashable {
    public var connectAttempts = 0
    public var failures = 0
    public var framesSent = 0
    public var framesReceived = 0
    public var coalesced = 0
    /// `sendFireAndForget` calls dropped because the connection was not healthy.
    public var droppedWhileUnhealthy = 0
    public var droppedOutboxFull = 0
    /// Queued messages discarded when the connection failed.
    public var discardedOnFailure = 0
    public var malformedFrames = 0
    /// Transport callbacks for an attempt that is not current (thrown or superseded).
    public var ignoredStaleCallbacks = 0
    public var readySignals = 0
    public var debouncedReadySignals = 0
    /// Ready signals ignored because this open circuit already used its one ready probe.
    public var rateLimitedReadySignals = 0
    /// `helloAck` outside `.connecting` or `heartbeatAck` outside `.healthy`, ignored.
    public var ignoredOutOfStateMessages = 0
    /// `settingsSnapshot`s older than the applied settings revision, ignored.
    public var staleSettingsRevisions = 0
    public var gateDrops: [GenerationGate.Decision: Int] = [:]

    public init() {}
}

/// The IME side of the agent connection: connects, handshakes, keeps it alive, degrades
/// and reconnects, and gates everything the agent sends.
///
/// Threading: every transport call, timer, and callback runs on `queue`, a private serial
/// queue. `sendFireAndForget(_:)` is the only hot-path entry: it takes one unfair lock for
/// O(capacity) work and at most enqueues one block, never waits on XPC, and drops in O(1)
/// while the connection is not healthy.
public final class IPCConnectionManager: @unchecked Sendable {
    public struct ClientInfo: Sendable, Hashable {
        public var bundleID: String
        public var version: String
        public init(bundleID: String, version: String) {
            self.bundleID = bundleID
            self.version = version
        }
    }

    private struct Core {
        var running = false
        var state: IPCConnectionState = .idle
        var nextAttemptID: UInt64 = 1
        /// The attempt whose events count; 0 while none is installed.
        var currentAttemptID: UInt64 = 0
        var consecutiveFailures = 0
        var gate = GenerationGate(sessionEpoch: UUID())
        var outbox: [IMEToAgent] = []
        var drainScheduled = false
        var sequence: UInt64 = 0
        var helloGeneration: UInt64 = 0
        var heartbeatGeneration: UInt64 = 0
        var engineMode = "booting"
        var retryTimer: (any IPCCancellable)?
        var livenessTimer: (any IPCCancellable)?
        var heartbeatTimer: (any IPCCancellable)?
        /// Bumped whenever timers are cancelled, so a timer that already fired is ignored.
        var timerEpoch: UInt64 = 0
        var lastReadySignal: IPCInstant?
        /// The ready notification is unauthenticated: an open circuit honours one
        /// ready-triggered probe, then waits out its cooldown. Reset on `.healthy` and
        /// when a cooldown elapses.
        var readyProbeUsedInCurrentCircuit = false
        /// The revision of `settings`; a `settingsSnapshot` below it is ignored.
        var lastAppliedSettingsRevision: UInt64 = 0
        var notifyToken: Int32 = NOTIFY_TOKEN_INVALID
        var settings: AgentSettingsSnapshot?
        var statistics = IPCStatistics()
        var onStateChange: (@Sendable (IPCConnectionState) -> Void)?
        var onMessage: (@Sendable (AgentToIME) -> Void)?
    }

    public let queue: DispatchQueue
    public let policy: IPCReconnectPolicy
    private let transport: any IPCClientTransport
    private let client: ClientInfo
    private let clock: any IPCClock
    private let jitter: any JitterSource
    private let readyNotificationName: String?
    private let core = OSAllocatedUnfairLock(initialState: Core())
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let log = NoemaLog.ipc("connection")

    public init(
        transport: any IPCClientTransport,
        client: ClientInfo,
        policy: IPCReconnectPolicy = .default,
        clock: any IPCClock = SystemIPCClock(),
        jitter: any JitterSource = SystemJitter(),
        readyNotificationName: String? = NoemaPaths.agentReadyNotificationName,
        queue: DispatchQueue = DispatchQueue(label: "dev.noema.ipc.connection", qos: .utility)
    ) {
        self.transport = transport
        self.client = client
        self.policy = policy
        self.clock = clock
        self.jitter = jitter
        self.readyNotificationName = readyNotificationName
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Dropped without `stop()`: release the notification and every timer.
    deinit {
        let token = core.withLock { core -> Int32 in
            cancelTimers(&core)
            defer { core.notifyToken = NOTIFY_TOKEN_INVALID }
            return core.notifyToken
        }
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }

    // MARK: - Observation

    public var state: IPCConnectionState { core.withLock { $0.state } }
    public var statistics: IPCStatistics {
        core.withLock { core in
            var statistics = core.statistics
            statistics.gateDrops = core.gate.drops
            return statistics
        }
    }
    public var gate: GenerationGate { core.withLock { $0.gate } }
    public var sessionEpoch: UUID { core.withLock { $0.gate.sessionEpoch } }
    /// The latest settings from `helloAck` or `settingsSnapshot`.
    public var agentSettings: AgentSettingsSnapshot? { core.withLock { $0.settings } }
    public var consecutiveFailures: Int { core.withLock { $0.consecutiveFailures } }

    /// Called on `queue` after every state change.
    public func setStateObserver(_ observer: (@Sendable (IPCConnectionState) -> Void)?) {
        core.withLock { $0.onStateChange = observer }
    }

    /// Called on `queue` with every agent message the gate admits.
    public func setMessageHandler(_ handler: (@Sendable (AgentToIME) -> Void)?) {
        core.withLock { $0.onMessage = handler }
    }

    /// Reported in the next `hello` (`rime`, `safeMode`, `booting`, `unavailable`).
    public func setEngineMode(_ mode: String) {
        core.withLock { $0.engineMode = mode }
    }

    /// Runs `body` on `queue` and waits: for tests and shutdown, never on the hot path.
    public func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    // MARK: - Lifecycle

    /// Starts connecting off the caller's thread and subscribes to the agent-ready
    /// notification. Returns at once.
    public func start() {
        queue.async { [self] in
            let alreadyRunning = core.withLock { core -> Bool in
                defer { core.running = true }
                return core.running
            }
            guard !alreadyRunning else { return }
            subscribeToReadyNotification()
            attempt()
        }
    }

    /// Disconnects, cancels timers and the notification, and returns once done. Safe to
    /// call from any thread, repeatedly.
    public func stop() {
        sync {
            let (wasRunning, token) = core.withLock { core -> (Bool, Int32) in
                defer {
                    core.running = false
                    core.currentAttemptID = 0
                    core.outbox.removeAll()
                    core.notifyToken = NOTIFY_TOKEN_INVALID
                }
                cancelTimers(&core)
                return (core.running, core.notifyToken)
            }
            if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
            guard wasRunning else { return }
            transport.disconnect(reason: "stopped")
            setState(.idle)
        }
    }

    // MARK: - Hot path

    /// Queues `message` for the agent and returns at once; never blocks on XPC. Dropped in
    /// O(1) unless healthy. A `compositionStateChanged` replaces the queued one (latest
    /// wins); others are dropped when `outboxCapacity` is reached. The message's epoch is
    /// stamped when it is sent.
    public func sendFireAndForget(_ message: IMEToAgent) {
        let capacity = policy.outboxCapacity
        let schedule = core.withLock { core -> Bool in
            if case .compositionStateChanged(let snapshot) = message {
                core.gate.noteComposition(generationID: snapshot.generationID)
            }
            guard core.state == .healthy else {
                core.statistics.droppedWhileUnhealthy += 1
                return false
            }
            if case .compositionStateChanged = message,
                let index = core.outbox.lastIndex(where: { if case .compositionStateChanged = $0 { true } else { false } })
            {
                core.outbox[index] = message
                core.statistics.coalesced += 1
            } else if core.outbox.count >= capacity {
                core.statistics.droppedOutboxFull += 1
                return false
            } else {
                core.outbox.append(message)
            }
            guard !core.drainScheduled else { return false }
            core.drainScheduled = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// The agent announced it is up: retry now instead of waiting out the backoff or
    /// cooldown. Debounced by `policy.readyDebounce`.
    public func agentReadySignalReceived() {
        queue.async { [self] in handleReadySignal() }
    }

    // MARK: - Queue-confined work

    private func subscribeToReadyNotification() {
        guard let name = readyNotificationName else { return }
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(name, &token, queue) { [weak self] (_: Int32) in
            self?.handleReadySignal()
        }
        if status == UInt32(NOTIFY_STATUS_OK) {
            let registered = token
            core.withLock { $0.notifyToken = registered }
        } else {
            log.error("notify_register_dispatch failed: \(status, privacy: .public)")
        }
    }

    private func attempt() {
        let prepared = core.withLock { core -> (UInt64, UUID, UInt64, String, Int)? in
            guard core.running else { return nil }
            cancelTimers(&core)
            let attemptID = core.nextAttemptID
            core.nextAttemptID += 1
            core.currentAttemptID = 0
            let epoch = UUID()
            core.gate.reset(sessionEpoch: epoch)
            core.helloGeneration += 1
            core.statistics.connectAttempts += 1
            return (attemptID, epoch, core.helloGeneration, core.engineMode, core.consecutiveFailures + 1)
        }
        guard let (attemptID, epoch, helloGeneration, engineMode, attemptNumber) = prepared else { return }
        // The observer may call `stop()`; never connect after that.
        guard setState(.connecting(attempt: attemptNumber)) else { return }
        do {
            try transport.connect(attemptID: attemptID) { [weak self] attemptID, event in
                guard let self else { return }
                self.queue.async { self.handle(event, attemptID: attemptID) }
            }
        } catch {
            // Never installed: callbacks the failed attempt still delivers are stale.
            fail(Self.reason(for: error))
            return
        }
        let installed = core.withLock { core -> Bool in
            guard core.running else { return false }
            core.currentAttemptID = attemptID
            return true
        }
        guard installed else {
            transport.disconnect(reason: "stopped")
            return
        }
        let hello = IMEToAgent.hello(IMEHello(
            clientBundleID: client.bundleID, clientVersion: client.version, sessionEpoch: epoch, engineMode: engineMode))
        guard send(hello, generationID: helloGeneration, expectingReply: true) else { return }
        armLivenessTimer()
    }

    private func handle(_ event: IPCClientEvent, attemptID: UInt64) {
        let current = core.withLock { core -> Bool in
            guard core.running, attemptID != 0, attemptID == core.currentAttemptID else {
                core.statistics.ignoredStaleCallbacks += 1
                return false
            }
            return true
        }
        guard current else { return }
        switch event {
        case .received(let frame, _):
            receive(frame)
        case .disconnected(let reason):
            fail(reason)
        case .peerRejected(let description):
            log.error("agent rejected: \(description, privacy: .public)")
            fail(.peerRejected)
        case .droppedFrame:
            core.withLock { $0.statistics.malformedFrames += 1 }
        }
    }

    private func receive(_ frame: Data) {
        let envelope: IPCEnvelope<AgentToIME>
        do {
            envelope = try IPCWireCodec.decode(AgentToIME.self, from: frame)
        } catch {
            core.withLock { $0.statistics.malformedFrames += 1 }
            return
        }
        let outcome = core.withLock { core -> (GenerationGate.Decision, (@Sendable (AgentToIME) -> Void)?) in
            core.statistics.framesReceived += 1
            guard envelope.isConsistent else {
                core.statistics.malformedFrames += 1
                return (.missingGeneration, nil)
            }
            return (core.gate.admit(envelope), core.onMessage)
        }
        guard outcome.0 == .accept else { return }
        switch envelope.payload {
        case .helloAck(let ack):
            // Only the handshake of the current attempt: a late or repeated ack can neither
            // reset the failure count nor replace newer settings.
            let accepted = core.withLock { core -> Bool in
                guard case .connecting = core.state else {
                    core.statistics.ignoredOutOfStateMessages += 1
                    return false
                }
                core.settings = ack.settings
                core.lastAppliedSettingsRevision = ack.settingsRevision
                cancelTimers(&core)
                core.consecutiveFailures = 0
                core.readyProbeUsedInCurrentCircuit = false
                return true
            }
            guard accepted else { return }
            guard setState(.healthy) else { return }
            scheduleHeartbeat()
        case .heartbeatAck:
            // While `.connecting` only `helloAck` may disarm the handshake timeout.
            let accepted = core.withLock { core -> Bool in
                guard core.state == .healthy else {
                    core.statistics.ignoredOutOfStateMessages += 1
                    return false
                }
                core.livenessTimer?.cancel()
                core.livenessTimer = nil
                return true
            }
            guard accepted else { return }
            scheduleHeartbeat()
        case .settingsSnapshot(_, let settings, let revision):
            let accepted = core.withLock { core -> Bool in
                guard revision >= core.lastAppliedSettingsRevision else {
                    core.statistics.staleSettingsRevisions += 1
                    return false
                }
                core.settings = settings
                core.lastAppliedSettingsRevision = revision
                return true
            }
            guard accepted else { return }
        case .aiSuggestion:
            break
        }
        guard core.withLock({ $0.running }) else { return }
        outcome.1?(envelope.payload)
    }

    /// Ends the current attempt and schedules the next: backoff, or the open circuit.
    private func fail(_ reason: IPCDegradationReason) {
        let plan = core.withLock { core -> (installed: Bool, failures: Int)? in
            guard core.running else { return nil }
            cancelTimers(&core)
            let installed = core.currentAttemptID != 0
            core.currentAttemptID = 0
            core.statistics.discardedOnFailure += core.outbox.count
            core.outbox.removeAll()
            core.consecutiveFailures += 1
            core.statistics.failures += 1
            return (installed, core.consecutiveFailures)
        }
        guard let plan else { return }
        if plan.installed { transport.disconnect(reason: "failed: \(reason.rawValue)") }
        log.info("agent connection degraded: \(reason.rawValue, privacy: .public), failures \(plan.failures, privacy: .public)")
        // The observer may call `stop()`: then schedule nothing.
        guard setState(.degraded(reason)) else { return }
        if plan.failures >= policy.circuitBreakerThreshold {
            let until = clock.now + policy.circuitCooldown
            guard setState(.circuitOpen(failures: plan.failures, cooldownUntil: until)) else { return }
            scheduleRetry(after: policy.circuitCooldown)
        } else {
            let base = policy.backoff(afterFailures: plan.failures)
            let maximumJitter = Duration.nanoseconds(Int64(Double(base.nanoseconds) * min(max(policy.jitterFraction, 0), 1)))
            let delay = base + jitter.jitter(maximum: maximumJitter)
            guard setState(.reconnecting(attempt: plan.failures, nextRetryDelay: delay)) else { return }
            scheduleRetry(after: delay)
        }
    }

    private func handleReadySignal() {
        let retryNow = core.withLock { core -> Bool in
            guard core.running else { return false }
            core.statistics.readySignals += 1
            let now = clock.now
            if let last = core.lastReadySignal, now - last < policy.readyDebounce {
                core.statistics.debouncedReadySignals += 1
                return false
            }
            core.lastReadySignal = now
            switch core.state {
            case .circuitOpen:
                guard !core.readyProbeUsedInCurrentCircuit else {
                    core.statistics.rateLimitedReadySignals += 1
                    return false
                }
                core.readyProbeUsedInCurrentCircuit = true
                return true
            case .reconnecting, .degraded: return true
            case .idle, .connecting, .healthy: return false
            }
        }
        if retryNow { attempt() }
    }

    private func drain() {
        let (messages, epoch) = core.withLock { core -> ([IMEToAgent], UUID) in
            defer { core.outbox.removeAll(); core.drainScheduled = false }
            guard core.state == .healthy, core.currentAttemptID != 0 else {
                core.statistics.discardedOnFailure += core.outbox.count
                return ([], core.gate.sessionEpoch)
            }
            return (core.outbox, core.gate.sessionEpoch)
        }
        for message in messages {
            let stamped = message.stamped(epoch: epoch)
            let generation: UInt64?
            switch stamped {
            case .compositionStateChanged(let snapshot): generation = snapshot.generationID
            default: generation = nil
            }
            guard send(stamped, generationID: generation, expectingReply: false) else { return }
        }
    }

    /// Encodes and sends; a transport failure fails the connection. Returns false then.
    @discardableResult
    private func send(_ message: IMEToAgent, generationID: UInt64?, expectingReply: Bool) -> Bool {
        let sequence = core.withLock { core -> UInt64 in
            core.sequence += 1
            return core.sequence
        }
        do {
            let frame = try IPCWireCodec.encode(IPCEnvelope(sequence: sequence, message: message, generationID: generationID))
            try transport.send(frame, expectingReply: expectingReply)
            core.withLock { $0.statistics.framesSent += 1 }
            return true
        } catch .payloadTooLarge {
            core.withLock { $0.statistics.malformedFrames += 1 }
            return true
        } catch .malformedFrame {
            core.withLock { $0.statistics.malformedFrames += 1 }
            return true
        } catch {
            fail(Self.reason(for: error))
            return false
        }
    }

    // MARK: Timers

    private func scheduleRetry(after delay: Duration) {
        let epoch = core.withLock { $0.timerEpoch }
        let timer = clock.schedule(after: delay, on: queue) { [weak self] in
            guard let self else { return }
            let due = self.core.withLock { core -> Bool in
                guard core.timerEpoch == epoch, core.running else { return false }
                // The backoff or cooldown elapsed on its own: a later open circuit gets a
                // fresh ready probe.
                core.readyProbeUsedInCurrentCircuit = false
                return true
            }
            guard due else { return }
            self.attempt()
        }
        install(timer, epoch: epoch) { $0.retryTimer = timer }
    }

    /// Fails the attempt with `.timeout` unless an ack cancels this timer first.
    private func armLivenessTimer() {
        let epoch = core.withLock { $0.timerEpoch }
        let timer = clock.schedule(after: policy.handshakeTimeout, on: queue) { [weak self] in
            guard let self, self.core.withLock({ $0.timerEpoch == epoch && $0.livenessTimer != nil }) else { return }
            self.fail(.timeout)
        }
        install(timer, epoch: epoch) { $0.livenessTimer = timer }
    }

    private func scheduleHeartbeat() {
        guard let interval = policy.heartbeatInterval else { return }
        let epoch = core.withLock { core -> UInt64 in
            core.heartbeatTimer?.cancel()
            return core.timerEpoch
        }
        let timer = clock.schedule(after: interval, on: queue) { [weak self] in
            guard let self else { return }
            let beat = self.core.withLock { core -> (UUID, UInt64)? in
                guard core.timerEpoch == epoch, core.state == .healthy else { return nil }
                core.heartbeatGeneration += 1
                return (core.gate.sessionEpoch, core.heartbeatGeneration)
            }
            guard let (sessionEpoch, generation) = beat else { return }
            guard self.send(.heartbeat(sessionEpoch: sessionEpoch), generationID: generation, expectingReply: true) else { return }
            self.armLivenessTimer()
        }
        install(timer, epoch: epoch) { $0.heartbeatTimer = timer }
    }

    /// Stores `timer` unless the manager stopped or its timers were cancelled since
    /// `epoch` was read (a re-entrant `stop()` from an observer); then cancels it at once.
    private func install(_ timer: any IPCCancellable, epoch: UInt64, _ store: (inout Core) -> Void) {
        let installed = core.withLockUnchecked { core -> Bool in
            guard core.running, core.timerEpoch == epoch else { return false }
            store(&core)
            return true
        }
        if !installed { timer.cancel() }
    }

    private func cancelTimers(_ core: inout Core) {
        core.timerEpoch += 1
        core.retryTimer?.cancel()
        core.livenessTimer?.cancel()
        core.heartbeatTimer?.cancel()
        core.retryTimer = nil
        core.livenessTimer = nil
        core.heartbeatTimer = nil
    }

    /// Publishes `state` and returns whether the manager is still running afterwards: the
    /// observer may call `stop()` re-entrantly, and callers then schedule nothing. Only
    /// `.idle` is published once stopped.
    @discardableResult
    private func setState(_ state: IPCConnectionState) -> Bool {
        let observer = core.withLock { core -> (@Sendable (IPCConnectionState) -> Void)?? in
            guard core.running || state == .idle else { return nil }
            core.state = state
            return .some(core.onStateChange)
        }
        guard let observer else { return false }
        observer?(state)
        return core.withLock { $0.running }
    }

    static func reason(for error: IPCError) -> IPCDegradationReason {
        switch error {
        case .connectionUnavailable(let reason): reason
        case .peerRejected: .peerRejected
        case .timeout: .timeout
        default: .directASCII
        }
    }
}

extension IMEToAgent {
    /// The message with its connection epoch replaced by `epoch`.
    func stamped(epoch: UUID) -> IMEToAgent {
        switch self {
        case .hello(var hello):
            hello.sessionEpoch = epoch
            return .hello(hello)
        case .heartbeat:
            return .heartbeat(sessionEpoch: epoch)
        case .compositionStateChanged(var snapshot):
            snapshot.sessionEpoch = epoch
            return .compositionStateChanged(snapshot)
        case .openSettingsRequested:
            return self
        }
    }
}
