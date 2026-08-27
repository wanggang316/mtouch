import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

private func textArea(_ value: String) -> AXNode {
    AXNode(
        role: "AXTextArea", value: value,
        frame: CGRect(x: 0, y: 0, width: 300, height: 200), actionable: true
    )
}

private func button(_ title: String) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: CGRect(x: 0, y: 0, width: 100, height: 20), actionable: true)
}

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

/// Wrap a walked tree as a `WalkResult` — the shape `rewalk` now yields.
private func walked(_ nodes: [AXNode]) -> WalkResult {
    WalkResult(nodes: nodes, fallbackFired: false, fallbackHelped: false, truncated: false)
}

private let testApp = "com.example.App"
private let testPID: pid_t = 4242

private struct StubPermissions: PermissionProvider {
    let accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

/// Deterministic virtual clock shared by the settle's `now`/`sleep` seams, so a
/// test that reaches the post-action settle spends no wall time in it.
private final class Clock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
}

private func session(for roots: [AXNode], app: String = testApp, pid: pid_t = testPID) -> Session {
    Session(snapshot: Snapshot(roots: roots), app: app, pid: pid)
}

/// Records the gestures the pipeline delivered and, optionally, refuses.
private final class PointerRecorder {
    private(set) var actions: [PointerAction] = []
    var throwing: Error?

    func deliver(_ pid: pid_t, _ action: PointerAction) throws {
        if let throwing { throw throwing }
        actions.append(action)
    }
}

private struct DeliveryBoom: Error {}

// MARK: - Off-screen detection (pure over display rects)

@Suite struct ScreenBoundsTests {
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    @Test func pointInsideAnyDisplayIsOnScreen() {
        #expect(ScreenBounds.contains(ScreenPoint(x: 200, y: 300), in: [main, secondary]))
        #expect(ScreenBounds.contains(ScreenPoint(x: 2000, y: 500), in: [main, secondary]))
    }

    @Test func pointOutsideEveryDisplayIsOffScreen() {
        // In the notch between the two displays' heights, and far negative.
        #expect(!ScreenBounds.contains(ScreenPoint(x: 1600, y: 1050), in: [main]))
        #expect(!ScreenBounds.contains(ScreenPoint(x: -5, y: 100), in: [main, secondary]))
        #expect(!ScreenBounds.contains(ScreenPoint(x: 100, y: 5000), in: [main, secondary]))
    }

    @Test func edgesAreInclusive() {
        #expect(ScreenBounds.contains(ScreenPoint(x: 0, y: 0), in: [main]))
        #expect(ScreenBounds.contains(ScreenPoint(x: 1440, y: 900), in: [main]))
    }

    @Test func emptyDisplayListIsAlwaysOffScreen() {
        #expect(!ScreenBounds.contains(ScreenPoint(x: 0, y: 0), in: []))
    }

    @Test func liveCheckRejectsWildlyOffScreenAndAcceptsOrigin() {
        // Degrades to the main display bounds when nothing else is readable, so a
        // far-flung coordinate is off-screen and a near-origin one is on-screen.
        #expect(!ScreenBounds.isOnScreen(ScreenPoint(x: 1_000_000, y: 1_000_000)))
        #expect(ScreenBounds.isOnScreen(ScreenPoint(x: 1, y: 1)))
    }
}

// MARK: - Coordinate parsing / ref-to-coord rejection (VAL-ACT-012 usage cases)

@Suite struct CoordinateParsingTests {
    @Test func parsesValidPairs() {
        #expect(ScreenPoint(parsing: "120,64") == ScreenPoint(x: 120, y: 64))
        #expect(ScreenPoint(parsing: "10.5,-3.25") == ScreenPoint(x: 10.5, y: -3.25))
    }

    @Test(arguments: ["e1", "e12", "e", "e0", "banana", "e1,", "e1,e2"])
    func referenceTokensAreNotValidCoordinates(_ input: String) {
        // A ref (`e1`) handed to a coordinate-only verb (`--at e1`, `--from e1`)
        // fails value parsing -> ArgumentParser usage error (exit 64). It is NEVER
        // silently treated as a coordinate.
        #expect(ScreenPoint(parsing: input) == nil)
    }
}

// MARK: - PointerAction shape

@Suite struct PointerActionTests {
    @Test func pointsEnumeratesEveryTargetPoint() {
        #expect(PointerAction.click(ScreenPoint(x: 1, y: 2)).points == [ScreenPoint(x: 1, y: 2)])
        #expect(PointerAction.scroll(at: ScreenPoint(x: 3, y: 4), dy: 5).points == [ScreenPoint(x: 3, y: 4)])
        #expect(
            PointerAction.drag(from: ScreenPoint(x: 0, y: 0), to: ScreenPoint(x: 9, y: 9)).points
                == [ScreenPoint(x: 0, y: 0), ScreenPoint(x: 9, y: 9)]
        )
    }

    @Test func onlyRightClickOpensAMenu() {
        #expect(PointerAction.rightClick(ScreenPoint(x: 1, y: 1)).opensMenu)
        #expect(!PointerAction.click(ScreenPoint(x: 1, y: 1)).opensMenu)
        #expect(!PointerAction.doubleClick(ScreenPoint(x: 1, y: 1)).opensMenu)
        #expect(!PointerAction.drag(from: ScreenPoint(x: 0, y: 0), to: ScreenPoint(x: 1, y: 1)).opensMenu)
        #expect(!PointerAction.scroll(at: ScreenPoint(x: 1, y: 1), dy: 1).opensMenu)
    }
}

// MARK: - Coordinate target resolution (permission 2 -> no-target 3)

@Suite struct CoordinateTargetTests {
    private func code(_ target: ActPipeline.KeyboardTarget) -> MTouchExitCode? {
        guard case let .terminal(.failed(_, code)) = target else { return nil }
        return code
    }

    @Test func missingPermissionIsExit2BeforeAnyResolution() {
        let target = ActPipeline.resolveCoordinateTarget(
            appOverride: "com.apple.TextEdit", environment: [:],
            permissions: StubPermissions(accessibility: false),
            loadSession: { _ in Issue.record("permission must precede the session"); return nil },
            resolvePID: { _ in Issue.record("permission must precede app resolution"); return 0 }
        )
        #expect(code(target) == .permissionMissing)
    }

    @Test func noSessionAndNoAppIsRefError3WithAdvice() {
        let target = ActPipeline.resolveCoordinateTarget(
            appOverride: nil, environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in nil }, resolvePID: { _ in 0 }
        )
        #expect(code(target) == .refError)
        if case let .terminal(.failed(stderr, _)) = target {
            #expect(stderr.contains("snapshot"))
            #expect(stderr.contains("--app"))
        }
    }

    @Test func appOverrideWithNoSessionResolvesFreshRefs() {
        let target = ActPipeline.resolveCoordinateTarget(
            appOverride: "com.apple.TextEdit", environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in nil }, resolvePID: { _ in 9999 }
        )
        guard case let .resolved(pid, app, refs, _) = target else {
            Issue.record("expected a resolved target"); return
        }
        #expect(pid == 9999)
        #expect(app == "com.apple.TextEdit")
        #expect(refs.isEmpty)
    }
}

// MARK: - Full coordinate run (back half via injected seams)

@Suite struct CoordinateRunTests {
    @Test func noSessionAndNoAppIsExit3AndDeliversNothing() {
        let recorder = PointerRecorder()
        let outcome = ActPipeline.runCoordinate(
            action: .click(ScreenPoint(x: 10, y: 10)), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in nil },
            resolvePID: { _ in 0 },
            isRunning: { _, _ in Issue.record("no target -> no liveness check"); return false },
            onScreen: { _ in true },
            rewalk: { _ in Issue.record("no target -> no walk"); return nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("no target -> no persist") },
            sleep: { _ in }
        )
        guard case let .failed(_, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .refError)
        #expect(recorder.actions.isEmpty)
    }

    @Test func offScreenCoordinateIsExit1AndDeliversNothing() {
        let recorder = PointerRecorder()
        let outcome = ActPipeline.runCoordinate(
            action: .click(ScreenPoint(x: 99999, y: 99999)), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in Issue.record("off-screen must be rejected before liveness"); return true },
            onScreen: { _ in false },
            rewalk: { _ in Issue.record("off-screen must be rejected before any walk"); return nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("off-screen must not persist") },
            sleep: { _ in }
        )
        guard case let .failed(stderr, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("outside every display"))
        #expect(recorder.actions.isEmpty) // ZERO events for a rejected coordinate
    }

    @Test func dragValidatesBothEndpointsBeforePosting() {
        let recorder = PointerRecorder()
        // First endpoint on-screen, second off-screen: the whole gesture is rejected.
        let onScreen: (ScreenPoint) -> Bool = { $0.x < 5000 }
        let outcome = ActPipeline.runCoordinate(
            action: .drag(from: ScreenPoint(x: 10, y: 10), to: ScreenPoint(x: 99999, y: 10)),
            appOverride: nil, json: false, environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            onScreen: onScreen,
            rewalk: { _ in Issue.record("off-screen endpoint must be rejected before any walk"); return nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        guard case let .failed(_, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .runtimeFailure)
        #expect(recorder.actions.isEmpty)
    }

    @Test func processGoneIsExit1AndDeliversNothing() {
        let recorder = PointerRecorder()
        let outcome = ActPipeline.runCoordinate(
            action: .click(ScreenPoint(x: 10, y: 10)), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in false },
            onScreen: { _ in true },
            rewalk: { _ in Issue.record("must not walk a dead process"); return nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("must not persist") }, sleep: { _ in }
        )
        guard case let .failed(stderr, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("no longer running"))
        #expect(recorder.actions.isEmpty)
    }

    @Test func preWalkTimeoutIsExit1BeforeDelivery() {
        let recorder = PointerRecorder()
        let outcome = ActPipeline.runCoordinate(
            action: .click(ScreenPoint(x: 10, y: 10)), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            onScreen: { _ in true },
            rewalk: { _ in nil }, // bounded timeout on the pre walk
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("must not persist") }, sleep: { _ in }
        )
        guard case let .failed(_, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .runtimeFailure)
        #expect(recorder.actions.isEmpty)
    }

    @Test func deliveryFailureIsExit1() {
        let recorder = PointerRecorder()
        recorder.throwing = DeliveryBoom()
        let outcome = ActPipeline.runCoordinate(
            action: .click(ScreenPoint(x: 10, y: 10)), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            onScreen: { _ in true },
            rewalk: { _ in walked([window([textArea("")])]) },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("a failed delivery must not persist") },
            sleep: { _ in }
        )
        guard case let .failed(_, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .runtimeFailure)
    }

    @Test func clickSurfacingAChangeRendersDiffAndPersists() {
        let pre = [window([textArea("")])]
        let post = [window([textArea(""), button("Paste")])] // some observable change
        let clock = Clock()
        var walks = 0
        let recorder = PointerRecorder()
        var persisted: Snapshot?

        let outcome = ActPipeline.runCoordinate(
            action: .click(ScreenPoint(x: 150, y: 100)), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: pre) },
            isRunning: { _, _ in true },
            onScreen: { _ in true },
            rewalk: { _ in
                walks += 1
                return walks == 1 ? walked(pre) : walked(post)
            },
            deliver: { try recorder.deliver($0, $1) },
            persist: { snapshot, _, _, _ in persisted = snapshot },
            now: clock.now, sleep: clock.sleep
        )

        guard case let .acted(rendered) = outcome else { Issue.record("expected an acted outcome"); return }
        #expect(rendered.contains("Paste"))
        #expect(recorder.actions.count == 1)
        #expect(recorder.actions.first == .click(ScreenPoint(x: 150, y: 100)))
        #expect(persisted != nil)
    }

    @Test func noEffectClickIsNoChangesExit0() {
        let pre = [window([textArea("")])]
        let clock = Clock()
        let recorder = PointerRecorder()
        let outcome = ActPipeline.runCoordinate(
            action: .click(ScreenPoint(x: 150, y: 100)), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: pre) },
            isRunning: { _, _ in true },
            onScreen: { _ in true },
            rewalk: { _ in walked(pre) }, // nothing changed
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in }, now: clock.now, sleep: clock.sleep
        )
        // Every walk agreed the tree still equals the pre tree, so "(no changes)" is
        // a SETTLED reading — `.acted`, not `.actedUnsettled`.
        #expect(outcome == .acted(DiffText.noChangesMarker))
        #expect(recorder.actions.count == 1)
    }

    @Test func appOverrideWithNoSessionDeliversTheGesture() {
        let post = [window([textArea("x")])]
        let clock = Clock()
        var walks = 0
        let recorder = PointerRecorder()
        let outcome = ActPipeline.runCoordinate(
            action: .scroll(at: ScreenPoint(x: 20, y: 20), dy: 300),
            appOverride: "com.apple.TextEdit", json: true, environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in nil }, // no prior session
            resolvePID: { _ in 9999 },
            isRunning: { _, _ in true },
            onScreen: { _ in true },
            rewalk: { _ in walks += 1; return walked(post) },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in }, now: clock.now, sleep: clock.sleep
        )
        guard case .acted = outcome else { Issue.record("expected an acted outcome"); return }
        #expect(recorder.actions.first == .scroll(at: ScreenPoint(x: 20, y: 20), dy: 300))
    }
}
