import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

private struct StubPermissions: PermissionProvider {
    var accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

/// Deterministic virtual clock shared by `now`/`sleep`, so a test can assert BOTH
/// that a wait happened and that it stayed inside its budget — with no wall time.
private final class Clock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
}

/// A scriptable stand-in for the system: nothing is launched, activated, or
/// killed. State changes are driven by the number of POLLS, so "the app appears
/// after a while" is expressed without any real delay.
private final class FakeWorkspace: WorkspaceControl {
    /// Bundle ids that resolve to an installed application.
    var installed: Set<String> = []
    /// pid -> bundle id for every live process.
    var running: [pid_t: String] = [:]
    var frontmost: pid_t?
    /// Window count an AX read reports; nil ⇒ the read is REFUSED (not "zero").
    var windowCount: Int? = 1
    /// Reason the system reports for a refused launch, if any.
    var launchFailure: String?
    /// Whether a graceful terminate request is accepted.
    var terminateAccepted = true
    /// Whether the process survives even a forced termination.
    var unkillable = false

    /// The pid a successful launch produces.
    var launchedPID: pid_t = 900
    /// Polls before the launched process becomes visible; `Int.max` ⇒ never.
    var launchDelay = 0
    /// Polls before the window count becomes visible.
    var windowDelay = 0
    /// Polls before the target becomes frontmost; `Int.max` ⇒ never.
    var frontmostDelay = 0
    /// Polls before a gracefully-quit process disappears; `Int.max` ⇒ never.
    var quitDelay = 0

    private(set) var launchRequests = 0
    private(set) var activations: [pid_t] = []
    private(set) var terminations: [(pid: pid_t, force: Bool)] = []
    /// Every query the pipeline made, to assert a fast-fail path touched nothing.
    private(set) var queries = 0

    private var runningQueries = 0
    private var windowQueries = 0
    private var frontmostQueries = 0
    private var livenessQueries = 0
    private var quitRequested: pid_t?
    private var forceKilled = false

    func applicationURL(bundleId: String) -> URL? {
        queries += 1
        guard installed.contains(bundleId) else { return nil }
        return URL(fileURLWithPath: "/Applications/\(bundleId).app")
    }

    func runningPIDs(bundleId: String) -> [pid_t] {
        queries += 1
        runningQueries += 1
        var pids = running.filter { $0.value == bundleId }.map(\.key)
        if launchRequests > 0, launchDelay != Int.max, runningQueries > launchDelay,
           installed.contains(bundleId), !pids.contains(launchedPID) {
            running[launchedPID] = bundleId
            pids.append(launchedPID)
        }
        return pids.sorted()
    }

    func bundleId(ofPID pid: pid_t) -> String? {
        queries += 1
        return running[pid]
    }

    func requestLaunch(at url: URL) -> () -> String? {
        queries += 1
        launchRequests += 1
        return { [weak self] in self?.launchFailure }
    }

    func activate(pid: pid_t) {
        queries += 1
        activations.append(pid)
    }

    func frontmostPID() -> pid_t? {
        queries += 1
        frontmostQueries += 1
        guard frontmostDelay != Int.max, frontmostQueries > frontmostDelay else { return frontmost }
        return activations.last ?? frontmost
    }

    func axWindowCount(pid: pid_t) -> Int? {
        queries += 1
        windowQueries += 1
        guard let windowCount else { return nil }
        return windowQueries > windowDelay ? windowCount : 0
    }

    func isRunning(pid: pid_t) -> Bool {
        queries += 1
        guard running[pid] != nil else { return false }
        guard quitRequested == pid else { return true }
        if forceKilled { return unkillable }
        livenessQueries += 1
        guard quitDelay != Int.max, livenessQueries > quitDelay else { return true }
        running[pid] = nil
        return false
    }

    func terminate(pid: pid_t, force: Bool) -> Bool {
        queries += 1
        terminations.append((pid: pid, force: force))
        if force {
            forceKilled = true
            if !unkillable { running[pid] = nil }
            return true
        }
        guard terminateAccepted else { return false }
        quitRequested = pid
        return true
    }
}

private let bundleId = "com.example.App"

private func failure(_ outcome: AppOutcome) -> (stderr: String, code: MTouchExitCode)? {
    guard case let .failed(stderr, code) = outcome else { return nil }
    return (stderr, code)
}

private func reported(_ outcome: AppOutcome) -> String? {
    guard case let .reported(output) = outcome else { return nil }
    return output
}

// MARK: - launch

@Suite struct AppLaunchTests {
    @Test func uninstalledApplicationIsExitOneNamingTheBundleId() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: nil, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains(bundleId) == true)
        #expect(result?.stderr.contains("installed") == true)
        #expect(workspace.launchRequests == 0)
    }

    @Test func alreadyRunningApplicationIsAdoptedNeverRelaunched() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.running = [4242: bundleId]

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: nil, json: true,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "{\"pid\":4242,\"bundleId\":\"com.example.App\",\"launched\":false}")
        #expect(workspace.launchRequests == 0)          // no second instance
        #expect(workspace.activations == [4242])        // but it IS brought forward
    }

    @Test func severalRunningInstancesAreRefusedRatherThanGuessed() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.running = [11: bundleId, 22: bundleId]

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: nil, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("11") == true)  // both candidates named
        #expect(result?.stderr.contains("22") == true)
        // The recovery must be one this verb supports: launch takes no --pid.
        #expect(result?.stderr.contains("app activate") == true)
        #expect(workspace.launchRequests == 0)
    }

    @Test func launchPollsUntilTheProcessAppearsAndReportsItsPid() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.launchDelay = 3

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: nil, json: true,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "{\"pid\":900,\"bundleId\":\"com.example.App\",\"launched\":true}")
        #expect(workspace.launchRequests == 1)
        #expect(clock.time > 0)                          // it really polled
        #expect(clock.time < AppLifecycle.launchBudget)  // and finished early
    }

    @Test func textOutputIsTheBarePid() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.running = [4242: bundleId]

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: nil, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "4242")
    }

    @Test func reportedLaunchFailureEndsTheWaitImmediately() {
        // A launch the system refuses must not be reported as a timeout: the real
        // reason is available at once, and burning the budget would hide it.
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.launchDelay = Int.max
        workspace.launchFailure = "The application is damaged."

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: nil, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("The application is damaged.") == true)
        #expect(clock.time == 0)                         // never waited
    }

    @Test func processThatNeverAppearsIsAWaitTimeout() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.launchDelay = Int.max

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: nil, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        let result = failure(outcome)
        #expect(result?.code == .waitTimeout)
        #expect(result?.stderr.contains("no process appeared") == true)
        // The BUDGET, not a raw elapsed reading: "10s" is actionable, "9.9968s" is noise.
        #expect(result?.stderr.contains("within 10s") == true)
        #expect(clock.time >= AppLifecycle.launchBudget) // honestly waited the budget
    }

    @Test func waitReadyPollsUntilTheApplicationReportsAWindow() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.windowDelay = 5                        // windows appear later

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: 15, json: true,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "{\"pid\":900,\"bundleId\":\"com.example.App\",\"launched\":true}")
        #expect(clock.time > 0)
        #expect(clock.time < 15)
    }

    @Test func waitReadyExpiryIsExitFourNamingTheApplication() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.windowCount = 0                        // starts, never shows a window

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: 5, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        let result = failure(outcome)
        #expect(result?.code == .waitTimeout)
        #expect(result?.stderr.contains(bundleId) == true)
        #expect(result?.stderr.contains("did not report a window") == true)
        #expect(clock.time >= 5)
    }

    @Test func aRefusedAccessibilityReadIsNotMistakenForReadiness() {
        // nil (the read was refused) must never be read as "a window is there".
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.windowCount = nil

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: 2, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            now: clock.now, sleep: clock.sleep
        )

        #expect(failure(outcome)?.code == .waitTimeout)
    }

    @Test func waitReadyWithoutAccessibilityIsExitTwoBeforeTouchingAnything() {
        // Readiness is an AX read, so a missing grant must fail as a PERMISSION
        // problem (exit 2) rather than as the timeout it would otherwise become.
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: 5, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: false),
            now: clock.now, sleep: clock.sleep
        )

        #expect(failure(outcome)?.code == .permissionMissing)
        #expect(workspace.queries == 0)                  // nothing was launched or read
        #expect(clock.time == 0)
    }

    @Test func launchWithoutWaitReadyNeedsNoAccessibilityGrant() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.installed = [bundleId]
        workspace.running = [4242: bundleId]

        let outcome = AppLifecycle.launch(
            bundleId: bundleId, waitReady: nil, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: false),
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "4242")
    }
}

// MARK: - activate

@Suite struct AppActivateTests {
    @Test func activateSucceedsOnceTheTargetActuallyHoldsTheForeground() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId]
        workspace.frontmost = 7                          // someone else, at first
        workspace.frontmostDelay = 4

        let outcome = AppLifecycle.activate(
            bundleId: bundleId, json: true,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "{\"pid\":4242,\"bundleId\":\"com.example.App\",\"frontmost\":true}")
        #expect(workspace.activations == [4242])
        #expect(clock.time > 0)                          // it verified rather than assumed
    }

    @Test func anActivationThatNeverTakesTheForegroundIsExitOne() {
        // The whole point: a silent "activated" that did not take the foreground
        // sends every later keystroke to the wrong application.
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId, 7: "com.example.Other"]
        workspace.frontmost = 7
        workspace.frontmostDelay = Int.max

        let outcome = AppLifecycle.activate(
            bundleId: bundleId, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 4242 },
            now: clock.now, sleep: clock.sleep
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("did not become frontmost") == true)
        #expect(result?.stderr.contains("7") == true)            // names the holder
        #expect(result?.stderr.contains("com.example.Other") == true)
        #expect(clock.time >= AppLifecycle.activateBudget)
    }

    @Test func aMissingTargetKeepsItsOwnExitCode() {
        let clock = Clock()
        let workspace = FakeWorkspace()

        let outcome = AppLifecycle.activate(
            bundleId: bundleId, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in throw AppNotRunningError(bundleId: bundleId) },
            now: clock.now, sleep: clock.sleep
        )

        #expect(failure(outcome)?.code == .runtimeFailure)
        #expect(failure(outcome)?.stderr.contains("is not running") == true)
        #expect(workspace.activations.isEmpty)
    }

    @Test func aSelfContradictoryPidIsStillAUsageError() {
        let clock = Clock()
        let workspace = FakeWorkspace()

        let outcome = AppLifecycle.activate(
            bundleId: bundleId, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in throw PidBundleMismatchError(pid: 5, requested: bundleId, actual: "com.other") },
            now: clock.now, sleep: clock.sleep
        )

        #expect(failure(outcome)?.code == .usageError)
        #expect(workspace.activations.isEmpty)
    }

    @Test func withoutAccessibilityItIsExitTwoRatherThanALostRace() {
        // The activation AND its verification both go through the accessibility
        // API, so a missing grant must be reported as the permission problem it is
        // — not as an activation that mysteriously never took.
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId]

        let outcome = AppLifecycle.activate(
            bundleId: bundleId, json: false,
            workspace: workspace, permissions: StubPermissions(accessibility: false),
            resolvePID: { _ in Issue.record("permission precedes target resolution"); return 0 },
            now: clock.now, sleep: clock.sleep
        )

        #expect(failure(outcome)?.code == .permissionMissing)
        #expect(workspace.queries == 0)
    }
}

// MARK: - quit

@Suite struct AppQuitTests {
    /// No ancestry by default: the target is unrelated to this process.
    private let noAncestors: (pid_t) -> pid_t? = { _ in nil }

    @Test func quitWaitsUntilTheProcessIsActuallyGone() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId]
        workspace.quitDelay = 3

        let outcome = AppLifecycle.quit(
            bundleId: bundleId, force: false, timeout: 10, json: true,
            workspace: workspace, resolvePID: { _ in 4242 },
            selfPID: 100, parentOf: noAncestors,
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "{\"pid\":4242,\"bundleId\":\"com.example.App\","
            + "\"terminated\":true,\"forced\":false}")
        #expect(workspace.terminations.count == 1)
        #expect(workspace.terminations.first?.force == false)
        #expect(clock.time > 0)
    }

    @Test func anApplicationThatOutlivesTheTimeoutIsNeverForcedImplicitly() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId]
        workspace.quitDelay = Int.max                    // e.g. showing a save dialog

        let outcome = AppLifecycle.quit(
            bundleId: bundleId, force: false, timeout: 3, json: false,
            workspace: workspace, resolvePID: { _ in 4242 },
            selfPID: 100, parentOf: noAncestors,
            now: clock.now, sleep: clock.sleep
        )

        let result = failure(outcome)
        #expect(result?.code == .waitTimeout)
        #expect(result?.stderr.contains("--force") == true)
        #expect(result?.stderr.contains("unsaved work") == true)
        // The load-bearing assertion: nothing was force-terminated.
        #expect(workspace.terminations.allSatisfy { !$0.force })
        #expect(clock.time >= 3)
    }

    @Test func forceEscalatesOnlyAfterAGracefulRequestExpired() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId]
        workspace.quitDelay = Int.max

        let outcome = AppLifecycle.quit(
            bundleId: bundleId, force: true, timeout: 3, json: true,
            workspace: workspace, resolvePID: { _ in 4242 },
            selfPID: 100, parentOf: noAncestors,
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "{\"pid\":4242,\"bundleId\":\"com.example.App\","
            + "\"terminated\":true,\"forced\":true}")
        // Graceful first, forced second — never the other way round.
        #expect(workspace.terminations.map(\.force) == [false, true])
    }

    @Test func forceIsNotUsedWhenTheApplicationQuitsPolitely() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId]
        workspace.quitDelay = 1

        let outcome = AppLifecycle.quit(
            bundleId: bundleId, force: true, timeout: 10, json: false,
            workspace: workspace, resolvePID: { _ in 4242 },
            selfPID: 100, parentOf: noAncestors,
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "4242")
        #expect(workspace.terminations.map(\.force) == [false])
    }

    @Test func aProcessThatSurvivesAForcedTerminationIsExitOne() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId]
        workspace.quitDelay = Int.max
        workspace.unkillable = true

        let outcome = AppLifecycle.quit(
            bundleId: bundleId, force: true, timeout: 1, json: false,
            workspace: workspace, resolvePID: { _ in 4242 },
            selfPID: 100, parentOf: noAncestors,
            now: clock.now, sleep: clock.sleep
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("survived a forced termination") == true)
    }

    @Test func aRefusedQuitRequestIsReportedNotEscalated() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId]
        workspace.terminateAccepted = false

        let outcome = AppLifecycle.quit(
            bundleId: bundleId, force: false, timeout: 10, json: false,
            workspace: workspace, resolvePID: { _ in 4242 },
            selfPID: 100, parentOf: noAncestors,
            now: clock.now, sleep: clock.sleep
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("--force") == true)
        #expect(workspace.terminations.allSatisfy { !$0.force })
    }

    @Test func refusesToQuitThisProcessOrAnyAncestorOfIt() {
        // Killing the invoking terminal would take this command down with it, so the
        // request is refused BEFORE anything is terminated.
        let ancestry: [pid_t: pid_t] = [100: 90, 90: 80, 80: 1]   // self -> shell -> terminal
        for target in [pid_t(100), 90, 80] {
            let clock = Clock()
            let workspace = FakeWorkspace()
            workspace.running = [target: bundleId]

            let outcome = AppLifecycle.quit(
                bundleId: bundleId, force: true, timeout: 10, json: false,
                workspace: workspace, resolvePID: { _ in target },
                selfPID: 100, parentOf: { ancestry[$0] },
                now: clock.now, sleep: clock.sleep
            )

            let result = failure(outcome)
            #expect(result?.code == .runtimeFailure, "pid \(target) should be refused")
            #expect(result?.stderr.contains("refusing to quit") == true)
            #expect(workspace.terminations.isEmpty, "pid \(target) must not be terminated")
        }
    }

    @Test func anUnrelatedProcessIsNotMistakenForAnAncestor() {
        let clock = Clock()
        let workspace = FakeWorkspace()
        workspace.running = [4242: bundleId]

        let outcome = AppLifecycle.quit(
            bundleId: bundleId, force: false, timeout: 10, json: false,
            workspace: workspace, resolvePID: { _ in 4242 },
            selfPID: 100, parentOf: { [100: 90, 90: 1][$0] },
            now: clock.now, sleep: clock.sleep
        )

        #expect(reported(outcome) == "4242")
    }
}

// MARK: - Process ancestry (pure)

@Suite struct ProcessAncestryTests {
    private let chain: [pid_t: pid_t] = [500: 400, 400: 300, 300: 1]

    @Test func recognizesSelfParentAndGrandparent() {
        for candidate in [pid_t(500), 400, 300, 1] {
            #expect(ProcessAncestry.isSelfOrAncestor(candidate, of: 500, parentOf: { self.chain[$0] }),
                    "\(candidate) is in the chain of 500")
        }
    }

    @Test func rejectsAnUnrelatedProcess() {
        #expect(!ProcessAncestry.isSelfOrAncestor(999, of: 500, parentOf: { self.chain[$0] }))
    }

    @Test func rejectsADescendantWhichIsNotAnAncestor() {
        // 500's child is not 500's ancestor: quitting it is allowed.
        let withChild: [pid_t: pid_t] = [600: 500, 500: 400, 400: 1]
        #expect(!ProcessAncestry.isSelfOrAncestor(600, of: 500, parentOf: { withChild[$0] }))
    }

    @Test func terminatesOnAMalformedParentCycle() {
        // A cycle must not spin: it simply reports "not an ancestor" and returns.
        let cycle: [pid_t: pid_t] = [10: 20, 20: 30, 30: 10]
        #expect(!ProcessAncestry.isSelfOrAncestor(999, of: 10, parentOf: { cycle[$0] }))
        #expect(ProcessAncestry.isSelfOrAncestor(30, of: 10, parentOf: { cycle[$0] }))
    }

    @Test func stopsAtAProcessThatIsItsOwnParent() {
        #expect(!ProcessAncestry.isSelfOrAncestor(999, of: 1, parentOf: { _ in 1 }))
    }

    /// The live parent lookup itself, because a silently-nil answer would DISABLE
    /// the self/ancestor guard without failing anything — the worst way for a safety
    /// check to break. Read-only (`sysctl`), spawns nothing, needs no permission.
    @Test func theLiveParentLookupWalksToTheRootProcess() {
        let live: (pid_t) -> pid_t? = { ProcessAncestry.liveParent(of: $0) }
        #expect(live(getpid()) != nil, "this process must have a parent")
        #expect(ProcessAncestry.isSelfOrAncestor(1, of: getpid(), parentOf: live),
                "pid 1 is an ancestor of every process")
        #expect(!ProcessAncestry.isSelfOrAncestor(0, of: getpid(), parentOf: live))
    }
}
