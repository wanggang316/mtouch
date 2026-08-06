import Foundation
import Testing
@testable import MTouchKit

/// A deterministic fake clock: `now()` reads the virtual time, `sleep(_:)`
/// advances it, and an optional per-probe cost advances it to model walk time.
/// This makes the poll timing bounds provable without any wall-clock reliance.
private final class FakeClock {
    private(set) var time: TimeInterval = 0
    let probeCost: TimeInterval

    init(probeCost: TimeInterval = 0) {
        self.probeCost = probeCost
    }

    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
    func advanceForProbe() { time += probeCost }
}

@Suite struct WaitPollTests {
    @Test func alreadyTrueReturnsInWellUnderOneInterval() {
        // VAL-WAIT-002: an already-true condition returns before one interval elapses.
        let clock = FakeClock()
        let result = WaitPoll.poll(
            timeout: 5, interval: 0.1, now: clock.now, sleep: clock.sleep
        ) { true }

        #expect(result.met)
        #expect(result.checks == 1)
        #expect(result.elapsed < 0.1)
    }

    @Test func neverTrueFailsAtTheTimeoutNotBefore() {
        // VAL-WAIT-006: a never-true --timeout 2s fails at ≥2s (and, with a
        // zero-cost probe, exactly at 2s — never early).
        let clock = FakeClock()
        let result = WaitPoll.poll(
            timeout: 2, interval: 0.1, now: clock.now, sleep: clock.sleep
        ) { false }

        #expect(!result.met)
        #expect(result.elapsed >= 2)
        #expect(result.elapsed < 3) // upper bound of the pinned [2s,3s) window
        #expect(result.checks >= 1)
    }

    @Test func neverTrueUpperBoundIncludesProbeCost() {
        // With a real (non-zero) walk cost per probe, the overshoot past the
        // deadline is bounded by one probe — still inside [timeout, timeout+cost].
        let clock = FakeClock(probeCost: 0.3)
        let result = WaitPoll.poll(
            timeout: 2, interval: 0.1, now: clock.now, sleep: clock.sleep
        ) {
            clock.advanceForProbe()
            return false
        }

        #expect(!result.met)
        #expect(result.elapsed >= 2)
        #expect(result.elapsed < 2 + 0.1 + 0.3) // < timeout + interval + probeCost
    }

    @Test func timeoutZeroDoesASingleCheck() {
        // --timeout 0 = one immediate check, then a verdict (no sleep).
        let clock = FakeClock()
        let result = WaitPoll.poll(
            timeout: 0, interval: 0.1, now: clock.now, sleep: clock.sleep
        ) { false }

        #expect(!result.met)
        #expect(result.checks == 1)
        #expect(result.elapsed == 0)
    }

    @Test func intervalLargerThanTimeoutStillChecksAtLeastOnce() {
        // --interval 10s --timeout 2s: still ≥1 check, and the sleep is capped to
        // the remaining budget so it never oversleeps to 10s.
        let clock = FakeClock()
        let result = WaitPoll.poll(
            timeout: 2, interval: 10, now: clock.now, sleep: clock.sleep
        ) { false }

        #expect(!result.met)
        #expect(result.checks >= 1)
        #expect(result.elapsed >= 2)
        #expect(result.elapsed < 3) // capped: not the full 10s interval
    }

    @Test func becomesTrueMidPollReturnsPromptly() {
        // Condition flips true once virtual time reaches ~0.5s; the poll must stop
        // then, not run to the 5s timeout.
        let clock = FakeClock()
        var probes = 0
        let result = WaitPoll.poll(
            timeout: 5, interval: 0.1, now: clock.now, sleep: clock.sleep
        ) {
            probes += 1
            return clock.now() >= 0.5
        }

        #expect(result.met)
        #expect(result.elapsed >= 0.5)
        #expect(result.elapsed < 0.7)
    }
}
