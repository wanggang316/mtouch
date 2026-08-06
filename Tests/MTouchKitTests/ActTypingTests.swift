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

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

private let testApp = "com.example.App"
private let testPID: pid_t = 4242

private struct StubPermissions: PermissionProvider {
    let accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

/// A session whose refs number the given pre tree (so a survivor keeps its ref).
private func session(for roots: [AXNode], app: String = testApp, pid: pid_t = testPID) -> Session {
    Session(snapshot: Snapshot(roots: roots), app: app, pid: pid)
}

/// Records the keystrokes the pipeline delivered and, optionally, refuses.
private final class DeliveryRecorder {
    private(set) var actions: [KeyboardAction] = []
    var throwing: Error?

    func deliver(_ pid: pid_t, _ action: KeyboardAction) throws {
        if let throwing { throw throwing }
        actions.append(action)
    }
}

// MARK: - Empty `type` no-op (short-circuits before everything)

@Suite struct ActTypeEmptyTests {
    @Test func emptyTypeIsNoChangesExit0WithoutTouchingPermissionOrDelivery() {
        let recorder = DeliveryRecorder()
        let outcome = ActPipeline.runKeyboard(
            action: .type(""), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: false), // would be exit 2 if consulted
            loadSession: { _ in Issue.record("empty type must not load a session"); return nil },
            resolvePID: { _ in Issue.record("empty type must not resolve an app"); return 0 },
            isRunning: { _, _ in Issue.record("empty type must not check liveness"); return false },
            rewalk: { _ in Issue.record("empty type must not walk"); return nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("empty type must not persist") },
            sleep: { _ in }
        )
        #expect(outcome == .acted(DiffText.noChangesMarker))
        #expect(recorder.actions.isEmpty)
    }

    @Test func emptyTypeJSONRendersEmptyDiffObject() {
        let outcome = ActPipeline.runKeyboard(
            action: .type(""), appOverride: nil, json: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            deliver: { _, _ in },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        #expect(outcome == .acted("{\"added\":[],\"removed\":[],\"changed\":[]}"))
    }
}

// MARK: - Target resolution + permission precedence

@Suite struct ActKeyboardTargetTests {
    private func code(_ target: ActPipeline.KeyboardTarget) -> MTouchExitCode? {
        guard case let .terminal(.failed(_, code)) = target else { return nil }
        return code
    }

    @Test func missingPermissionIsExit2BeforeAnyResolution() {
        let target = ActPipeline.resolveKeyboardTarget(
            appOverride: "com.apple.TextEdit", environment: [:],
            permissions: StubPermissions(accessibility: false),
            loadSession: { _ in Issue.record("permission must be checked before the session"); return nil },
            resolvePID: { _ in Issue.record("permission must be checked before app resolution"); return 0 }
        )
        #expect(code(target) == .permissionMissing)
    }

    @Test func noSessionAndNoAppIsRefError3WithAdvice() {
        let target = ActPipeline.resolveKeyboardTarget(
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

    @Test func sessionAppIsTheDefaultTargetWithItsRefs() {
        let pre = [window([textArea("")])]
        let session = session(for: pre)
        let target = ActPipeline.resolveKeyboardTarget(
            appOverride: nil, environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session }, resolvePID: { _ in Issue.record("no --app -> no pid resolution"); return 0 }
        )
        guard case let .resolved(pid, app, refs, _) = target else {
            Issue.record("expected a resolved session target"); return
        }
        #expect(pid == testPID)
        #expect(app == testApp)
        #expect(refs["e1"]?.role == "AXTextArea")
    }

    @Test func appOverrideMatchingSessionReusesSessionRefs() {
        let pre = [window([textArea("")])]
        let session = session(for: pre)
        let target = ActPipeline.resolveKeyboardTarget(
            appOverride: testApp, environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session }, resolvePID: { _ in testPID }
        )
        guard case let .resolved(pid, app, refs, _) = target else {
            Issue.record("expected a resolved target"); return
        }
        #expect(pid == testPID)
        #expect(app == testApp)
        #expect(refs["e1"] != nil) // session refs carried across
    }

    @Test func appOverrideDifferingFromSessionStartsFreshRefs() {
        let session = session(for: [window([textArea("")])])
        let target = ActPipeline.resolveKeyboardTarget(
            appOverride: "com.apple.TextEdit", environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session }, resolvePID: { _ in 9999 }
        )
        guard case let .resolved(pid, app, refs, _) = target else {
            Issue.record("expected a resolved target"); return
        }
        #expect(pid == 9999)
        #expect(app == "com.apple.TextEdit")
        #expect(refs.isEmpty) // a different app -> the session refs do not apply
    }

    @Test func appOverrideNotRunningIsRuntimeError1() {
        let target = ActPipeline.resolveKeyboardTarget(
            appOverride: "com.apple.NotRunning", environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in nil },
            resolvePID: { bundleId in throw AppNotRunningError(bundleId: bundleId) }
        )
        #expect(code(target) == .runtimeFailure)
        if case let .terminal(.failed(stderr, _)) = target {
            #expect(stderr.contains("com.apple.NotRunning"))
        }
    }
}

// MARK: - Full keyboard run (back half via injected seams)

@Suite struct ActKeyboardRunTests {
    @Test func processGoneIsRuntimeError1AndDeliversNothing() {
        let recorder = DeliveryRecorder()
        let outcome = ActPipeline.runKeyboard(
            action: .type("hi"), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in false },
            rewalk: { _ in Issue.record("must not walk a dead process"); return nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("must not persist") }, sleep: { _ in }
        )
        guard case let .failed(stderr, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("no longer running"))
        #expect(recorder.actions.isEmpty)
    }

    @Test func preWalkTimeoutIsRuntimeError1BeforeDelivery() {
        let recorder = DeliveryRecorder()
        let outcome = ActPipeline.runKeyboard(
            action: .type("hi"), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            rewalk: { _ in nil }, // bounded timeout on the pre walk
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("must not persist") }, sleep: { _ in }
        )
        guard case let .failed(_, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .runtimeFailure)
        #expect(recorder.actions.isEmpty) // never delivered without a baseline
    }

    @Test func secureInputIsExit5WithZeroPersistAndNoLeak() {
        let secret = "correct horse battery staple 42"
        let recorder = DeliveryRecorder()
        recorder.throwing = SecureInputActive()
        let outcome = ActPipeline.runKeyboard(
            action: .type(secret), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            rewalk: { _ in [window([textArea("")])] },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("secure input must not persist a session") },
            sleep: { _ in }
        )
        guard case let .failed(stderr, code) = outcome else { Issue.record("expected failure"); return }
        #expect(code == .secureInput)
        #expect(!stderr.contains(secret)) // payload never reaches stderr
    }

    @Test func typingSurfacesAChangedDiffKeepingTheFocusedElementRef() {
        let pre = [window([textArea("")])]
        let post = [window([textArea("hello world")])]
        var walks = 0
        let recorder = DeliveryRecorder()
        var persisted: Snapshot?

        let outcome = ActPipeline.runKeyboard(
            action: .type("hello world"), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: pre) },
            isRunning: { _, _ in true },
            rewalk: { _ in
                walks += 1
                return walks == 1 ? pre : post // first walk = pre baseline, then the typed state
            },
            deliver: { try recorder.deliver($0, $1) },
            persist: { snapshot, _, _, _ in persisted = snapshot },
            sleep: { _ in }
        )

        guard case let .acted(rendered) = outcome else { Issue.record("expected an acted outcome"); return }
        #expect(rendered.hasPrefix("~"))                 // a change, not add/remove
        #expect(rendered.contains("hello world"))        // the new value is shown
        #expect(rendered.contains("e1"))                 // the focused element kept its ref
        // Delivered exactly the requested text.
        #expect(recorder.actions.count == 1)
        if case let .type(text) = recorder.actions.first { #expect(text == "hello world") }
        else { Issue.record("expected a type action") }
        // Persisted the new session with the text area still act-able as e1.
        #expect(persisted?.refs["e1"] != nil)
    }

    @Test func keyComboIsDeliveredThroughTheSamePath() {
        let recorder = DeliveryRecorder()
        let combo = try? KeyCombo(parsing: "cmd+a")
        let outcome = ActPipeline.runKeyboard(
            action: .key(combo!), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("x")])]) },
            isRunning: { _, _ in true },
            rewalk: { _ in [window([textArea("x")])] }, // selection change is invisible to AX value
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        guard case .acted = outcome else { Issue.record("expected an acted outcome"); return }
        #expect(recorder.actions.count == 1)
        if case let .key(delivered) = recorder.actions.first { #expect(delivered == combo) }
        else { Issue.record("expected a key action") }
    }
}
