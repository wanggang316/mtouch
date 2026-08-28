import Foundation

/// A bounded, single-flight walk used by the poll loop.
///
/// `wait` polls repeatedly, so a naive per-poll `BoundedWalk.run` on a HUNG
/// target would abandon (leak) one background thread per poll — unbounded over
/// a long timeout. `GuardedWalk` caps that: it keeps AT MOST ONE walk in flight.
/// While a previous walk is still running (hung target), `sample()` returns nil
/// immediately WITHOUT spawning another, so the background task count stays at 1
/// for the whole wait regardless of how many polls occur.
///
/// A healthy walk completes within `deadline`, resets the in-flight flag, and
/// each subsequent poll spawns a fresh short-lived task — so the cap only ever
/// bites on an unresponsive target.
///
/// Generic over the SAMPLE a walk yields, because the two pollers need different
/// readings of the same tree: `wait` only evaluates a condition, so it samples the
/// derived `[AXNode]`, while a `--wait`-paced criteria act must ACT on what it
/// matched, so it samples a handle-bearing `LiveElementTree`. The single-flight
/// discipline is identical either way, so it lives here once.
public final class GuardedWalk<Sample: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let deadline: TimeInterval
    private let work: @Sendable () -> Sample?

    private let lock = NSLock()
    private var inFlight = false
    private var spawns = 0

    /// Number of background tasks ever spawned. Exposed for tests to assert the
    /// single-flight cap holds on a hung target (stays 1 across many samples).
    public var spawnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return spawns
    }

    public init(
        deadline: TimeInterval = BoundedWalk.defaultDeadline,
        work: @escaping @Sendable () -> Sample?
    ) {
        self.queue = DispatchQueue(label: "com.mtouch.guarded-walk", qos: .userInitiated)
        self.deadline = deadline
        self.work = work
    }

    /// One poll's sample: the freshest tree read within `deadline`, or nil when a
    /// walk is already in flight (hung target) or this walk itself exceeds the
    /// deadline. Never spawns a second concurrent walk.
    public func sample() -> Sample? {
        lock.lock()
        if inFlight {
            // A previous walk is still running (hung): do NOT spawn another.
            lock.unlock()
            return nil
        }
        inFlight = true
        spawns += 1
        lock.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        queue.async { [work, lock] in
            let result = work()
            box.set(result)
            // Clear the flag BEFORE signaling so the waiter observes a consistent
            // state and the next healthy poll can spawn again.
            lock.lock(); self.inFlight = false; lock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + deadline) == .success else {
            // Timed out: the walk is still running, so `inFlight` remains true and
            // the next `sample()` short-circuits without spawning a second thread.
            return nil
        }
        return box.get()
    }

    /// Lock-protected one-shot cell carrying the walk result across the queue
    /// boundary (mirrors `BoundedWalk.Box`): the write happens-before `signal()`,
    /// the read only after a successful `wait()`.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Sample?
        func set(_ newValue: Sample?) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> Sample? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
