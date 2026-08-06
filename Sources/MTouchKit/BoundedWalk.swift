import Foundation

/// Runs a potentially-blocking walk under a hard wall-clock deadline so a hung or
/// SIGSTOPped target can never wedge the CLI into an indefinite hang.
///
/// The per-read AX messaging timeout (3s) already degrades individual reads on an
/// unresponsive app, but a full tree walk chains many reads plus the fallback
/// re-walk, so its worst case can exceed the hung-target budget. This ceiling
/// bounds the WHOLE walk: a healthy app finishes in well under 2s and never
/// approaches it, while an unresponsive one trips it and the caller emits an
/// explicit timeout diagnostic (exit 1) instead of blocking.
public enum BoundedWalk {
    /// Wall-clock ceiling for a single walk, chosen to sit well under the 10s
    /// hung-target budget while leaving ample room for a healthy walk.
    public static let defaultDeadline: TimeInterval = 8

    /// Runs `work` on a background queue, returning its result when it completes
    /// within `deadline`, else nil. On timeout the abandoned work keeps running
    /// on its queue; callers exit the process immediately after, so the leak is
    /// bounded to process lifetime and never wedges the CLI.
    public static func run<T: Sendable>(
        deadline: TimeInterval = defaultDeadline,
        _ work: @escaping @Sendable () -> T
    ) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(work())
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + deadline) == .success else { return nil }
        return box.get()
    }

    /// Minimal lock-protected one-shot cell so the result crosses the queue
    /// boundary without a data race: the write happens-before `signal()`, and the
    /// read happens only after a successful `wait()`.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
