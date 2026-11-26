import Dispatch
import Foundation
import os

/// A monotonic instant of an `IPCClock`: the time since the clock's origin.
public struct IPCInstant: Comparable, Hashable, Sendable {
    public var sinceOrigin: Duration

    public init(sinceOrigin: Duration) {
        self.sinceOrigin = sinceOrigin
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.sinceOrigin < rhs.sinceOrigin }
    public static func + (lhs: Self, rhs: Duration) -> Self { Self(sinceOrigin: lhs.sinceOrigin + rhs) }
    public static func - (lhs: Self, rhs: Self) -> Duration { lhs.sinceOrigin - rhs.sinceOrigin }
}

/// A scheduled timer; `cancel()` is idempotent and safe from any thread.
public protocol IPCCancellable: Sendable {
    func cancel()
}

/// Monotonic time and timers for `IPCConnectionManager`, injectable so backoff, circuit
/// cooldown, and debouncing run deterministically in tests (`ManualIPCClock`).
public protocol IPCClock: Sendable {
    var now: IPCInstant { get }
    /// Runs `work` on `queue` once `delay` has elapsed, unless cancelled first.
    func schedule(after delay: Duration, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> any IPCCancellable
}

/// `ContinuousClock` time and `DispatchQueue.asyncAfter` timers.
public struct SystemIPCClock: IPCClock {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: IPCInstant { IPCInstant(sinceOrigin: ContinuousClock.now - origin) }

    public func schedule(after delay: Duration, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> any IPCCancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: delay.nanoseconds)), execute: item)
        return WorkItemCancellable(item: item)
    }

    private struct WorkItemCancellable: IPCCancellable, @unchecked Sendable {
        let item: DispatchWorkItem
        func cancel() { item.cancel() }
    }
}

/// A clock that moves only when a test calls `advance(by:)`. Due timers run in deadline
/// order, each synchronously on its queue, so call `advance` from the test's thread, never
/// from a timer's queue.
public final class ManualIPCClock: IPCClock, @unchecked Sendable {
    private struct Timer {
        let id: UInt64
        let deadline: IPCInstant
        let queue: DispatchQueue
        let work: @Sendable () -> Void
    }

    private struct State {
        var now = IPCInstant(sinceOrigin: .zero)
        var nextID: UInt64 = 1
        var timers: [Timer] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var now: IPCInstant { state.withLock { $0.now } }

    /// Timers that have not fired or been cancelled.
    public var pendingTimerCount: Int { state.withLock { $0.timers.count } }

    /// The earliest pending deadline, if any.
    public var nextDeadline: IPCInstant? { state.withLock { $0.timers.map(\.deadline).min() } }

    public func schedule(after delay: Duration, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> any IPCCancellable {
        let id = state.withLock { state -> UInt64 in
            let id = state.nextID
            state.nextID += 1
            state.timers.append(Timer(id: id, deadline: state.now + max(delay, .zero), queue: queue, work: work))
            return id
        }
        return Cancellation(clock: self, id: id)
    }

    /// Moves time forward, firing every timer that falls due (including timers scheduled by
    /// fired timers) in deadline order.
    public func advance(by duration: Duration) {
        let target = state.withLock { $0.now + duration }
        while true {
            let due = state.withLock { state -> Timer? in
                guard let index = state.timers.indices
                    .filter({ state.timers[$0].deadline <= target })
                    .min(by: { (state.timers[$0].deadline, state.timers[$0].id) < (state.timers[$1].deadline, state.timers[$1].id) })
                else { return nil }
                let timer = state.timers.remove(at: index)
                state.now = max(state.now, timer.deadline)
                return timer
            }
            guard let due else { break }
            due.queue.sync(execute: due.work)
        }
        state.withLock { $0.now = max($0.now, target) }
    }

    fileprivate func cancel(id: UInt64) {
        state.withLock { $0.timers.removeAll { $0.id == id } }
    }

    private struct Cancellation: IPCCancellable {
        weak var clock: ManualIPCClock?
        let id: UInt64
        func cancel() { clock?.cancel(id: id) }
    }
}

/// Randomization added to reconnect delays so many clients do not retry in lockstep.
public protocol JitterSource: Sendable {
    /// A value in `0...maximum`.
    func jitter(maximum: Duration) -> Duration
}

public struct SystemJitter: JitterSource {
    public init() {}
    public func jitter(maximum: Duration) -> Duration {
        let limit = max(maximum.nanoseconds, 0)
        return .nanoseconds(limit == 0 ? 0 : Int64.random(in: 0...limit))
    }
}

/// `maximum * fraction`, for deterministic tests (0 disables jitter).
public struct FixedJitter: JitterSource {
    public let fraction: Double
    public init(fraction: Double) { self.fraction = min(max(fraction, 0), 1) }
    public func jitter(maximum: Duration) -> Duration {
        .nanoseconds(Int64(Double(max(maximum.nanoseconds, 0)) * fraction))
    }
}

extension Duration {
    /// Whole nanoseconds, saturating.
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return seconds < 0 ? .min : .max }
        return scaled.addingReportingOverflow(attoseconds / 1_000_000_000).partialValue
    }
}
