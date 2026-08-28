import Foundation

/// Resolution of an `act --of <criteria>` target, with an OPT-IN bounded wait.
///
/// Without `--wait` this is exactly what it has always been: one walk, one
/// verdict, and the exit-1 refusals for zero or several matches. With `--wait` the
/// same resolution is POLLED until the criteria yields exactly one actionable
/// element, which is the round-trip that a multi-screen flow otherwise pays twice
/// for (`wait --appears '<criteria>'` then `act ... --of '<criteria>'`, repeating
/// the criteria and starting a second process).
///
/// This does not soften the project's "no implicit synchronization" stance: the
/// wait is written into the invocation, bounded by the duration the caller chose,
/// and absent unless asked for. What it does remove is the duplicated criteria and
/// the second process — a flow becomes press → press → press with no interleaved
/// wait steps, which is what makes it composable with `mtouch batch`.
extension ActPipeline {
    /// Default poll interval for a `--wait`-paced resolution: the SAME 100ms
    /// `mtouch wait` defaults to, so one duration vocabulary covers both.
    static let defaultCriteriaWaitInterval: TimeInterval = 0.1

    /// The element a criteria-targeted verb acts on, together with the walk it was
    /// chosen from — they travel as a pair because the diff baseline MUST be the
    /// tree the acted element provably came from.
    struct CriteriaTarget {
        let tree: LiveElementTree
        let match: ActCriteriaSelection.Match
    }

    /// A resolved target, or a terminal outcome the caller returns as-is.
    enum CriteriaResolution {
        case resolved(CriteriaTarget)
        case terminal(ActOutcome)
    }

    /// Resolve `criteria` to EXACTLY ONE actionable element in the target's tree.
    ///
    /// `wait == nil` keeps the pinned one-shot behaviour byte for byte: a failed
    /// walk is the bounded exit-1 timeout, several matches are the exit-1 refusal
    /// listing candidates, and zero matches is the exit-1 diagnostic advising a
    /// `wait --appears`. Nothing about that path changed, and nothing about it may.
    ///
    /// `wait != nil` polls the SAME resolution over `WaitPoll` (checked before any
    /// sleep, so an already-resolvable criteria costs no interval at all) with the
    /// pinned per-state rules:
    ///   - ZERO matches keep polling; on expiry, exit 4 — waiting longer is exactly
    ///     what might help, which is what exit 4 means in this taxonomy. Note the
    ///     deliberate difference from the no-wait path, where zero stays exit 1.
    ///   - SEVERAL matches ALSO keep polling. Duplicates are commonly TRANSIENT
    ///     while a screen renders — an outgoing view still holding its button while
    ///     the incoming one already has its own — so refusing the instant a second
    ///     match appears would be flaky in precisely the flows this wait exists to
    ///     make reliable. On expiry the diagnostic says the criteria was AMBIGUOUS
    ///     at the last observation and lists the candidates: reporting "it never
    ///     appeared" when the truth is "it matched several" would send an agent
    ///     waiting longer for something that is already there, twice over.
    ///   - Only NON-ACTIONABLE matches keep polling, and the expiry diagnostic
    ///     carries the same "matched N non-actionable element(s)" hint as the
    ///     one-shot refusal.
    ///   - A target that DIES mid-wait fails FAST at exit 1 with the app-gone
    ///     diagnosis, never burning the budget into a misleading exit 4 (the bug
    ///     `wait` itself was fixed for). The liveness consult runs ONLY on a poll
    ///     that observed nothing, so the happy path never pays for it.
    static func resolveCriteriaElement(
        criteria: WaitCriteria,
        app: String,
        pid: pid_t,
        wait: TimeInterval?,
        interval: TimeInterval,
        isRunning: (pid_t, String) -> Bool,
        walkLive: (pid_t) -> LiveElementTree?,
        makeWaitProbe: (pid_t, TimeInterval) -> () -> LiveElementTree?,
        now: () -> TimeInterval,
        sleep: (TimeInterval) -> Void
    ) -> CriteriaResolution {
        guard let wait else {
            // Pre-action walk, retaining handles. The SAME walk resolves the
            // criteria AND provides the diff baseline. A bounded timeout on a
            // wedged target surfaces as an explicit exit-1 diagnostic, never a hang.
            guard let tree = walkLive(pid) else {
                return .terminal(.failed(
                    stderr: inputTimeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure
                ))
            }
            return verdictOutcome(
                ActCriteriaSelection.select(criteria, in: tree.nodes),
                criteria: criteria, app: app, tree: tree
            )
        }

        // Cap the guarded walk's per-sample deadline to the wait's OWN budget, for
        // the same reason `WaitPipeline` does: `sample()` BLOCKS the first poll up
        // to `deadline`, so the stock 8s ceiling would let a hung target overshoot
        // a short `--wait 1s` by ~8x before the poll could observe its own expiry.
        // `max(wait, 1.0)` floors it so a healthy walk still gets a fair window.
        let probe = makeWaitProbe(pid, min(BoundedWalk.defaultDeadline, max(wait, 1.0)))

        var target: CriteriaTarget?
        var lastSeen: [AXNode]?
        var lastAmbiguous: [ActCriteriaSelection.Match] = []
        var lastNonActionable = 0
        var observed = false
        var appGone = false

        _ = WaitPoll.poll(timeout: wait, interval: interval, now: now, sleep: sleep) {
            guard let tree = probe() else {
                // The walk observed NOTHING (its own deadline, or a walk still in
                // flight on a hung target). Consult liveness before polling on: a
                // dead process can never answer, so burning the budget on it would
                // end in a wait timeout when the truth is "the target is gone".
                if !isRunning(pid, app) { appGone = true; return true }
                return false
            }
            observed = true
            lastSeen = tree.nodes
            switch ActCriteriaSelection.select(criteria, in: tree.nodes) {
            case let .one(match):
                target = CriteriaTarget(tree: tree, match: match)
                return true
            case let .ambiguous(matches):
                lastAmbiguous = matches
                lastNonActionable = 0
            case let .none(nonActionable):
                lastAmbiguous = []
                lastNonActionable = nonActionable
            }
            // An empty tree from a live-looking walk is the other shape a dead
            // target takes, so it gets the same consult (and only then).
            if tree.nodes.isEmpty, !isRunning(pid, app) { appGone = true; return true }
            return false
        }

        if appGone {
            return .terminal(.failed(
                stderr: notRunningDiagnostic(app: app, pid: pid), code: .runtimeFailure
            ))
        }
        if let target { return .resolved(target) }
        guard observed else {
            // Not one poll managed to read the tree: that is an unresponsive target,
            // not an absent element, and no amount of extra waiting fixes it. Report
            // it exactly as the one-shot path reports a failed walk (exit 1), never
            // as a wait timeout that invites a longer retry.
            return .terminal(.failed(
                stderr: inputTimeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure
            ))
        }
        if !lastAmbiguous.isEmpty {
            return .terminal(.failed(
                stderr: ambiguousCriteriaWaitDiagnostic(criteria, app: app, wait: wait, matches: lastAmbiguous),
                code: .waitTimeout
            ))
        }
        return .terminal(.failed(
            stderr: absentCriteriaWaitDiagnostic(
                criteria, app: app, wait: wait, roots: lastSeen, nonActionable: lastNonActionable
            ),
            code: .waitTimeout
        ))
    }

    /// The one-shot verdict mapping, unchanged: one acts, several refuse (exit 1)
    /// listing the candidates, zero fails (exit 1) advising a `wait --appears`.
    private static func verdictOutcome(
        _ verdict: ActCriteriaSelection.Verdict,
        criteria: WaitCriteria,
        app: String,
        tree: LiveElementTree
    ) -> CriteriaResolution {
        switch verdict {
        case let .one(match):
            return .resolved(CriteriaTarget(tree: tree, match: match))
        case let .ambiguous(matches):
            return .terminal(.failed(
                stderr: ambiguousCriteriaDiagnostic(criteria, app: app, matches: matches),
                code: .runtimeFailure
            ))
        case let .none(nonActionable):
            return .terminal(.failed(
                stderr: noCriteriaMatchDiagnostic(
                    criteria, app: app, roots: tree.nodes, nonActionable: nonActionable
                ),
                code: .runtimeFailure
            ))
        }
    }

    // MARK: - Expiry diagnostics (two wordings, because the corrections differ)

    /// Exit 4 when `--wait` expired and the criteria NEVER matched an actionable
    /// element. Echoes the criteria, the budget spent, and what WAS visible (the
    /// same summary a `wait` timeout reports), so the criteria can be corrected
    /// without a blind retry. The `wait --appears` advice the one-shot refusal
    /// gives is deliberately absent: the caller already waited.
    static func absentCriteriaWaitDiagnostic(
        _ criteria: WaitCriteria, app: String, wait: TimeInterval, roots: [AXNode]?, nonActionable: Int
    ) -> String {
        var message = "mtouch: timed out after \(WaitPipeline.formatDuration(wait)) waiting for an "
            + "actionable element matching \(criteria.description) in '\(app)': it never appeared."
        if nonActionable > 0 {
            message += " The criteria matched \(nonActionable) non-actionable element(s), which the "
                + "act verbs cannot target."
        }
        return message + " Last seen: \(WaitPipeline.lastSeenSummary(roots)). "
            + "Check the criteria against 'mtouch snapshot --app \(app)', or retry with a longer "
            + "--wait. Nothing was acted on."
    }

    /// Exit 4 when `--wait` expired while the criteria was matching SEVERAL
    /// actionable elements. Deliberately worded apart from the never-appeared case
    /// above: "it never appeared" would be a lie here, and it would send an agent
    /// waiting longer for an element that is already on screen twice over. The
    /// correction is the ambiguity one — narrow the criteria — so the candidates
    /// are listed exactly as the one-shot refusal lists them.
    static func ambiguousCriteriaWaitDiagnostic(
        _ criteria: WaitCriteria, app: String, wait: TimeInterval, matches: [ActCriteriaSelection.Match]
    ) -> String {
        let listed = matches.prefix(maxListedMatches).map { SnapshotText.line(for: $0.node, ref: nil, indent: 0) }
        var message = "mtouch: timed out after \(WaitPipeline.formatDuration(wait)) waiting for "
            + "\(criteria.description) to match exactly one actionable element in '\(app)': at the last "
            + "observation it was AMBIGUOUS — \(matches.count) actionable elements matched, so nothing "
            + "was acted on. Matches: " + listed.joined(separator: "; ")
        if matches.count > listed.count {
            message += "; ... and \(matches.count - listed.count) more"
        }
        return message + ". Narrow the criteria — quote a longer label, or the element's @id "
            + "identifier — so exactly one element matches."
    }
}
