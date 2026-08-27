import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

private let testApp = "com.example.App"
private let testPID: pid_t = 4242

private struct StubPermissions: PermissionProvider {
    let accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

/// Deterministic virtual clock shared by the settle's `now`/`sleep` seams, so a
/// test that reaches the post-action settle spends no wall time in it — the menu
/// budget is the longest in the codebase.
private final class Clock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
}

private func window(_ title: String, _ children: [AXNode] = []) -> AXNode {
    AXNode(role: kAXWindowRole, title: title, frame: CGRect(x: 0, y: 0, width: 400, height: 300),
           children: children)
}

private func walked(_ nodes: [AXNode]) -> WalkResult {
    WalkResult(nodes: nodes, fallbackFired: false, fallbackHelped: false, truncated: false)
}

private func session(for roots: [AXNode]) -> Session {
    Session(snapshot: Snapshot(roots: roots), app: testApp, pid: testPID)
}

private func menuPath(_ raw: String) -> MenuPath {
    // Every literal here is a valid path; a malformed one is covered by the grammar
    // tests, which is where that failure belongs.
    try! MenuPath(parsing: raw)
}

/// Records the order of the side effects the pipeline drives, so "activated BEFORE
/// the menu was walked" is asserted as an ordering fact rather than assumed.
private final class Journal {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private func failure(_ outcome: ActOutcome) -> (stderr: String, code: MTouchExitCode)? {
    guard case let .failed(stderr, code) = outcome else { return nil }
    return (stderr, code)
}

// MARK: - Target resolution

@Suite struct ActMenuTargetTests {
    private func code(_ target: ActPipeline.KeyboardTarget) -> MTouchExitCode? {
        guard case let .terminal(.failed(_, code)) = target else { return nil }
        return code
    }

    @Test func missingPermissionIsExitTwoBeforeAnyResolution() {
        let target = ActPipeline.resolveMenuTarget(
            appOverride: testApp, environment: [:],
            permissions: StubPermissions(accessibility: false),
            loadSession: { _ in Issue.record("permission precedes the session"); return nil },
            resolvePID: { _ in Issue.record("permission precedes app resolution"); return 0 }
        )
        #expect(code(target) == .permissionMissing)
    }

    @Test func noSessionAndNoAppIsRefErrorWithMenuSpecificAdvice() {
        let target = ActPipeline.resolveMenuTarget(
            appOverride: nil, environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in nil }, resolvePID: { _ in 0 }
        )
        #expect(code(target) == .refError)
        guard case let .terminal(.failed(stderr, _)) = target else {
            Issue.record("expected a terminal outcome"); return
        }
        #expect(stderr.contains("menus"))
        #expect(stderr.contains("--app"))
    }
}

// MARK: - Full run

@Suite struct ActMenuRunTests {
    @Test func invokesThePathAndRendersTheResultingDiff() {
        let journal = Journal()
        let clock = Clock()
        let pre = [window("Untitled")]
        let post = [window("Untitled"), window("Untitled 2")]
        var walks = 0

        let outcome = ActPipeline.runMenu(
            path: menuPath("File>New File"), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: pre) },
            resolvePID: { _ in testPID },
            isRunning: { _, _ in true },
            activate: { _ in journal.record("activate") },
            rewalk: { _ in
                walks += 1
                journal.record("walk")
                return walked(walks == 1 ? pre : post)
            },
            invoke: { _, _ in journal.record("invoke"); return .success(()) },
            persist: { _, _, _, _ in journal.record("persist") },
            now: clock.now, sleep: clock.sleep
        )

        guard case let .acted(output) = outcome else {
            Issue.record("expected a rendered diff, got \(outcome)"); return
        }
        #expect(output.contains("Untitled 2"))       // the new window shows up in the diff
        // Activation precedes the baseline walk (only the frontmost app's menu bar
        // is drawn), and the session is persisted before anything is rendered.
        #expect(journal.events.prefix(3) == ["activate", "walk", "invoke"])
        #expect(journal.events.contains("persist"))
    }

    @Test func aMenuFailureIsReportedVerbatimWithItsExitCode() {
        let pre = [window("Untitled")]
        let outcome = ActPipeline.runMenu(
            path: menuPath("File>Nope"), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: pre) },
            resolvePID: { _ in testPID },
            isRunning: { _, _ in true },
            activate: { _ in },
            rewalk: { _ in walked(pre) },
            invoke: { _, _ in
                .failure(MenuPathError(reason: .notFound(
                    segment: "Nope", context: "menu 'File'", available: ["New File", "Save"]
                )))
            },
            persist: { _, _, _, _ in Issue.record("a failed menu path must not persist a session") },
            sleep: { _ in }
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("'New File'") == true)   // the available titles survive
        #expect(result?.stderr.contains("Nope") == true)
    }

    @Test func anUnreadableMenuBarNamesTheApplicationAndPid() {
        let pre = [window("Untitled")]
        let outcome = ActPipeline.runMenu(
            path: menuPath("File>Save"), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: pre) },
            resolvePID: { _ in testPID },
            isRunning: { _, _ in true },
            activate: { _ in },
            rewalk: { _ in walked(pre) },
            invoke: { _, _ in .failure(MenuPathError(reason: .menuBarUnreadable)) },
            persist: { _, _, _, _ in },
            sleep: { _ in }
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains(testApp) == true)
        #expect(result?.stderr.contains("\(testPID)") == true)
    }

    @Test func aDeadTargetIsExitOneAndNothingIsDriven() {
        let outcome = ActPipeline.runMenu(
            path: menuPath("File>Save"), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window("Untitled")]) },
            resolvePID: { _ in testPID },
            isRunning: { _, _ in false },
            activate: { _ in Issue.record("a dead process must not be activated") },
            rewalk: { _ in Issue.record("a dead process must not be walked"); return nil },
            invoke: { _, _ in Issue.record("a dead process must not be driven"); return .success(()) },
            persist: { _, _, _, _ in },
            sleep: { _ in }
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("no longer running") == true)
    }

    @Test func anUnresponsiveTargetIsABoundedExitOneNotAHang() {
        let outcome = ActPipeline.runMenu(
            path: menuPath("File>Save"), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window("Untitled")]) },
            resolvePID: { _ in testPID },
            isRunning: { _, _ in true },
            activate: { _ in },
            rewalk: { _ in nil },                       // the bounded walk timed out
            invoke: { _, _ in Issue.record("must not drive menus of an unresponsive app"); return .success(()) },
            persist: { _, _, _, _ in },
            sleep: { _ in }
        )

        let result = failure(outcome)
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("timed out") == true)
    }

    @Test func anExplicitAppTargetsThatApplicationWithoutASession() {
        let clock = Clock()
        var invokedPID: pid_t?
        let post = [window("Untitled")]
        let outcome = ActPipeline.runMenu(
            path: menuPath("File>New File"), appOverride: "com.example.Other", json: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in nil },                  // no prior snapshot at all
            resolvePID: { _ in 77 },
            isRunning: { _, _ in true },
            activate: { _ in },
            rewalk: { _ in walked(post) },
            invoke: { pid, _ in invokedPID = pid; return .success(()) },
            persist: { _, _, _, _ in },
            now: clock.now, sleep: clock.sleep
        )

        #expect(invokedPID == 77)
        guard case let .acted(output) = outcome else {
            Issue.record("expected a rendered diff, got \(outcome)"); return
        }
        #expect(output.hasPrefix("{"))                  // --json stays JSON
    }
}
