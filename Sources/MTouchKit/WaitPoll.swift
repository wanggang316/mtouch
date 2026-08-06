import Foundation

/// Outcome of a poll: whether the condition was met, how many checks ran, and
/// the elapsed time. `checks` and `elapsed` are the observable evidence the
/// timing bounds (VAL-WAIT-002/006 and the `--timeout 0` / `--interval > --timeout`
/// edge cases) are asserted against.
public struct WaitPollResult: Equatable, Sendable {
    public let met: Bool
    public let checks: Int
    public let elapsed: TimeInterval

    public init(met: Bool, checks: Int, elapsed: TimeInterval) {
        self.met = met
        self.checks = checks
        self.elapsed = elapsed
    }
}

/// A bounded poll loop, kept PURE over an injectable clock (`now`), timer
/// (`sleep`), and condition (`probe`) so its timing is deterministic under a
/// fake clock and never depends on wall time.
///
/// Guarantees, by construction:
/// - The condition is checked BEFORE any sleep, so an already-true condition
///   returns in well under one interval (VAL-WAIT-002).
/// - It fails only once `now() >= start + timeout`, so a never-true wait never
///   gives up early — elapsed is always ≥ `timeout` (VAL-WAIT-006).
/// - `--timeout 0` yields exactly ONE check; a first check always runs, so
///   `--interval` larger than `--timeout` still guarantees ≥1 check.
/// - The inter-check sleep is capped to the time remaining, so an oversized
///   interval never sleeps meaningfully past the deadline.
public enum WaitPoll {
    public static func poll(
        timeout: TimeInterval,
        interval: TimeInterval,
        now: () -> TimeInterval,
        sleep: (TimeInterval) -> Void,
        probe: () -> Bool
    ) -> WaitPollResult {
        let start = now()
        let deadline = start + timeout
        var checks = 0
        while true {
            checks += 1
            if probe() {
                return WaitPollResult(met: true, checks: checks, elapsed: now() - start)
            }
            let current = now()
            if current >= deadline {
                return WaitPollResult(met: false, checks: checks, elapsed: current - start)
            }
            // Time remains: wait, but never past the deadline (elapsed honesty).
            sleep(min(interval, deadline - current))
        }
    }
}
