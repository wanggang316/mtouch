import Foundation

/// The budget an `act` verb spends re-walking after its input, waiting for the
/// UI's response to STOP CHANGING.
///
/// Two numbers and one derived rule:
///   - `deadline` bounds the whole settle on the MONOTONIC clock, in the spirit of
///     `BoundedWalk`: a UI that never sits still costs a bounded amount of time and
///     then reports what it saw, rather than blocking.
///   - `interval` is the gap between re-walks. It is never a fixed wait for an
///     effect to arrive: the loop re-walks and returns the instant the reading is
///     stable, so the interval only keeps a settling application from being
///     hammered with back-to-back tree reads.
///   - `window` is the quiet window handed to `QuiescenceTracker`, deliberately
///     SHORTER than `interval`. That is what makes the time-based quiescence rule
///     `wait --stable` uses mean, here, exactly "the tree was identical on two
///     CONSECUTIVE walks" — one notion of settled, one implementation of it.
///
/// A menu-opening verb gets its own, much longer budget: the `AXMenu` it opens
/// only becomes walkable once it reports a real frame, and a menu command
/// routinely opens a window or sheet, both of which take far longer to appear than
/// an in-place change.
public struct SettleBudget: Equatable, Sendable {
    /// Wall-clock ceiling on the whole settle loop, measured on the monotonic clock.
    public let deadline: TimeInterval
    /// Gap between consecutive re-walks.
    public let interval: TimeInterval

    public init(deadline: TimeInterval, interval: TimeInterval) {
        self.deadline = deadline
        self.interval = interval
    }

    /// The quiet window a `QuiescenceTracker` must see to call the tree settled.
    /// Derived as half the interval so it is shorter than the poll period BY
    /// CONSTRUCTION: satisfying it therefore means the digest was unchanged from
    /// one walk to the very next, never merely "unchanged for a while".
    public var window: TimeInterval { interval / 2 }

    /// The budget for an ordinary in-place change (a keystroke, a click, a press).
    ///
    /// Sized against what this loop used to cost an action that changes NOTHING,
    /// since that is the case which spends the whole budget: four walks spaced 120ms,
    /// measured at ~720ms on a stock text editor whose walk costs ~90ms. A 600ms
    /// ceiling fits about five walks into a comparable span — more chances to catch a
    /// late change, in no more wall time. Measured end to end on that editor, a no-op
    /// verb went from ~1080ms to ~1200ms; the extra ~120ms is one more observation of
    /// the tree, which is the thing being bought.
    public static let standard = SettleBudget(deadline: 0.6, interval: 0.05)

    /// The budget for an action that opens a menu, window, or sheet, sized the same
    /// way: ten walks spaced 400ms cost ~4.5s, so 4s is the ceiling that replaces it.
    public static let menu = SettleBudget(deadline: 4, interval: 0.15)

    public static func forVerb(expectsMenu: Bool) -> SettleBudget {
        expectsMenu ? menu : standard
    }
}

/// What the post-action settle concluded: the reading to report, and whether that
/// reading was proven STABLE.
///
/// The two travel together because they are only meaningful together. A diff is
/// the evidence an `act` verb exists to produce, and an agent acts on it — retries
/// a keystroke it believes was not typed, or believes a field holds a value it does
/// not. So a reading that was still moving when the budget expired must be
/// reportable as exactly that, in the same way `verified` and `deliveryConfirmed`
/// already report the other two ways an action's evidence can be weaker than usual.
public struct SettleResult: Equatable, Sendable {
    /// The diff and the new session snapshot, both taken from the SAME walk — so
    /// the change an agent reads about and the refs it can act on next describe one
    /// moment in the application's life, never two.
    public let reading: DiffResult
    /// True when the tree's digest was identical on two consecutive walks, i.e. the
    /// UI had stopped changing when this reading was taken. False when the deadline
    /// expired first: the reading is the most recent one available, but it may be
    /// partial, or describe a state the application has already moved on from.
    public let settled: Bool

    public init(reading: DiffResult, settled: Bool) {
        self.reading = reading
        self.settled = settled
    }
}
