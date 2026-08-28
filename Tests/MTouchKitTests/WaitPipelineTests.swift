import ApplicationServices
import Foundation
import Testing
@testable import MTouchKit

private struct StubPermissions: PermissionProvider {
    var accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

/// Deterministic virtual clock shared by `now`/`sleep`, letting a test observe
/// whether the poll loop ran at all (fast-fail paths must leave it at 0).
private final class Clock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
}

private func window(title: String, _ children: [AXNode] = []) -> AXNode {
    AXNode(role: kAXWindowRole, title: title, children: children)
}

@Suite struct WaitPipelineTests {
    private let textArea = AXNode(role: "AXTextArea", value: "hi", actionable: true)

    @Test func missingGrantFailsFastWithExitTwoBeforePolling() {
        let clock = Clock()
        let outcome = WaitPipeline.run(
            bundleId: "com.apple.TextEdit",
            condition: .appears(WaitCriteria(parsing: "textarea")),
            timeout: 5, interval: 0.1,
            permissions: StubPermissions(accessibility: false),
            resolvePID: { _ in Issue.record("resolvePID must not run without the grant"); return 1 },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in { Issue.record("must not poll without the grant"); return nil } }
        )

        guard case let .failed(_, code) = outcome else {
            Issue.record("expected failure"); return
        }
        #expect(code == .permissionMissing)
        #expect(clock.time == 0) // never entered the loop
    }

    @Test func appNotRunningFailsFastWithExitOneNeverBurningTheTimeout() {
        let clock = Clock()
        let outcome = WaitPipeline.run(
            bundleId: "com.example.nope",
            condition: .appears(WaitCriteria(parsing: "window")),
            timeout: 5, interval: 0.1,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in throw AppNotRunningError(bundleId: "com.example.nope") },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in { Issue.record("must not poll a non-running app"); return nil } }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("is not running"))
        #expect(clock.time == 0) // the 5s timeout was never burned
    }

    @Test func conditionMetReturnsSatisfied() {
        let clock = Clock()
        let outcome = WaitPipeline.run(
            bundleId: "com.apple.TextEdit",
            condition: .appears(WaitCriteria(parsing: "textarea")),
            timeout: 5, interval: 0.1,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 42 },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in { [window(title: "Untitled", [self.textArea])] } }
        )

        #expect(outcome == .satisfied)
    }

    @Test func timeoutReturnsExitFourWithDiagnosableStderr() {
        let clock = Clock()
        // The probe always yields a document WITHOUT the awaited button, so the
        // wait times out and the diagnostic must echo the criteria + last-seen.
        let outcome = WaitPipeline.run(
            bundleId: "com.apple.TextEdit",
            condition: .appears(WaitCriteria(parsing: "button \"NoSuchThing\"")),
            timeout: 2, interval: 0.1,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 42 },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in { [window(title: "Untitled", [self.textArea])] } }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(code == .waitTimeout)
        #expect(stderr.contains("timed out"))
        #expect(stderr.contains("2s"))                 // the timeout used
        #expect(stderr.contains("AXButton \"NoSuchThing\"")) // the criteria echoed
        #expect(stderr.contains("Last seen"))          // the last-seen summary
        #expect(stderr.contains("Untitled"))           // a window title actually observed
        #expect(clock.time >= 2)                        // it honestly waited the full timeout
    }

    @Test func hungWalkYieldsTimeoutNotACrash() {
        // A probe that always fails (nil, as GuardedWalk returns on a hung target)
        // counts as "not met" and the wait times out cleanly (exit 4).
        //
        // This models the RESULT of a hung walk (nil) with a synchronous probe, so
        // it spawns no background walk and cannot leak a blocked thread. The tests
        // that DO spawn a real blocking walk — GuardedWalkTests' hung-target case and
        // BoundedWalkTests' over-deadline case — release and drain that thread before
        // returning, so none survives into the (SIGBUS-prone on Xcode 16.x) teardown.
        let clock = Clock()
        let outcome = WaitPipeline.run(
            bundleId: "com.apple.TextEdit",
            condition: .appears(WaitCriteria(parsing: "window")),
            timeout: 1, interval: 0.1,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 42 },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in { nil } },
            isAlive: { _ in true }   // hung but ALIVE: keeps polling to timeout
        )

        guard case let .failed(_, code) = outcome else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(code == .waitTimeout)
    }

    @Test func perWalkDeadlineIsCappedToTheWaitBudget() throws {
        // GuardedWalk.sample() BLOCKS the first poll up to its deadline, so the
        // deadline handed to makeProbe must be min(8, max(timeout, 1)): the 8s
        // ceiling for long waits, floored at 1s so a healthy walk is never
        // starved by a sub-second timeout. Capture that deadline deterministically
        // — no real GuardedWalk thread, no real clock — and assert the cap math.
        final class DeadlineBox { var value: TimeInterval? }

        let cases: [(timeout: TimeInterval, expected: TimeInterval)] = [
            (0, 1), (0.5, 1), (1, 1), (3, 3), (8, 8), (20, 8),
        ]

        for (timeout, expected) in cases {
            let clock = Clock()
            let box = DeadlineBox()
            let outcome = WaitPipeline.run(
                bundleId: "com.apple.TextEdit",
                condition: .appears(WaitCriteria(parsing: "window")),
                timeout: timeout, interval: 0.1,
                permissions: StubPermissions(accessibility: true),
                resolvePID: { _ in 42 },
                now: clock.now, sleep: clock.sleep,
                makeProbe: { _, deadline in
                    box.value = deadline
                    // A satisfying tree so run() exits on the first poll.
                    return { [window(title: "Untitled")] }
                }
            )

            #expect(outcome == .satisfied)
            let captured = try #require(box.value)
            #expect(captured == expected, "timeout \(timeout) should cap the walk deadline to \(expected)")
        }
    }
}

@Suite struct WaitDiagnosticTests {
    @Test func formatDurationRendersFriendlyUnits() {
        #expect(WaitPipeline.formatDuration(2) == "2s")
        #expect(WaitPipeline.formatDuration(0.5) == "500ms")
        #expect(WaitPipeline.formatDuration(0.1) == "100ms")
        #expect(WaitPipeline.formatDuration(1.5) == "1.5s")
    }

    @Test func lastSeenSummaryReportsCountsRolesAndTitles() {
        let roots = [
            AXNode(role: kAXWindowRole, title: "Untitled", children: [
                AXNode(role: "AXTextArea", value: "hi"),
                AXNode(role: kAXButtonRole, title: "Close"),
            ]),
        ]
        let summary = WaitPipeline.lastSeenSummary(roots)
        #expect(summary.contains("element(s)"))
        #expect(summary.contains("AXWindow"))
        #expect(summary.contains("Untitled"))
    }

    @Test func lastSeenSummaryHandlesNothingWalked() {
        #expect(WaitPipeline.lastSeenSummary(nil).contains("nothing"))
        #expect(WaitPipeline.lastSeenSummary([]).contains("nothing"))
    }
}
