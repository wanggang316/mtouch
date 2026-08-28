import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures (zero AX/TCC dependency; fabricated pids never reach the kernel)

private struct StubPermissions: PermissionProvider {
    let accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

private func button(_ title: String) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: CGRect(x: 0, y: 0, width: 100, height: 20), actionable: true)
}

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

/// One actionable ref (e1: the "First" button) — the session every act/read
/// dead-target case resolves against.
private func sampleSnapshot() -> Snapshot {
    Snapshot(roots: [window([button("First")])])
}

private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-liveness-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func writeSession(
    _ snapshot: Snapshot, app: String = "com.example.App", pid: Int32 = 4242, to dir: URL
) throws -> String {
    let path = dir.appendingPathComponent("session.json").path
    try SessionStore.save(snapshot, app: app, pid: pid, to: path)
    return path
}

/// A live tree in which e1 ("First") RESOLVES: attributes mirror the session tree
/// and the element handle is present.
private func resolvingTree() -> LiveElementTree {
    LiveElementTree(
        nodes: [window([button("First")])],
        elementsByPath: [[0, 0]: AXUIElementCreateApplication(4242)],
        attributesByPath: [
            [0]: AXAttributes(role: kAXWindowRole, title: "W"),
            [0, 0]: AXAttributes(role: kAXButtonRole, title: "First", actionNames: [kAXPressAction]),
        ]
    )
}

/// A live tree in which e1 MISSES: the same position now holds a different
/// element — exactly what a walk of a dead (or changed) process yields.
private func missTree() -> LiveElementTree {
    LiveElementTree(
        nodes: [window([button("Gone")])],
        elementsByPath: [[0, 0]: AXUIElementCreateApplication(4242)],
        attributesByPath: [
            [0]: AXAttributes(role: kAXWindowRole, title: "W"),
            [0, 0]: AXAttributes(role: kAXButtonRole, title: "Gone", actionNames: [kAXPressAction]),
        ]
    )
}

/// An `isRunning` stub that answers ALIVE for the up-front gate, then DEAD for
/// every later (failure-time) consult — the process that exits mid-command.
private final class DiesAfterGate {
    private var calls = 0
    func isRunning(_ pid: pid_t, _ bundleId: String) -> Bool {
        calls += 1
        return calls == 1
    }
}

/// Deterministic virtual clock: time advances only when the code under test
/// sleeps, so "failed fast" is provable rather than merely observed.
private final class Clock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
}

private func walkResult(_ roots: [AXNode]) -> WalkResult {
    WalkResult(nodes: roots, fallbackFired: false, fallbackHelped: false, truncated: false)
}

private func failure(_ outcome: ActOutcome) -> (stderr: String, code: MTouchExitCode)? {
    guard case let .failed(stderr, code) = outcome else { return nil }
    return (stderr, code)
}

private func failure(_ outcome: ReadOutcome) -> (stderr: String, code: MTouchExitCode)? {
    guard case let .failed(stderr, code) = outcome else { return nil }
    return (stderr, code)
}

// MARK: - The probe itself (kill(pid, 0) semantics)

@Suite struct ProcessLivenessTests {
    @Test func theCurrentProcessIsAlive() {
        #expect(ProcessLiveness.isAlive(getpid()))
    }

    /// EPERM counts as ALIVE: pid 1 is launchd, which always exists and (for a
    /// non-root test run) refuses the signal check with EPERM rather than ESRCH.
    /// Treating that refusal as death would misdiagnose every root-owned target.
    @Test func aProcessOwnedByAnotherUserCountsAsAlive() {
        #expect(ProcessLiveness.isAlive(1))
    }

    @Test func anExitedProcessIsGone() throws {
        // Spawn a short-lived child and wait for it; once reaped, its pid names
        // no process and the probe must say so.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(ProcessLiveness.isAlive(child.processIdentifier) == false)
    }

    /// A ZOMBIE — exited but not yet reaped — answers `kill(pid, 0)` with 0, yet
    /// it can never answer an accessibility read again, so the probe must count
    /// it as gone. Measured live, a SIGKILLed app spends tens of milliseconds in
    /// this state — exactly when a mid-command failure path consults the probe.
    @Test func anUnreapedZombieCountsAsGone() throws {
        // posix_spawn (not Foundation.Process, which reaps automatically) so the
        // exited child STAYS a zombie until this test reaps it below.
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        let spawned = posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, nil)
        try #require(spawned == 0)

        // Wait (bounded) for the child to exit into the zombie state.
        var sawZombie = false
        for _ in 0..<200 where !sawZombie {
            sawZombie = ProcessLiveness.isZombie(pid)
            if !sawZombie { usleep(10_000) }
        }
        try #require(sawZombie)

        #expect(ProcessLiveness.isAlive(pid) == false)

        // Reap it so the test leaves no zombie behind; the pid then names no
        // process at all and the verdict must not change.
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(ProcessLiveness.isAlive(pid) == false)
    }

    /// `kill` with a non-positive pid addresses a process GROUP — a different
    /// question — so those are refused as "not alive" instead of probed.
    @Test func nonPositivePidsAreNeverProbed() {
        #expect(ProcessLiveness.isAlive(0) == false)
        #expect(ProcessLiveness.isAlive(-1) == false)
    }
}

// MARK: - The pinned app-gone diagnosis

@Suite struct AppGoneDiagnosisTests {
    @Test func theMessageNamesPidBundleAndTheOnlyWorkingRecovery() {
        let message = AppGone.diagnostic(app: "com.example.App", pid: 4242)
        #expect(message.contains("com.example.App"))
        #expect(message.contains("(pid 4242)"))
        #expect(message.contains("is no longer running"))
        #expect(message.contains("mtouch app launch --app com.example.App"))
        #expect(message.contains("mtouch snapshot"))
    }

    /// The trajectory classifier keys off the wording, so it must match the
    /// app-gone diagnosis and NOTHING else — in particular not the
    /// resolution-time "is not running" refusal, which is a pre-launch fact.
    @Test func describesMatchesOnlyTheAppGoneWording() {
        #expect(AppGone.describes(AppGone.diagnostic(app: "com.example.App", pid: 4242)))
        #expect(AppGone.describes(AppNotRunningError(bundleId: "com.example.App").message) == false)
        #expect(AppGone.describes(ActPipeline.goneRefDiagnostic("e1")) == false)
        #expect(AppGone.describes(ActPipeline.timeoutDiagnostic(app: "com.example.App", pid: 4242)) == false)
        #expect(AppGone.describes("") == false)
    }

    /// One wording for the whole act surface: the up-front gate and the
    /// failure-time consults must be indistinguishable to an agent.
    @Test func theActGateSharesTheSameWording() {
        #expect(
            ActPipeline.notRunningDiagnostic(app: "com.example.App", pid: 4242)
                == AppGone.diagnostic(app: "com.example.App", pid: 4242)
        )
    }
}

// MARK: - act: death at failure time is app-gone (exit 1), never stale (exit 3)

@Suite struct ActDeadTargetDistinctionTests {
    private func run(
        isRunning: @escaping (pid_t, String) -> Bool,
        walkLive: @escaping (pid_t) -> LiveElementTree?,
        performAction: @escaping (AXUIElement, ActVerb, String?) -> Result<Void, AXActionFailure>
            = { _, _, _ in .success(()) }
    ) throws -> ActOutcome {
        var outcome: ActOutcome?
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            outcome = ActPipeline.run(
                ref: "e1", verb: .press, value: nil, json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: isRunning,
                walkLive: walkLive,
                rewalk: { _ in nil },
                performAction: performAction,
                persist: { _, _, _, _ in Issue.record("must not persist after a failure") },
                sleep: { _ in }
            )
        }
        return try #require(outcome)
    }

    @Test func aWalkFailureOnADeadTargetIsAppGoneNotUnresponsive() throws {
        let liveness = DiesAfterGate()
        let outcome = try run(isRunning: liveness.isRunning, walkLive: { _ in nil })
        let failed = try #require(failure(outcome))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
        #expect(failed.stderr.contains("unresponsive") == false)
    }

    @Test func aRelocationMissOnADeadTargetIsAppGoneExitOneNotStaleExitThree() throws {
        // The stale-ref advice ("re-run 'mtouch snapshot'") cannot help when the
        // app itself died: a fresh snapshot of a dead process is impossible.
        let liveness = DiesAfterGate()
        let outcome = try run(isRunning: liveness.isRunning, walkLive: { _ in missTree() })
        let failed = try #require(failure(outcome))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
    }

    /// The regression pin: a LIVE target keeps the stale-ref diagnostic byte for
    /// byte at exit 3 — the liveness distinction must not disturb it.
    @Test func aRelocationMissOnALiveTargetKeepsStaleExitThreeByteForByte() throws {
        let outcome = try run(isRunning: { _, _ in true }, walkLive: { _ in missTree() })
        let failed = try #require(failure(outcome))
        #expect(failed.code == .refError)
        #expect(failed.stderr == ActPipeline.goneRefDiagnostic("e1"))
    }

    /// Measured live: a target killed mid-command surfaces as an AX action
    /// refusal ("may be disabled") — misdirecting the agent toward the element.
    /// A dead pid behind that refusal is diagnosed as app-gone instead.
    @Test func anActionRefusalOnADeadTargetIsAppGone() throws {
        var calls = 0
        let outcome = try run(
            isRunning: { _, _ in calls += 1; return calls <= 1 },
            walkLive: { _ in resolvingTree() },
            performAction: { _, _, _ in .failure(AXActionFailure("cannot press the referenced element (AX error -25204). It may be disabled or may not support this action.")) }
        )
        let failed = try #require(failure(outcome))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
        #expect(failed.stderr.contains("disabled") == false)
    }

    @Test func anActionRefusalOnALiveTargetKeepsItsDiagnosticByteForByte() throws {
        let outcome = try run(
            isRunning: { _, _ in true },
            walkLive: { _ in resolvingTree() },
            performAction: { _, _, _ in .failure(AXActionFailure("button 'First' cannot be pressed.")) }
        )
        let failed = try #require(failure(outcome))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == "mtouch: button 'First' cannot be pressed.")
    }
}

// MARK: - read (ref path): identical distinction, byte for byte with act

@Suite struct ReadDeadTargetDistinctionTests {
    private func run(
        isRunning: @escaping (pid_t, String) -> Bool,
        walkLive: @escaping (pid_t) -> LiveElementTree?
    ) throws -> ReadOutcome {
        var outcome: ReadOutcome?
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            outcome = ReadPipeline.run(
                ref: "e1", json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: isRunning,
                walkLive: walkLive
            )
        }
        return try #require(outcome)
    }

    @Test func aWalkFailureOnADeadTargetIsAppGone() throws {
        let liveness = DiesAfterGate()
        let outcome = try run(isRunning: liveness.isRunning, walkLive: { _ in nil })
        let failed = try #require(failure(outcome))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
    }

    @Test func aRelocationMissOnADeadTargetIsAppGoneExitOne() throws {
        let liveness = DiesAfterGate()
        let outcome = try run(isRunning: liveness.isRunning, walkLive: { _ in missTree() })
        let failed = try #require(failure(outcome))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
    }

    @Test func aRelocationMissOnALiveTargetKeepsStaleExitThreeByteForByte() throws {
        let outcome = try run(isRunning: { _, _ in true }, walkLive: { _ in missTree() })
        let failed = try #require(failure(outcome))
        #expect(failed.code == .refError)
        #expect(failed.stderr == ActPipeline.goneRefDiagnostic("e1"))
    }
}

// MARK: - read (app path): AX failures behind a dead pid say so

@Suite struct ReadAppDeadTargetTests {
    private func run(
        walk: @escaping (pid_t) -> WalkResult?,
        diagnoseEmptyTree: @escaping (pid_t) -> AXReadFailure? = { _ in nil },
        isAlive: @escaping (pid_t) -> Bool
    ) -> ReadOutcome {
        ReadPipeline.runApp(
            bundleId: "com.example.App", criteria: nil, json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            walk: walk,
            diagnoseEmptyTree: diagnoseEmptyTree,
            isAlive: isAlive
        )
    }

    @Test func aWalkFailureOnADeadTargetIsAppGone() throws {
        let outcome = run(walk: { _ in nil }, isAlive: { _ in false })
        let failed = try #require(failure(outcome))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
    }

    @Test func anEmptyTreeRefusalOnADeadTargetIsAppGone() throws {
        let outcome = run(
            walk: { _ in walkResult([]) },
            diagnoseEmptyTree: { pid in AXReadFailure(pid: pid, error: .cannotComplete) },
            isAlive: { _ in false }
        )
        let failed = try #require(failure(outcome))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
        #expect(failed.stderr.contains("--pid") == false)   // no wrong recovery advice
    }

    @Test func livenessIsNeverConsultedOnAHappyPath() throws {
        let tree = [window([button("First")])]
        let outcome = run(
            walk: { _ in walkResult(tree) },
            isAlive: { _ in Issue.record("liveness must not be probed on success"); return true }
        )
        guard case .read = outcome else {
            Issue.record("expected a successful read, got \(outcome)"); return
        }
    }
}

// MARK: - snapshot: AX failures behind a dead pid say so

@Suite struct SnapshotDeadTargetTests {
    private func run(
        walk: @escaping (pid_t) -> WalkResult?,
        diagnoseEmptyTree: @escaping (pid_t) -> AXReadFailure? = { _ in nil },
        isAlive: @escaping (pid_t) -> Bool
    ) -> SnapshotOutcome {
        SnapshotPipeline.run(
            bundleId: "com.example.App", json: false, environment: [:],
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            walk: walk,
            diagnoseEmptyTree: diagnoseEmptyTree,
            persist: { _, _, _, _ in },
            isAlive: isAlive
        )
    }

    @Test func aWalkFailureOnADeadTargetIsAppGoneNotUnresponsive() throws {
        let outcome = run(walk: { _ in nil }, isAlive: { _ in false })
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
        #expect(stderr.contains("unresponsive") == false)
    }

    /// Measured live: a snapshot racing a mid-command death reports
    /// `cannotComplete` with "may be hung, busy, or stopped … retry with --pid" —
    /// advice that cannot work on a dead process. The dead pid must be named.
    @Test func anEmptyTreeRefusalOnADeadTargetIsAppGone() throws {
        let outcome = run(
            walk: { _ in walkResult([]) },
            diagnoseEmptyTree: { pid in AXReadFailure(pid: pid, error: .cannotComplete) },
            isAlive: { _ in false }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
        #expect(stderr.contains("hung") == false)
        #expect(stderr.contains("--pid") == false)
    }

    /// The regression pin: the SAME refusal from a target that is still alive
    /// keeps the AX diagnostic byte for byte.
    @Test func anEmptyTreeRefusalOnALiveTargetKeepsTheAXWording() throws {
        let refusal = AXReadFailure(pid: 4242, error: .cannotComplete)
        let outcome = run(
            walk: { _ in walkResult([]) },
            diagnoseEmptyTree: { _ in refusal },
            isAlive: { _ in true }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == refusal.diagnostic(reading: "the accessibility tree", of: "com.example.App"))
    }
}

// MARK: - windows: an enumeration refusal behind a dead pid says so

@Suite struct WindowsDeadTargetTests {
    @Test func aRefusedListingOnADeadTargetIsAppGone() {
        let outcome = WindowsPipeline.run(
            bundleId: "com.example.App", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            enumerate: { pid in .failure(AXReadFailure(pid: pid, error: .invalidUIElement)) },
            isAlive: { _ in false }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
    }

    @Test func aRefusedListingOnALiveTargetKeepsTheAXWordingByteForByte() {
        let refusal = AXReadFailure(pid: 4242, error: .apiDisabled)
        let outcome = WindowsPipeline.run(
            bundleId: "com.example.App", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            enumerate: { _ in .failure(refusal) },
            isAlive: { _ in true }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == refusal.diagnostic(reading: "windows", of: "com.example.App"))
    }

    @Test func livenessIsNeverConsultedOnASuccessfulListing() {
        let outcome = WindowsPipeline.run(
            bundleId: "com.example.App", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            enumerate: { _ in .success([]) },
            isAlive: { _ in Issue.record("liveness must not be probed on success"); return true }
        )
        #expect(outcome == .listed("no windows for com.example.App"))
    }
}

// MARK: - wait: a target that dies mid-poll fails FAST at exit 1 (VAL-WAIT-009)

@Suite struct WaitDeadTargetTests {
    /// The live tree the target shows while alive: present, but never matching
    /// the awaited criteria — an ordinary unmet poll.
    private let aliveTree = [window([button("Other")])]

    private func runWait(
        condition: WaitCondition,
        timeout: TimeInterval,
        probe: @escaping () -> [AXNode]?,
        isAlive: @escaping (pid_t) -> Bool
    ) -> (outcome: WaitOutcome, elapsed: TimeInterval) {
        let clock = Clock()
        let outcome = WaitPipeline.run(
            bundleId: "com.example.App",
            condition: condition,
            timeout: timeout, interval: 0.1,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            now: clock.now, sleep: clock.sleep,
            makeProbe: { _, _ in probe },
            isAlive: isAlive
        )
        return (outcome, clock.time)
    }

    @Test func aTargetThatDiesMidPollFailsFastNotAtTimeout() throws {
        // Alive (non-matching tree) for three polls, then dead: every later walk
        // is empty. The wait must end at death detection — a fraction of the 60s
        // budget — with the app-gone diagnosis at exit 1, not exit 4.
        var polls = 0
        var livenessConsults = 0
        let (outcome, elapsed) = runWait(
            condition: .appears(WaitCriteria(parsing: "button \"nope\"")),
            timeout: 60,
            probe: { polls += 1; return polls <= 3 ? self.aliveTree : [] },
            isAlive: { _ in livenessConsults += 1; return false }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
        #expect(elapsed < 1)             // death at ~0.3s of a 60s budget
        #expect(livenessConsults == 1)   // only the first EMPTY poll consulted it
    }

    @Test func aHungWalkOnADeadTargetFailsFastToo() throws {
        // nil (a hung/failed walk) rather than empty: the other way a dead
        // process reads as nothing.
        let (outcome, elapsed) = runWait(
            condition: .appears(WaitCriteria(parsing: "window")),
            timeout: 60,
            probe: { nil },
            isAlive: { _ in false }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
        #expect(elapsed < 1)
    }

    /// The behavior `wait` exists for: an ALIVE target that merely shows nothing
    /// yet keeps being polled to the full budget (exit 4), exactly as today.
    @Test func anAliveTargetWithAnEmptyTreeKeepsPollingToTimeout() throws {
        var livenessConsults = 0
        let (outcome, elapsed) = runWait(
            condition: .appears(WaitCriteria(parsing: "button \"nope\"")),
            timeout: 2,
            probe: { [] },
            isAlive: { _ in livenessConsults += 1; return true }
        )
        guard case let .failed(_, code) = outcome else {
            Issue.record("expected a timeout failure, got \(outcome)"); return
        }
        #expect(code == .waitTimeout)
        #expect(elapsed >= 2)           // it honestly waited the full budget
        #expect(livenessConsults > 1)   // consulted on failed polls, never fatal while alive
    }

    /// No polling-cost regression: a poll that walks a NON-EMPTY tree — matching
    /// or not — never consults the probe. Liveness runs only on failed reads.
    @Test func livenessIsNeverConsultedWhileWalksObserveAnything() throws {
        let matching = [window([button("Yes")])]
        let (satisfied, _) = runWait(
            condition: .appears(WaitCriteria(parsing: "button \"Yes\"")),
            timeout: 5,
            probe: { matching },
            isAlive: { _ in Issue.record("liveness must not be probed on a non-empty walk"); return true }
        )
        #expect(satisfied == .satisfied)

        let (timedOut, _) = runWait(
            condition: .appears(WaitCriteria(parsing: "button \"nope\"")),
            timeout: 1,
            probe: { self.aliveTree },
            isAlive: { _ in Issue.record("liveness must not be probed on a non-empty walk"); return true }
        )
        guard case let .failed(_, code) = timedOut else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(code == .waitTimeout)
    }

    /// A `--stable` wait dies mid-poll the same way: the quiescence loop's empty
    /// walks consult liveness and fail fast rather than reading a dead app's
    /// unchanging emptiness as stability.
    @Test func aStableWaitOnATargetThatDiesFailsFast() throws {
        var polls = 0
        let (outcome, elapsed) = runWait(
            condition: .stable(of: nil, window: 0.5),
            timeout: 60,
            probe: {
                polls += 1
                // Still changing while alive, then dead (empty) from poll 4 on.
                return polls <= 3 ? [window([button("tick \(polls)")])] : []
            },
            isAlive: { _ in false }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == AppGone.diagnostic(app: "com.example.App", pid: 4242))
        #expect(elapsed < 1)
    }

    /// A condition an empty tree satisfies on its own terms — `--disappears` —
    /// is met BEFORE liveness is ever consulted: the element did disappear, and
    /// that verdict does not depend on why.
    @Test func aDisappearsConditionIsMetOnItsOwnTermsBeforeAnyLivenessCheck() throws {
        var polls = 0
        let (outcome, _) = runWait(
            condition: .disappears(WaitCriteria(parsing: "button \"Other\"")),
            timeout: 5,
            probe: { polls += 1; return polls == 1 ? self.aliveTree : [] },
            isAlive: { _ in Issue.record("a met condition must not consult liveness"); return false }
        )
        #expect(outcome == .satisfied)
    }
}

// MARK: - trajectory: app-gone records are machine-distinguishable

@Suite struct TrajectoryAppGoneClassTests {
    private let appGone = AppGone.diagnostic(app: "com.example.App", pid: 4242)

    @Test func appGoneFailuresCarryTheirOwnClassOnEverySurface() {
        #expect(ActOutcome.failed(stderr: appGone, code: .runtimeFailure)
            .trajectoryInfo.errorClass == AppGone.errorClass)
        #expect(ReadOutcome.failed(stderr: appGone, code: .runtimeFailure)
            .trajectoryInfo.errorClass == AppGone.errorClass)
        #expect(WaitOutcome.failed(stderr: appGone, code: .runtimeFailure)
            .trajectoryInfo.errorClass == AppGone.errorClass)
        #expect(SnapshotOutcome.failed(stderr: appGone, code: .runtimeFailure)
            .trajectoryInfo.errorClass == AppGone.errorClass)
    }

    /// The boundary pins: every other failure keeps its exit-code-derived class —
    /// including the resolution-time "is not running" refusal, which is a
    /// pre-launch fact rather than a mid-command death.
    @Test func otherFailuresKeepTheirExitCodeClasses() {
        #expect(ActOutcome.failed(stderr: "mtouch: something else broke", code: .runtimeFailure)
            .trajectoryInfo.errorClass == "runtime")
        #expect(WaitOutcome.failed(
            stderr: AppNotRunningError(bundleId: "com.example.App").message, code: .runtimeFailure
        ).trajectoryInfo.errorClass == "runtime")
        #expect(ActOutcome.failed(stderr: ActPipeline.goneRefDiagnostic("e1"), code: .refError)
            .trajectoryInfo.errorClass == "ref")
        #expect(WaitOutcome.failed(stderr: "mtouch: wait timed out …", code: .waitTimeout)
            .trajectoryInfo.errorClass == "wait-timeout")
    }
}
