import CoreGraphics
import Foundation

/// Reads the window server's running count of events of a given type. That count
/// advances when an event has been PROCESSED by the window server, not when it was
/// merely handed over — which is what makes it a completion signal rather than a
/// guess. Injected so the flush's timing is provable under a fake counter and a
/// fake clock, with nothing posted.
public protocol EventDeliveryCounter {
    func count(of type: CGEventType) -> UInt32
}

/// The live counter, read from the same `.combinedSessionState` source the
/// synthesized events are built against, so posted events and the counter describe
/// the same event stream.
public struct CGEventDeliveryCounter: EventDeliveryCounter {
    public init() {}

    public func count(of type: CGEventType) -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
    }
}

/// What the bounded flush established about the events a verb posted.
public enum DeliveryConfirmation: Equatable, Sendable {
    /// Nothing was posted, so there is nothing to confirm — and, crucially, no
    /// signal to wait for. The refused (`secure input`) and empty (`act type ""`)
    /// paths land here and return instantly.
    case nothingPosted
    /// The window server's counters advanced by exactly the number of events that
    /// were posted: delivery completed.
    case confirmed
    /// The deadline expired before the counters caught up. The events WERE posted
    /// and may still land; what cannot be claimed is that they did.
    case unconfirmed
}

/// Posts synthesized events and waits — bounded — until the window server reports
/// having processed them.
///
/// `CGEvent.post` is ASYNCHRONOUS: it hands the event to the window server and
/// returns. A CLI that posts and then exits therefore races its own input, and
/// loses: measured with identical events, a process that lingered 0s after posting
/// delivered nothing while one that lingered 0.5s delivered everything. That race
/// is why every input verb has to wait here, and why the verified verbs must not
/// keep depending on their post-action accessibility walk to hold the process open
/// long enough by accident.
///
/// The wait is on an OBSERVABLE signal, not a fixed delay:
/// `CGEventSource.counterForEventType` is sampled per event type before posting,
/// and the flush returns the instant every type's counter has advanced by the
/// number of events of that type that were posted. On this machine that takes
/// ~50ms for a keystroke pair and ~450ms for a thousand events, against a `post`
/// that returns in ~20ms — the gap the race lived in.
///
/// It is bounded like `BoundedWalk`: a deadline on the monotonic clock, generous
/// enough that a healthy delivery never approaches it, so expiry means something is
/// genuinely wrong (the window server dropped the events — secure input turning on
/// mid-flight does exactly that) and is reported rather than passed off as success.
///
/// The counter is session-wide, so real input of the same type arriving DURING the
/// flush can satisfy the expectation slightly early. That only ever shortens a
/// wait whose events were already in flight; it can never invent a confirmation
/// for a delivery the window server refused, because a refused event stream leaves
/// its counter parked and the deadline is what ends the wait.
public struct InputDeliveryFlush {
    /// Fixed part of the budget, ~30x the measured latency of a single keystroke
    /// pair so ordinary jitter never trips it.
    public static let baseDeadline: TimeInterval = 2
    /// Per-event allowance, ~10x the measured drain rate, so a long `act type`
    /// (two events per character) gets a budget proportional to what it posted
    /// instead of being cut off by a constant.
    public static let perEventDeadline: TimeInterval = 0.005
    /// Ceiling on the whole wait, matching `BoundedWalk.defaultDeadline` so no
    /// single input verb can outlast the hung-target budget.
    public static let maxDeadline: TimeInterval = 8
    /// Sampling period. The counter read is a cheap call, and a tight period keeps
    /// the flush's own overhead far below the delivery latency it is measuring.
    public static let pollInterval: TimeInterval = 0.002

    /// The budget for `count` events: fixed part plus a per-event allowance,
    /// capped. Returning as soon as the signal arrives is what makes a generous
    /// budget free — it is a ceiling, never a delay.
    public static func deadline(forEvents count: Int) -> TimeInterval {
        min(baseDeadline + perEventDeadline * Double(count), maxDeadline)
    }

    private let counter: EventDeliveryCounter
    private let interval: TimeInterval
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let deadlineForEvents: (Int) -> TimeInterval

    public init(
        counter: EventDeliveryCounter = CGEventDeliveryCounter(),
        interval: TimeInterval = pollInterval,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        deadlineForEvents: @escaping (Int) -> TimeInterval = { deadline(forEvents: $0) }
    ) {
        self.counter = counter
        self.interval = interval
        self.now = now
        self.sleep = sleep
        self.deadlineForEvents = deadlineForEvents
    }

    /// Post `events` through `send`, then wait until the window server has
    /// processed them all. Posting is owned here so the baseline can never be read
    /// on the wrong side of the first event — the one ordering mistake that would
    /// make the whole signal meaningless.
    public func post(_ events: [CGEvent], through send: (CGEvent) -> Void) -> DeliveryConfirmation {
        var expected: [CGEventType: Int] = [:]
        for event in events {
            expected[event.type, default: 0] += 1
        }
        // Zero events posted ⇒ zero to wait for. Read no counter and never sleep:
        // a secure-input refusal and an empty `type` must not stall on a signal
        // that will never come.
        guard !expected.isEmpty else { return .nothingPosted }

        var baseline: [CGEventType: UInt32] = [:]
        for type in expected.keys {
            baseline[type] = counter.count(of: type)
        }

        for event in events {
            send(event)
        }

        return waitForDelivery(of: expected, since: baseline)
    }

    /// The bounded wait itself. Structured like `WaitPoll`: the condition is
    /// checked BEFORE any sleep, so an already-delivered burst returns without
    /// waiting; the loop ends only at the deadline, so it can never hang.
    private func waitForDelivery(
        of expected: [CGEventType: Int],
        since baseline: [CGEventType: UInt32]
    ) -> DeliveryConfirmation {
        let expiry = now() + deadlineForEvents(expected.values.reduce(0, +))
        while true {
            if hasDelivered(expected, since: baseline) { return .confirmed }
            let current = now()
            if current >= expiry { return .unconfirmed }
            // Never sleep past the deadline, so expiry is prompt rather than
            // rounded up to the next whole interval.
            sleep(min(interval, expiry - current))
        }
    }

    /// Whether EVERY posted event type's counter has advanced by at least the
    /// number of events of that type. All types are required, not just the last
    /// one, so a partially-drained burst is never mistaken for a delivered one.
    private func hasDelivered(_ expected: [CGEventType: Int], since baseline: [CGEventType: UInt32]) -> Bool {
        for (type, wanted) in expected {
            // The counter is a rolling 32-bit value, so it wraps. Wrapping
            // subtraction is exactly the arithmetic that keeps the delta correct
            // across the wrap.
            let advanced = counter.count(of: type) &- (baseline[type] ?? 0)
            if advanced < UInt32(clamping: wanted) { return false }
        }
        return true
    }
}

/// Thrown by a live delivery seam when the bounded flush could not confirm that the
/// events it posted reached the window server.
///
/// Payload-free on purpose, exactly like `SecureInputActive`: the events that could
/// not be confirmed may be a password, and this error's report reaches stdout and
/// the trajectory.
public struct DeliveryUnconfirmed: Error, Equatable, Sendable {
    public init() {}
}

/// How an unconfirmed delivery is reported — the counterpart to
/// `UnverifiedDelivery`, and a deliberately STRONGER statement than it.
///
/// `--no-verify` says "the input was delivered, but its effect was not checked".
/// This says "the input was posted, and even its delivery could not be established"
/// — a different and worse position for an agent to be in, so it must never render
/// as the other. It is reported by the verified verbs too: when the flush expires
/// there is nothing left to verify against, so the post-action walk is skipped and
/// this is what the verb reports instead of a diff it cannot stand behind.
public enum UnconfirmedDelivery {
    /// Printed on stdout WHERE THE DIFF WOULD NORMALLY GO. It says what is known
    /// (the events were posted), what is not (that they arrived), and the one
    /// command that settles the question.
    public static let notice =
        "input was posted but its delivery could NOT be confirmed (no accessibility diff was taken); "
            + "the action may not have taken effect — run 'mtouch snapshot' to see the current state"

    /// The `--json` form. `posted` and `confirmed` are separate fields precisely
    /// because they differ here; `verified` is false too, since no walk was taken.
    /// A consumer keying off `delivered` — the unverified notice's field — finds it
    /// ABSENT, so the two can never be conflated.
    public static let noticeJSON =
        "{\"posted\":true,\"confirmed\":false,\"verified\":false,\"note\":\(JSONText.string(notice))}"

    /// The notice in the caller's chosen rendering — the single source both the CLI
    /// and the MCP surface print, so their payloads stay byte-identical.
    public static func rendered(json: Bool) -> String { json ? noticeJSON : notice }
}
