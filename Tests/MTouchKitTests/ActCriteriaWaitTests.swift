import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

private struct StubPermissions: PermissionProvider {
    let accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

/// Deterministic virtual clock shared by `now`/`sleep`: it advances ONLY when the
/// poll loop sleeps, so every timing assertion below is exact and no test ever
/// waits on wall time.
private final class Clock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
}

private func keypadButton(_ description: String, id identifier: String) -> AXNode {
    AXNode(
        role: kAXButtonRole, description: description, identifier: identifier,
        frame: CGRect(x: 0, y: 0, width: 40, height: 40), actionable: true
    )
}

private func window(_ children: [AXNode], title: String = "W") -> AXNode {
    AXNode(role: kAXWindowRole, title: title, frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

/// A handle-bearing tree over `roots`, giving every path a DISTINGUISHABLE
/// sentinel handle so a test can assert WHICH element was acted on.
private func liveTree(_ roots: [AXNode]) -> LiveElementTree {
    var elements: [[Int]: AXUIElement] = [:]
    var attributes: [[Int]: AXAttributes] = [:]
    var seed: pid_t = 1000
    func visit(_ node: AXNode, path: [Int]) {
        elements[path] = AXUIElementCreateApplication(seed)
        attributes[path] = AXAttributes(role: "AXStub")
        seed += 1
        for (index, child) in node.children.enumerated() { visit(child, path: path + [index]) }
    }
    for (index, root) in roots.enumerated() { visit(root, path: [index]) }
    return LiveElementTree(nodes: roots, elementsByPath: elements, attributesByPath: attributes)
}

/// The screen BEFORE the awaited button exists: a keypad that does not carry it.
private func screenWithout() -> LiveElementTree {
    liveTree([window([keypadButton("7", id: "Seven")])])
}

/// The screen once the awaited button has rendered.
private func screenWith() -> LiveElementTree {
    liveTree([window([keypadButton("7", id: "Seven"), keypadButton("等于", id: "Equals")])])
}

/// A screen rendering a DUPLICATE of the awaited button — the transient state a
/// cross-fade produces, with the outgoing view still holding its own copy.
private func screenWithDuplicates() -> LiveElementTree {
    liveTree([window([keypadButton("等于", id: "Equals"), keypadButton("等于", id: "Equals")])])
}

/// A screen where the criteria matches only an INERT element.
private func screenWithInertMatchOnly() -> LiveElementTree {
    liveTree([window([AXNode(role: kAXStaticTextRole, value: "Equals")])])
}

/// A scripted target: what each poll's walk observes, and (optionally) the poll at
/// which its process is gone. The last scripted observation repeats forever, so a
/// "never appears" script is a single entry.
private final class FakeTarget {
    private let observations: [LiveElementTree?]
    private let diesAtPoll: Int?
    private(set) var polls = 0

    init(_ observations: [LiveElementTree?], diesAtPoll: Int? = nil) {
        self.observations = observations
        self.diesAtPoll = diesAtPoll
    }

    func probe() -> LiveElementTree? {
        polls += 1
        return observations[min(polls - 1, observations.count - 1)]
    }

    /// Liveness as the pipeline consults it: alive until the poll the process dies
    /// at, gone from then on.
    func isRunning() -> Bool {
        guard let diesAtPoll else { return true }
        return polls < diesAtPoll
    }
}

private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-act-criteria-wait-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

// MARK: - Grammar: --wait requires --of, --interval requires --wait (exit 64)

@Suite struct ActWaitGrammarTests {
    @Test func waitBesideARefIsRefusedNamingWhyARefCannotBeWaitedFor() {
        let message = ActTargetGrammar.selectionError(ref: "e5", of: nil, app: nil, hasWait: true)
        #expect(message?.contains("--wait is only valid together with --of") == true)
        // It says WHY, not merely that it is invalid: a ref addresses a snapshot
        // that already happened, so there is nothing left to wait for.
        #expect(message?.contains("snapshot that has already been taken") == true)
        #expect(message?.contains("nothing to wait for") == true)
    }

    @Test func waitWithNoTargetAtAllIsRefusedForTheSameReason() {
        let message = ActTargetGrammar.selectionError(ref: nil, of: nil, app: nil, hasWait: true)
        #expect(message?.contains("--wait is only valid together with --of") == true)
    }

    @Test func intervalWithoutWaitIsRefusedRatherThanSilentlyIgnored() {
        let message = ActTargetGrammar.selectionError(
            ref: nil, of: "button \"Seven\"", app: "com.example.App", hasWait: false, hasInterval: true
        )
        #expect(message?.contains("--interval is only valid together with --wait") == true)
        #expect(message?.contains("no polling") == true)
    }

    @Test func intervalBesideARefIsRefusedByTheWaitRuleFirst() {
        // Both rules are violated; the WAIT one is reported, because it is the one
        // that explains the invocation the user actually wrote.
        let message = ActTargetGrammar.selectionError(
            ref: "e5", of: nil, app: nil, hasWait: true, hasInterval: true
        )
        #expect(message?.contains("--wait is only valid together with --of") == true)
    }

    @Test func waitAndIntervalBesideAWellFormedOfPass() {
        #expect(ActTargetGrammar.selectionError(
            ref: nil, of: "button \"Seven\"", app: "com.example.App", hasWait: true
        ) == nil)
        #expect(ActTargetGrammar.selectionError(
            ref: nil, of: "button \"Seven\"", app: "com.example.App", hasWait: true, hasInterval: true
        ) == nil)
    }

    /// The pre-existing selections are decided exactly as before: adding the wait
    /// rules must not change any verdict for an invocation that carries no wait.
    @Test func selectionsWithoutAWaitAreUnchanged() {
        #expect(ActTargetGrammar.selectionError(ref: "e5", of: nil, app: nil) == nil)
        #expect(ActTargetGrammar.selectionError(ref: nil, of: "button", app: "a") == nil)
        #expect(ActTargetGrammar.selectionError(ref: nil, of: nil, app: nil)?
            .contains("exactly one target") == true)
        #expect(ActTargetGrammar.selectionError(ref: "e5", of: "button", app: "a")?
            .contains("cannot be combined") == true)
        #expect(ActTargetGrammar.selectionError(ref: nil, of: "button", app: nil)?
            .contains("--of requires --app") == true)
    }
}

// MARK: - Polling semantics (fake clock; no real timing anywhere)

@Suite struct ActCriteriaWaitTests {
    private let app = "com.example.Calc"
    private let pid: pid_t = 4242
    private let criteria = #"button "等于""#

    /// One `runCriteria` run over a scripted target, every AX seam stubbed.
    /// `wait: nil` exercises the untouched one-shot path (which reads the target's
    /// FIRST observation through `walkLive`), so the two paths can be compared
    /// against the identical tree.
    private func run(
        target: FakeTarget,
        wait: TimeInterval?,
        interval: TimeInterval = 0.1,
        criteria: String? = nil,
        clock: Clock,
        sessionDir: URL,
        onAct: @escaping (AXUIElement) -> Void = { _ in },
        observeDeadline: @escaping (TimeInterval) -> Void = { _ in }
    ) -> ActOutcome {
        ActPipeline.runCriteria(
            criteria: WaitCriteria(parsing: criteria ?? self.criteria),
            verb: .press,
            value: nil,
            app: app,
            wait: wait,
            interval: interval,
            json: false,
            environment: [MTouchEnvironment.sessionKey: sessionDir.appendingPathComponent("session.json").path],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in nil },
            resolvePID: { [pid] _ in pid },
            isRunning: { _, _ in target.isRunning() },
            walkLive: { _ in target.probe() },
            makeWaitProbe: { _, deadline in
                observeDeadline(deadline)
                return { target.probe() }
            },
            rewalk: { _ in
                WalkResult(nodes: [window([keypadButton("7", id: "Seven")])],
                           windowIDsByPath: [:], fallbackFired: false, fallbackHelped: false,
                           truncated: false)
            },
            performAction: { element, _, _ in onAct(element); return .success(()) },
            persist: { _, _, _, _ in },
            now: clock.now,
            sleep: clock.sleep
        )
    }

    // MARK: Appearing

    /// The motivating case: the element is not there yet, then it is. The act
    /// happens on the poll that finds it, and the elapsed time is exactly the
    /// intervals actually slept — no more.
    @Test func absentForSeveralPollsThenAppearingActs() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([
                screenWithout(), screenWithout(), screenWithout(), screenWith(),
            ])
            var actedAt: TimeInterval?
            let outcome = run(
                target: target, wait: 5, clock: clock, sessionDir: dir,
                onAct: { _ in actedAt = clock.now() }
            )
            guard case .acted = outcome else {
                Issue.record("expected an acted outcome, got \(outcome)"); return
            }
            #expect(target.polls == 4)
            // Three sleeps of one interval each preceded the successful fourth poll.
            // Snapped to milliseconds, as every measured duration in this project is:
            // accumulated interval arithmetic is not exact in binary floating point.
            #expect(WaitPipeline.roundedToMilliseconds(actedAt ?? -1) == 0.3)
        }
    }

    /// An already-resolvable criteria must cost NOTHING: `WaitPoll` checks before
    /// it sleeps, so the happy path adds no poll interval of latency.
    @Test func immediatelyResolvableActsWithoutAnExtraInterval() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([screenWith()])
            var actedAt: TimeInterval?
            var polled = false
            let outcome = run(
                target: target, wait: 5, clock: clock, sessionDir: dir,
                onAct: { _ in actedAt = clock.now() },
                observeDeadline: { _ in polled = true }
            )
            guard case .acted = outcome else {
                Issue.record("expected an acted outcome, got \(outcome)"); return
            }
            // The POLLED path really ran (its probe seam was built), and it still
            // acted on the first observation with the clock untouched.
            #expect(polled)
            #expect(target.polls == 1)
            #expect(actedAt == 0)
        }
    }

    /// Ambiguity is treated as TRANSIENT: the poll continues, and once the screen
    /// settles onto a single match the act proceeds — on that match's handle.
    @Test func ambiguousThenResolvingToOneActsOnTheSurvivor() throws {
        try withTempDir { dir in
            let clock = Clock()
            let resolved = screenWith()
            let target = FakeTarget([screenWithDuplicates(), screenWithDuplicates(), resolved])
            var acted: AXUIElement?
            let outcome = run(
                target: target, wait: 5, clock: clock, sessionDir: dir, onAct: { acted = $0 }
            )
            guard case .acted = outcome else {
                Issue.record("expected an acted outcome, got \(outcome)"); return
            }
            let performed = try #require(acted)
            let expected = try #require(resolved.elementsByPath[[0, 1]])
            #expect(CFEqual(performed, expected))
        }
    }

    // MARK: Expiry

    @Test func neverAppearingIsWaitTimeoutNamingTheCriteriaAndWhatWasSeen() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([screenWithout()])
            let outcome = run(
                target: target, wait: 1, clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("a criteria that never matched must act on NOTHING") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            // Exit 4, not 1: with a wait in play, "waiting longer might help" is
            // exactly the taxonomy this belongs in.
            #expect(code == .waitTimeout)
            #expect(stderr.contains("timed out after 1s"))
            #expect(stderr.contains("AXButton \"等于\""))
            #expect(stderr.contains("it never appeared"))
            // The last-seen summary, so the criteria can be corrected in one go.
            #expect(stderr.contains("Last seen:"))
            #expect(stderr.contains("AXButton×1"))
            #expect(stderr.contains("Nothing was acted on"))
            // The budget was actually spent (the loop never gives up early).
            #expect(clock.now() >= 1)
        }
    }

    /// The distinction the diagnostics MUST keep: an element that never appeared
    /// and a criteria that matched several are different failures with different
    /// corrections, so they never share a wording.
    @Test func ambiguousOnExpiryReportsAmbiguityAndListsTheCandidates() {
        withTempDir { dir in
            var absentStderr = ""
            var ambiguousStderr = ""
            withTempDir { other in
                let clock = Clock()
                let outcome = run(
                    target: FakeTarget([screenWithout()]), wait: 1, clock: clock, sessionDir: other,
                    onAct: { _ in Issue.record("must not act") }
                )
                if case let .failed(stderr, _) = outcome { absentStderr = stderr }
            }
            let clock = Clock()
            let outcome = run(
                target: FakeTarget([screenWithDuplicates()]), wait: 1, clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("an ambiguous criteria must act on NOTHING") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            ambiguousStderr = stderr
            #expect(code == .waitTimeout)
            #expect(stderr.contains("AMBIGUOUS"))
            #expect(stderr.contains("2 actionable elements matched"))
            // The candidates are listed on their snapshot-text lines, so a narrower
            // criteria can be written straight from the refusal.
            #expect(stderr.contains("AXButton \"等于\"@desc"))
            #expect(stderr.contains("Narrow the criteria"))
            // NEVER the never-appeared wording: reporting absence for something
            // that is on screen twice sends an agent waiting for what is there.
            #expect(!stderr.contains("never appeared"))
            #expect(!absentStderr.isEmpty)
            #expect(absentStderr != ambiguousStderr)
            #expect(absentStderr.contains("never appeared"))
            #expect(!absentStderr.contains("AMBIGUOUS"))
        }
    }

    /// Only inert matches keep polling too, and the expiry diagnostic carries the
    /// same "matched N non-actionable element(s)" hint the one-shot refusal gives —
    /// a different correction than "no such element".
    @Test func nonActionableOnlyMatchesCarryTheirHintIntoTheTimeout() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([screenWithInertMatchOnly()])
            let outcome = run(
                target: target, wait: 1, criteria: "statictext \"Equals\"", clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("must not act") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .waitTimeout)
            #expect(stderr.contains("matched 1 non-actionable element(s)"))
            #expect(stderr.contains("it never appeared"))
        }
    }

    // MARK: Dead target

    /// The bug this pass must not reintroduce: a target that dies mid-wait is
    /// diagnosed AS DEAD, immediately — never left to burn the whole budget into a
    /// wait timeout that invites a longer retry.
    @Test func targetDyingMidWaitFailsFastWithTheAppGoneDiagnosis() {
        withTempDir { dir in
            let clock = Clock()
            // Two ordinary polls, then the walk observes nothing and the process
            // is gone.
            let target = FakeTarget([screenWithout(), screenWithout(), nil], diesAtPoll: 3)
            let outcome = run(
                target: target, wait: 60, clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("must not act on a dead target") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr == AppGone.diagnostic(app: app, pid: pid))
            #expect(target.polls == 3)
            // Two intervals, not sixty seconds.
            #expect(WaitPipeline.roundedToMilliseconds(clock.now()) == 0.2)
        }
    }

    /// The other shape a dead target takes: the walk still SUCCEEDS but yields an
    /// empty tree. That gets the same consult, and the same fast diagnosis.
    @Test func anEmptyTreeFromADeadTargetIsAlsoDiagnosedAsAppGone() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([screenWithout(), liveTree([])], diesAtPoll: 2)
            let outcome = run(
                target: target, wait: 60, clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("must not act on a dead target") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr == AppGone.diagnostic(app: app, pid: pid))
            #expect(WaitPipeline.roundedToMilliseconds(clock.now()) == 0.1)
        }
    }

    /// A LIVE but unresponsive target keeps polling (that is what a wait is for),
    /// and when no poll ever manages to read the tree the failure is the bounded
    /// walk timeout — exit 1 with the modal-panel way forward, never an exit 4 that
    /// would invite waiting even longer on a wedged app.
    @Test func aWalkThatNeverSucceedsIsTheBoundedTimeoutNotAWaitTimeout() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([nil])
            let outcome = run(
                target: target, wait: 1, clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("must not act") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("appears unresponsive"))
            #expect(stderr.contains("--no-verify"))
            #expect(target.polls > 1)
        }
    }

    // MARK: Bounds

    /// The polled walk's per-sample deadline is capped to the wait's OWN budget, so
    /// a hung target cannot overshoot a short wait by the walk ceiling; a long wait
    /// keeps the stock ceiling, and a very short one keeps a 1s floor so a healthy
    /// walk is never starved.
    @Test func thePolledWalkDeadlineIsCappedToTheWaitBudget() {
        withTempDir { dir in
            var deadlines: [TimeInterval] = []
            for wait in [0.5, 3.0, 60.0] {
                let clock = Clock()
                _ = run(
                    target: FakeTarget([screenWith()]), wait: wait, clock: clock, sessionDir: dir,
                    observeDeadline: { deadlines.append($0) }
                )
            }
            #expect(deadlines == [1.0, 3.0, BoundedWalk.defaultDeadline])
        }
    }

    /// `--interval` paces the poll: a longer interval means fewer polls over the
    /// same budget, and it is honoured exactly.
    @Test func theIntervalPacesThePoll() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([screenWithout()])
            _ = run(
                target: target, wait: 1, interval: 0.5, clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("must not act") }
            )
            // t=0, 0.5, 1.0 — the third poll runs, then the deadline is reached.
            #expect(target.polls == 3)
            #expect(WaitPipeline.roundedToMilliseconds(clock.now()) == 1)
        }
    }

    /// `--wait 0` is a legal boundary, not a no-op: exactly ONE check, then the
    /// verdict — the same guarantee `wait --timeout 0` gives. It still reports the
    /// WAIT taxonomy (exit 4), because a wait was asked for.
    @Test func waitZeroTakesExactlyOneCheckAndStillReportsTheWaitTaxonomy() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([screenWithout()])
            let outcome = run(
                target: target, wait: 0, clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("must not act") }
            )
            guard case let .failed(_, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .waitTimeout)
            #expect(target.polls == 1)
            #expect(clock.now() == 0)
        }
    }

    // MARK: The no-wait path is untouched

    /// The deliberate difference, pinned from both sides: the SAME zero-match tree
    /// is exit 1 without `--wait` (with the `wait --appears` advice) and exit 4
    /// with it (with the timeout wording). Neither borrows the other's exit code.
    @Test func withoutWaitZeroMatchesStaysExit1AndDoesNotPoll() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([screenWithout()])
            let outcome = run(
                target: target, wait: nil, clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("must not act") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("no actionable element matching"))
            #expect(stderr.contains("mtouch wait --app \(app) --appears"))
            #expect(!stderr.contains("timed out"))
            // Exactly ONE walk, and not one tick of the clock: no wait was asked
            // for, so none was taken.
            #expect(target.polls == 1)
            #expect(clock.now() == 0)
        }
    }

    /// Likewise for ambiguity: without a wait it refuses immediately at exit 1,
    /// with the pre-existing wording.
    @Test func withoutWaitSeveralMatchesStayExit1AndDoNotPoll() {
        withTempDir { dir in
            let clock = Clock()
            let target = FakeTarget([screenWithDuplicates()])
            let outcome = run(
                target: target, wait: nil, clock: clock, sessionDir: dir,
                onAct: { _ in Issue.record("must not act") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("matches 2 actionable elements"))
            #expect(!stderr.contains("timed out"))
            #expect(target.polls == 1)
        }
    }
}

// MARK: - MCP parity

@Suite struct ActWaitMCPParityTests {
    private let ungranted = StubPermissions(accessibility: false)

    private func call(_ args: [String: ToolArgumentValue]) -> ToolResult {
        MCPToolDispatch.dispatch(
            tool: "act", arguments: ToolArguments(args), environment: [:], permissions: ungranted
        )
    }

    private func message(_ result: ToolResult) -> String {
        for payload in result.payloads {
            if case let .text(value) = payload { return value }
        }
        return ""
    }

    /// The catalog gains two OPTIONAL string properties on the existing `act`
    /// tool — no tool added or renamed, no change to the required set.
    @Test func actAdvertisesWaitAndIntervalWithoutChangingTheToolset() throws {
        #expect(MCPToolCatalog.tools.count == 10)
        let spec = try #require(MCPToolCatalog.tools.first { $0.name == "act" })
        let wait = try #require(spec.properties.first { $0.name == "wait" })
        #expect(wait.type == "string")
        #expect(wait.description.contains("Requires of"))
        let interval = try #require(spec.properties.first { $0.name == "interval" })
        #expect(interval.type == "string")
        #expect(interval.description.contains("Requires wait"))
        #expect(spec.required == ["verb"])
    }

    /// The refusals are the CLI's, byte for byte: both surfaces run the same
    /// grammar, so an agent that switches surfaces re-learns nothing.
    @Test func waitBesideARefIsRefusedWithTheCLIsMessage() {
        let result = call([
            "verb": .string("press"), "ref": .string("e5"), "wait": .string("3s"),
        ])
        #expect(result.isError)
        let expected = ActTargetGrammar.selectionError(ref: "e5", of: nil, app: nil, hasWait: true)
        #expect(message(result) == "mtouch: invalid arguments: " + (expected ?? ""))
    }

    @Test func intervalWithoutWaitIsRefusedWithTheCLIsMessage() {
        let result = call([
            "verb": .string("press"), "of": .string("button \"Seven\""),
            "app": .string("com.example.App"), "interval": .string("200ms"),
        ])
        #expect(result.isError)
        let expected = ActTargetGrammar.selectionError(
            ref: nil, of: "button \"Seven\"", app: "com.example.App", hasWait: false, hasInterval: true
        )
        #expect(message(result) == "mtouch: invalid arguments: " + (expected ?? ""))
    }

    @Test func malformedWaitDurationIsAnInvalidArgument() {
        let result = call([
            "verb": .string("press"), "of": .string("button \"Seven\""),
            "app": .string("com.example.App"), "wait": .string("soon"),
        ])
        #expect(result.isError)
        #expect(message(result).contains("'wait' must be a valid duration"))
    }

    @Test func malformedIntervalDurationIsAnInvalidArgument() {
        let result = call([
            "verb": .string("press"), "of": .string("button \"Seven\""),
            "app": .string("com.example.App"), "wait": .string("3s"), "interval": .string("-1"),
        ])
        #expect(result.isError)
        #expect(message(result).contains("'interval' must be a valid duration"))
    }

    /// A well-formed wait passes the grammar and reaches the pipeline, which stops
    /// at the permission gate here — proving the arguments were ACCEPTED rather
    /// than refused by the shape check.
    @Test func aWellFormedWaitReachesThePipeline() {
        let result = call([
            "verb": .string("press"), "of": .string("button \"Seven\""),
            "app": .string("com.example.App"), "wait": .string("3s"), "interval": .string("200ms"),
        ])
        #expect(result.isError)
        #expect(message(result).contains("Accessibility"))
    }

    /// A verb with no criteria to wait for refuses the arguments rather than
    /// silently ignoring them — the CLI's parser has no such option on those verbs
    /// at all, and an argument that quietly does nothing is the silent-wrong-answer
    /// class this project refuses.
    @Test func waitOnAVerbWithNoCriteriaIsRefused() {
        for verb in ["click", "type", "key", "menu", "drag"] {
            let result = call(["verb": .string(verb), "wait": .string("3s")])
            #expect(result.isError)
            #expect(message(result).contains("apply only to the verbs that target by criteria"))
            #expect(message(result).contains("act \(verb) has no criteria to wait for"))
        }
    }

    /// An unknown verb still gets the unknown-verb message: the wait refusal must
    /// not shadow the more fundamental error.
    @Test func anUnknownVerbIsStillReportedAsUnknown() {
        let result = call(["verb": .string("wiggle"), "wait": .string("3s")])
        #expect(result.isError)
        #expect(message(result).contains("unknown verb 'wiggle'"))
    }
}
