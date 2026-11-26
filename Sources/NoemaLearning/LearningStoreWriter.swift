import Dispatch
import Foundation
import os

/// Records commits without blocking the input method's main actor.
///
/// `enqueue(_:)` appends to a bounded in-memory queue under an `OSAllocatedUnfairLock` and,
/// when no drain is pending, schedules one on a serial `.utility` queue after
/// `coalescingDelay`; it never touches SQLite. A drain takes everything queued and writes it
/// in one WAL transaction (`LearningStore.recordBatch`). When the queue is full the newest
/// event is dropped and counted: learning is best effort, typing is not.
///
/// `flush()` drains synchronously (call it before shutdown; never from the writer's own
/// queue); `flushAsync()` drains without blocking, before a schema-set switch.
public final class LearningStoreWriter: Sendable {
    public struct Statistics: Sendable, Hashable {
        public var enqueued: Int = 0
        public var dropped: Int = 0
        public var recorded: Int = 0
        /// Transactions written; fewer than `enqueued` when events were coalesced.
        public var batches: Int = 0
        public var failedBatches: Int = 0
        public var lastError: LearningStoreError?
    }

    private struct State {
        var pending: [LearningCommitEvent] = []
        var drainScheduled = false
        var statistics = Statistics()
    }

    public let store: LearningStore
    public let capacity: Int
    public let coalescingDelay: Duration
    private let queue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(store: LearningStore, capacity: Int = 4096, coalescingDelay: Duration = .milliseconds(25)) {
        self.store = store
        self.capacity = max(capacity, 1)
        self.coalescingDelay = coalescingDelay
        self.queue = DispatchQueue(label: "dev.noema.learning.writer", qos: .utility)
        state.withLock { $0.pending.reserveCapacity(min(self.capacity, 256)) }
    }

    /// Queues `event`; returns false when the queue was full and the event was dropped.
    @discardableResult
    public func enqueue(_ event: LearningCommitEvent) -> Bool {
        let (accepted, schedule) = state.withLock { state -> (Bool, Bool) in
            guard state.pending.count < capacity else {
                state.statistics.dropped += 1
                return (false, false)
            }
            state.pending.append(event)
            state.statistics.enqueued += 1
            let schedule = !state.drainScheduled
            state.drainScheduled = true
            return (true, schedule)
        }
        if schedule {
            let (seconds, attoseconds) = coalescingDelay.components
            let delay = max(0, Double(seconds) + Double(attoseconds) / 1e18)
            queue.asyncAfter(deadline: .now() + delay) { [self] in drain() }
        }
        return accepted
    }

    /// Writes everything queued so far before returning.
    public func flush() {
        queue.sync { drain() }
    }

    /// Writes everything queued so far, on the writer's queue, before resuming; never blocks
    /// the caller's thread (`switchSchemaSet` calls it on the main actor).
    public func flushAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                drain()
                continuation.resume()
            }
        }
    }

    public var statistics: Statistics { state.withLock { $0.statistics } }

    public var pendingCount: Int { state.withLock { $0.pending.count } }

    private func drain() {
        let batch = state.withLock { state -> [LearningCommitEvent] in
            let batch = state.pending
            state.pending.removeAll(keepingCapacity: true)
            state.drainScheduled = false
            return batch
        }
        guard !batch.isEmpty else { return }
        do {
            let recorded = try store.recordBatch(batch)
            state.withLock {
                $0.statistics.recorded += recorded
                $0.statistics.batches += 1
            }
        } catch {
            state.withLock {
                $0.statistics.failedBatches += 1
                $0.statistics.lastError = error
            }
        }
    }
}
