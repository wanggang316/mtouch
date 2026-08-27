import Foundation

/// The fingerprint a quiescence wait compares from poll to poll.
///
/// It deliberately REUSES the session's own tree digest (`Session.digest(of:)` —
/// an FNV-1a hash of the canonical `SnapshotJSON` rendering) rather than inventing
/// a second notion of "the same tree". Three properties come along for free:
///   - it is byte-stable and order-deterministic, so equal digests really do mean
///     an unchanged tree (role, subrole, title, value, enabled, geometry and
///     structure all participate);
///   - secure-field values are already MASKED by the renderer, so a secret is
///     never hashed from its plaintext; and
///   - the renderer's noise filter drops scrollbars and zero-area chrome, so the
///     churn an agent does not care about cannot, by itself, defeat quiescence.
///
/// Because geometry participates, a whole-tree digest also treats a moving
/// element as "still changing" — which is the point (a sliding animation has not
/// settled) but is also why `--of` exists: scope the digest to the subtree whose
/// stability actually matters.
public enum WaitDigest {
    /// The digest of `roots`, optionally narrowed to the elements matching
    /// `criteria` (each contributing its whole subtree, in document order).
    ///
    /// Returns nil when a criteria was given and matched NOTHING. Absence is
    /// deliberately not a digest value: an element that is not there yet has not
    /// "settled", so the caller must treat nil as "keep waiting" rather than as a
    /// stable observation (see `QuiescenceTracker.observe`).
    public static func digest(of roots: [AXNode], scopedTo criteria: WaitCriteria?) -> String? {
        guard let criteria else { return Session.digest(of: Snapshot(roots: roots)) }
        let matched = roots.flatMap(\.flattened).filter { WaitEvaluator.matches($0, criteria) }
        guard !matched.isEmpty else { return nil }
        return Session.digest(of: Snapshot(roots: matched))
    }
}

/// Turns a SEQUENCE of digest observations into the quiescence verdict, keeping
/// the rule pure (no clock, no AX) so every timing edge is provable under a fake
/// clock: the caller supplies the monotonic instant of each observation.
///
/// The rule: the condition is met once the digest has been continuously UNCHANGED
/// for at least `window`. ANY change restarts the quiet window — including a
/// change observed at the very instant the window would otherwise have closed,
/// because the observation is folded in BEFORE the verdict is taken.
///
/// A nil digest (the criteria matched nothing, or the walk failed) is never a
/// stable observation: it clears the quiet window and reports "not met". An
/// element that has not appeared yet is not a settled element.
///
/// The running counters (`changes`, `longestQuiet`, `observations`, `everPresent`)
/// are the evidence the exit-4 diagnostic reports, so an agent can tell "it never
/// stopped changing" from "it never showed up" and decide whether a longer window
/// would help — instead of retrying blind against a bare "timed out".
public struct QuiescenceTracker: Sendable {
    /// How long the digest must stay unchanged for the condition to be met.
    public let window: TimeInterval

    /// How many observations have been folded in (i.e. how many polls ran).
    public private(set) var observations = 0
    /// How many times the digest DIFFERED from the previous observation. The first
    /// observation establishes the baseline and is never counted as a change.
    public private(set) var changes = 0
    /// The longest continuously-unchanged stretch observed so far, in seconds.
    public private(set) var longestQuiet: TimeInterval = 0
    /// Whether any observation ever produced a digest at all — false means the
    /// scope matched nothing on every poll.
    public private(set) var everPresent = false

    private var lastDigest: String?
    private var quietSince: TimeInterval?

    public init(window: TimeInterval) {
        self.window = window
    }

    /// Fold in one observation taken at monotonic instant `time`, returning
    /// whether the quiet window has now been satisfied.
    ///
    /// A `window` of 0 means "no quiet requirement": the first observation that
    /// produces a digest satisfies it.
    public mutating func observe(digest: String?, at time: TimeInterval) -> Bool {
        let isFirst = observations == 0
        let changed = isFirst || digest != lastDigest
        if !isFirst, changed { changes += 1 }
        observations += 1
        lastDigest = digest

        guard digest != nil else {
            // Nothing to be stable ABOUT: restart the window and keep waiting.
            quietSince = nil
            return false
        }

        everPresent = true
        if changed || quietSince == nil { quietSince = time }
        let quiet = time - (quietSince ?? time)
        longestQuiet = max(longestQuiet, quiet)
        return quiet >= window
    }
}
