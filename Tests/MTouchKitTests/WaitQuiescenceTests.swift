import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

private struct StubPermissions: PermissionProvider {
    var accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

/// Deterministic virtual clock: `now()` reads virtual time and `sleep(_:)`
/// advances it. Every quiescence test below runs entirely on this — no real
/// sleeping, no wall-clock reliance, so the timing verdicts are provable rather
/// than merely observed.
private final class Clock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
}

private func staticText(_ value: String) -> AXNode {
    AXNode(role: "AXStaticText", value: value, frame: CGRect(x: 0, y: 0, width: 100, height: 20))
}

private func answerGroup(_ text: String) -> AXNode {
    AXNode(
        role: "AXGroup", title: "answer",
        frame: CGRect(x: 0, y: 0, width: 200, height: 100),
        children: [staticText(text)]
    )
}

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 300),
           children: children)
}

/// The criteria used to scope every `--of` case: `AXGroup "answer"`.
private let answerCriteria = WaitCriteria(parsing: "group \"answer\"")

/// Run the pipeline with a stable condition against a caller-supplied sequence of
/// trees, one per poll (the last is reused once exhausted, modelling a UI that has
/// finished changing). Returns the outcome plus the virtual time it consumed.
private func runStable(
    trees: [[AXNode]],
    of criteria: WaitCriteria? = answerCriteria,
    window stableWindow: TimeInterval,
    timeout: TimeInterval,
    interval: TimeInterval = 0.1
) -> (outcome: WaitOutcome, elapsed: TimeInterval) {
    let clock = Clock()
    var index = 0
    let outcome = WaitPipeline.run(
        bundleId: "com.example.App",
        condition: .stable(of: criteria, window: stableWindow),
        timeout: timeout, interval: interval,
        permissions: StubPermissions(accessibility: true),
        resolvePID: { _ in 4242 },
        now: clock.now, sleep: clock.sleep,
        makeProbe: { _, _ in
            {
                let tree = trees[min(index, trees.count - 1)]
                index += 1
                return tree
            }
        }
    )
    return (outcome, clock.time)
}

// MARK: - The pure quiescence rule

/// Fold a whole sequence of observations into a tracker, returning the verdict at
/// each step. Hoisting the `mutating` calls out of `#expect` keeps the assertions
/// macro-friendly (the macro cannot call a mutating member on its captured value)
/// and makes each test read as "this timeline, these verdicts".
private func verdicts(
    window: TimeInterval, _ timeline: [(TimeInterval, String?)]
) -> (met: [Bool], tracker: QuiescenceTracker) {
    var tracker = QuiescenceTracker(window: window)
    let met = timeline.map { tracker.observe(digest: $0.1, at: $0.0) }
    return (met, tracker)
}

@Suite struct QuiescenceTrackerTests {
    @Test func unchangedDigestIsMetOnlyOnceTheWindowHasElapsed() {
        let (met, tracker) = verdicts(window: 0.5, [(0, "a"), (0.2, "a"), (0.49, "a"), (0.5, "a")])
        #expect(met == [false, false, false, true])
        #expect(tracker.changes == 0)
    }

    @Test func anyChangeRestartsTheQuietWindow() {
        // 0.5s after the FIRST observation there is only 0.2s of quiet since the
        // change, so the window closes at 0.8s instead.
        let (met, tracker) = verdicts(window: 0.5, [(0, "a"), (0.3, "b"), (0.5, "b"), (0.8, "b")])
        #expect(met == [false, false, false, true])
        #expect(tracker.changes == 1)
    }

    @Test func aChangeAtTheVeryEndOfTheWindowResetsItRatherThanSlippingThrough() {
        // The crux: at t=0.5 the window WOULD have closed, but the digest changed at
        // exactly that instant. The observation is folded in BEFORE the verdict, so
        // the answer is "not met" and the quiet window restarts from 0.5.
        let (met, tracker) = verdicts(window: 0.5, [(0, "a"), (0.4, "a"), (0.5, "b"), (0.9, "b"), (1.0, "b")])
        #expect(met == [false, false, false, false, true])
        #expect(tracker.changes == 1)
    }

    @Test func anAbsentScopeIsNeverStableAndClearsTheWindow() {
        // Absent for a long stretch (never met, never "present"), then it appears
        // and settles — the window runs from FIRST SIGHT, not from the start.
        let (met, tracker) = verdicts(
            window: 0.2, [(0, nil), (5, nil), (6, "a"), (6.1, "a"), (6.2, "a")]
        )
        #expect(met == [false, false, false, false, true])
        #expect(tracker.everPresent)

        let (absentOnly, absentTracker) = verdicts(window: 0.2, [(0, nil), (5, nil)])
        #expect(absentOnly == [false, false])
        #expect(absentTracker.everPresent == false)
        #expect(absentTracker.longestQuiet == 0)
    }

    @Test func disappearingAgainClearsTheQuietWindow() {
        // 0.3s after the first sighting the window would have closed, but the
        // element vanished in between, so the clock restarts at its return.
        let (met, _) = verdicts(window: 0.3, [(0, "a"), (0.2, "a"), (0.25, nil), (0.3, "a"), (0.6, "a")])
        #expect(met == [false, false, false, false, true])
    }

    @Test func countersReportChangesAndTheLongestQuietStretch() {
        let (_, tracker) = verdicts(
            window: 10,
            [(0, "a"), (0.4, "a"), (0.5, "b"), (0.6, "c"), (1.3, "c"), (1.4, "d")]
        )
        #expect(tracker.changes == 3)
        #expect(tracker.observations == 6)
        #expect(abs(tracker.longestQuiet - 0.7) < 0.000_001) // the c→c stretch
    }

    @Test func aZeroWindowIsSatisfiedByTheFirstPresentObservation() {
        let (met, _) = verdicts(window: 0, [(0, "a")])
        #expect(met == [true])
    }

    @Test func aZeroWindowStillRefusesAnAbsentScope() {
        // "No quiet requirement" is not "no element requirement".
        let (met, _) = verdicts(window: 0, [(0, nil)])
        #expect(met == [false])
    }
}

// MARK: - The scoped digest

@Suite struct WaitDigestTests {
    @Test func anUnchangedTreeDigestsIdentically() {
        let tree = [window([answerGroup("hello")])]
        #expect(WaitDigest.digest(of: tree, scopedTo: nil) == WaitDigest.digest(of: tree, scopedTo: nil))
    }

    @Test func changedTextChangesTheDigest() {
        let before = WaitDigest.digest(of: [window([answerGroup("hel")])], scopedTo: nil)
        let after = WaitDigest.digest(of: [window([answerGroup("hello")])], scopedTo: nil)
        #expect(before != after)
    }

    @Test func scopingIgnoresChangesOutsideTheCriteria() throws {
        // A spinner churning elsewhere must not defeat a scoped stability wait.
        let first = [window([answerGroup("done"), staticText("tick 1")])]
        let second = [window([answerGroup("done"), staticText("tick 2")])]
        let scopedFirst = try #require(WaitDigest.digest(of: first, scopedTo: answerCriteria))
        let scopedSecond = try #require(WaitDigest.digest(of: second, scopedTo: answerCriteria))
        #expect(scopedFirst == scopedSecond)
        #expect(WaitDigest.digest(of: first, scopedTo: nil) != WaitDigest.digest(of: second, scopedTo: nil))
    }

    @Test func scopingStillSeesChangesInsideTheCriteria() {
        let first = [window([answerGroup("hel")])]
        let second = [window([answerGroup("hello")])]
        #expect(WaitDigest.digest(of: first, scopedTo: answerCriteria)
            != WaitDigest.digest(of: second, scopedTo: answerCriteria))
    }

    @Test func aCriteriaThatMatchesNothingHasNoDigest() {
        #expect(WaitDigest.digest(of: [window([staticText("x")])], scopedTo: answerCriteria) == nil)
    }

    @Test func anEmptyTreeStillHasAWholeTreeDigest() {
        // Absence of a SCOPE is nil; an empty whole tree is simply a digest of "[]".
        #expect(WaitDigest.digest(of: [], scopedTo: nil) != nil)
    }
}

// MARK: - Grammar

@Suite struct WaitStableGrammarTests {
    @Test func stableAloneIsAValidCondition() {
        #expect(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: nil,
            stable: true, stableFor: 0.5, timeout: 5
        ) == nil)
    }

    @Test func stableParticipatesInTheExactlyOneRule() throws {
        let both = try #require(WaitGrammar.selectionError(
            appears: "button", disappears: nil, text: nil, valueEquals: nil, of: nil,
            stable: true, stableFor: nil, timeout: 5
        ))
        #expect(both.contains("only one condition"))
        #expect(both.contains("--stable"))

        let none = try #require(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: nil,
            stable: false, stableFor: nil, timeout: 5
        ))
        #expect(none.contains("--stable"))
    }

    @Test func ofScopesStableAsWellAsValueEquals() {
        #expect(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: "group \"answer\"",
            stable: true, stableFor: nil, timeout: 5
        ) == nil)
    }

    @Test func ofWithoutValueEqualsOrStableIsStillRefused() throws {
        let message = try #require(WaitGrammar.selectionError(
            appears: "button", disappears: nil, text: nil, valueEquals: nil, of: "group",
            stable: false, stableFor: nil, timeout: 5
        ))
        #expect(message.contains("--of"))
    }

    @Test func stableForRequiresStable() throws {
        let message = try #require(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: "hi", valueEquals: nil, of: nil,
            stable: false, stableFor: 0.5, timeout: 5
        ))
        #expect(message.contains("--stable-for is only valid together with --stable"))
    }

    @Test func stableForLongerThanTimeoutIsAUsageError() throws {
        let message = try #require(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: nil,
            stable: true, stableFor: 5, timeout: 2
        ))
        #expect(message.contains("--stable-for"))
        #expect(message.contains("5s"))
        #expect(message.contains("2s"))
        #expect(message.contains("never fit"))
    }

    @Test func theDefaultWindowIsAlsoCheckedAgainstTheTimeout() throws {
        // Without this, `--stable --timeout 200ms` would be accepted and then time
        // out with mathematical certainty — the silent failure the feature exists
        // to kill. The message names the DEFAULT so the fix is obvious.
        let message = try #require(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: nil,
            stable: true, stableFor: nil, timeout: 0.2
        ))
        #expect(message.contains("the default --stable-for (500ms)"))
        #expect(message.contains("200ms"))

        // A timeout that comfortably fits the default is untouched.
        #expect(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: nil,
            stable: true, stableFor: nil, timeout: 0.5
        ) == nil)
    }

    @Test func stableForEqualToTimeoutIsAllowed() {
        // The documented degenerate case: it succeeds only if the tree never
        // changed at all across the whole budget (asserted end-to-end below).
        #expect(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: nil,
            stable: true, stableFor: 2, timeout: 2
        ) == nil)
    }

    @Test func makeConditionBuildsStableWithTheDefaultWindow() {
        let condition = WaitGrammar.makeCondition(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: nil,
            stable: true, stableFor: nil
        )
        #expect(condition == .stable(of: nil, window: WaitGrammar.defaultStableWindow))
        #expect(WaitGrammar.defaultStableWindow == 0.5)
    }

    @Test func makeConditionCarriesTheScopeAndWindow() {
        let condition = WaitGrammar.makeCondition(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: "group \"answer\"",
            stable: true, stableFor: 1.5
        )
        #expect(condition == .stable(of: answerCriteria, window: 1.5))
    }

    @Test func theStableDescriptionNamesTheScopeAndWindow() {
        #expect(WaitCondition.stable(of: nil, window: 0.5).description
            == "the accessibility tree to stop changing for 500ms")
        #expect(WaitCondition.stable(of: answerCriteria, window: 2).description
            == "elements matching AXGroup \"answer\" to stop changing for 2s")
    }

    @Test func quiescenceIsNotDecidableFromOneTree() {
        // Pinned, not accidental: a single tree is never evidence of stability, and
        // the pipeline routes `.stable` away from the stateless evaluator.
        #expect(WaitEvaluator.isStateless(.stable(of: nil, window: 1)) == false)
        #expect(WaitEvaluator.isStateless(.text("hi")))
        #expect(WaitEvaluator.evaluate(.stable(of: nil, window: 1), in: [window([])]) == false)
    }
}

// MARK: - End-to-end under the fake clock

@Suite struct WaitStablePipelineTests {
    @Test func aStreamThatStopsIsMetOnlyAfterTheQuietWindowElapses() {
        // Five polls of growing text (t=0…0.4), then it stops. With a 0.5s window
        // the earliest possible success is 0.4 + 0.5 = 0.9s.
        // The upper bound carries one interval of slack throughout this suite: the
        // window can only close AT a poll, so the observable success instant is the
        // first poll at or after the deadline.
        let stream = ["a", "ab", "abc", "abcd", "abcde"].map { [window([answerGroup($0)])] }
        let (outcome, elapsed) = runStable(trees: stream, window: 0.5, timeout: 10)

        #expect(outcome == .satisfied)
        #expect(elapsed >= 0.9)          // never before last-change + window
        #expect(elapsed < 0.9 + 2 * 0.1) // and never more than a poll or so after
    }

    @Test func aStreamThatNeverStopsTimesOutWithExitFour() {
        // A tree that changes on EVERY poll: the quiet window never closes.
        let clock = Clock()
        var tick = 0
        let outcome = WaitPipeline.run(
            bundleId: "com.example.App",
            condition: .stable(of: answerCriteria, window: 0.5),
            timeout: 2, interval: 0.1,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in
                {
                    tick += 1
                    return [window([answerGroup("chunk \(tick)")])]
                }
            }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(code == .waitTimeout)
        #expect(clock.time >= 2) // it honestly waited the full budget
        #expect(stderr.contains("timed out"))
        #expect(stderr.contains("to stop changing for 500ms"))
    }

    @Test func theTimeoutDiagnosticReportsChangesAndTheLongestQuietStretch() {
        // Digest changes every OTHER poll (interval 0.1s), so the longest quiet
        // stretch is one interval — exactly the number an agent needs to decide
        // that a shorter --stable-for, not a longer --timeout, is the fix.
        let clock = Clock()
        var tick = 0
        let outcome = WaitPipeline.run(
            bundleId: "com.example.App",
            condition: .stable(of: answerCriteria, window: 0.5),
            timeout: 1, interval: 0.1,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in
                {
                    defer { tick += 1 }
                    return [window([answerGroup("chunk \(tick / 2)")])]
                }
            }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(code == .waitTimeout)
        #expect(stderr.contains("change(s)"))
        #expect(stderr.contains("longest quiet stretch was 100ms"))
        #expect(stderr.contains("of the 500ms required"))
        #expect(stderr.contains("Retry with a longer --timeout"))
        #expect(stderr.contains("Last seen"))
    }

    @Test func anAbsentScopeTimesOutAndSaysSoRatherThanSucceedingInstantly() {
        // The pinned rule: `--of` matching nothing is NOT instant success. The
        // diagnostic must blame the criteria, not the durations.
        let (outcome, elapsed) = runStable(
            trees: [[window([staticText("nothing relevant")])]], window: 0.2, timeout: 1
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(code == .waitTimeout)
        #expect(elapsed >= 1) // it kept waiting for the whole budget
        #expect(stderr.contains("matched no element"))
        #expect(stderr.contains("has not settled"))
        #expect(stderr.contains("longest quiet stretch") == false) // not a duration problem
    }

    @Test func anElementThatAppearsLateIsWaitedForThenSettled() {
        // Absent for the first three polls (t=0,0.1,0.2), then present and static.
        // First sighting is t=0.3, so a 0.2s window can close no earlier than 0.5s.
        let absent = [window([staticText("loading")])]
        let present = [window([staticText("loading"), answerGroup("here")])]
        let (outcome, elapsed) = runStable(
            trees: [absent, absent, absent, present], window: 0.2, timeout: 5
        )

        #expect(outcome == .satisfied)
        #expect(elapsed >= 0.5)          // never before first-sight + window
        #expect(elapsed < 0.5 + 2 * 0.1) // and never more than a poll or so after
    }

    @Test func stableForEqualToTimeoutSucceedsOnlyForAnAlreadyStillTree() {
        // Documented degenerate case, both directions.
        let still = [window([answerGroup("done")])]
        let (met, elapsed) = runStable(trees: [still], window: 1, timeout: 1)
        #expect(met == .satisfied)
        #expect(elapsed >= 1) // it had to observe the whole budget quietly

        let churn = (0..<50).map { [window([answerGroup("chunk \($0)")])] }
        let (unmet, _) = runStable(trees: churn, window: 1, timeout: 1)
        guard case let .failed(_, code) = unmet else {
            Issue.record("a tree that keeps changing must not satisfy a full-budget window"); return
        }
        #expect(code == .waitTimeout)
    }

    @Test func theWholeTreeIsWatchedWhenNoScopeIsGiven() {
        // No --of: a change ANYWHERE resets the window, including outside the
        // element an agent cares about.
        let churn = (0..<50).map { [window([answerGroup("done"), staticText("tick \($0)")])] }
        let (outcome, _) = runStable(trees: churn, of: nil, window: 0.5, timeout: 2)
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(code == .waitTimeout)
        #expect(stderr.contains("the accessibility tree to stop changing"))
    }

    @Test func aHungWalkNeverCountsAsStability() {
        // A probe that always fails (nil, as GuardedWalk yields on a hung target)
        // must not read as "unchanged, therefore settled" — it times out (exit 4).
        // Modelled synchronously, so no background walk thread is created.
        let clock = Clock()
        let outcome = WaitPipeline.run(
            bundleId: "com.example.App",
            condition: .stable(of: nil, window: 0.2),
            timeout: 1, interval: 0.1,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in { nil } }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(code == .waitTimeout)
        #expect(stderr.contains("nothing (no elements were read"))
    }

    @Test func missingGrantStillFailsFastWithoutPolling() {
        let clock = Clock()
        let outcome = WaitPipeline.run(
            bundleId: "com.example.App",
            condition: .stable(of: nil, window: 0.5),
            timeout: 5, interval: 0.1,
            permissions: StubPermissions(accessibility: false),
            resolvePID: { _ in Issue.record("must not resolve without the grant"); return 1 },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in { Issue.record("must not poll without the grant"); return nil } }
        )

        guard case let .failed(_, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .permissionMissing)
        #expect(clock.time == 0)
    }
}
