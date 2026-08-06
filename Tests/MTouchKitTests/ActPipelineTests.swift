import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

private func button(_ title: String) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: CGRect(x: 0, y: 0, width: 100, height: 20), actionable: true)
}

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

/// Three actionable refs e1..e3 (First/Second/Third buttons in a window).
private func sampleSnapshot() -> Snapshot {
    Snapshot(roots: [window([button("First"), button("Second"), button("Third")])])
}

private struct StubPermissions: PermissionProvider {
    let accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-act-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func writeSession(_ snapshot: Snapshot, app: String = "com.example.App", pid: Int32 = 4242, to dir: URL) throws -> String {
    let path = dir.appendingPathComponent("session.json").path
    try SessionStore.save(snapshot, app: app, pid: pid, to: path)
    return path
}

/// Resolve a target, granting Accessibility by default so non-permission cases
/// are isolated. `env` points the store at the temp session file.
private func resolve(
    ref: String,
    verb: ActVerb = .press,
    value: String? = nil,
    sessionPath: String?,
    accessibility: Bool = true
) -> ActPipeline.Target {
    var env: [String: String] = [:]
    if let sessionPath { env[MTouchEnvironment.sessionKey] = sessionPath }
    else { env[MTouchEnvironment.sessionKey] = "/nonexistent/mtouch-act-tests/none.json" }
    return ActPipeline.resolveTarget(
        ref: ref, verb: verb, value: value,
        environment: env,
        permissions: StubPermissions(accessibility: accessibility),
        loadSession: { SessionStore.load(from: $0) }
    )
}

private func terminalCode(_ target: ActPipeline.Target) -> MTouchExitCode? {
    guard case let .terminal(.failed(_, code)) = target else { return nil }
    return code
}

// MARK: - Exit-code precedence (usage 64 -> permission 2 -> ref 3)

@Suite struct ActResolveExitMappingTests {
    @Test func nonTokenRefIsUsageError64() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            #expect(terminalCode(resolve(ref: "banana", sessionPath: path)) == .usageError)
            #expect(terminalCode(resolve(ref: "e0", sessionPath: path)) == .usageError)
            #expect(terminalCode(resolve(ref: "e", sessionPath: path)) == .usageError)
            #expect(terminalCode(resolve(ref: "e1x", sessionPath: path)) == .usageError)
        }
    }

    @Test func setValueWithoutValueIsUsageError64() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            #expect(terminalCode(resolve(ref: "e1", verb: .setValue, value: nil, sessionPath: path)) == .usageError)
            // With a value it proceeds to resolution (and resolves).
            guard case .resolved = resolve(ref: "e1", verb: .setValue, value: "x", sessionPath: path) else {
                Issue.record("set-value with a value should resolve e1"); return
            }
        }
    }

    @Test func malformedRefOutranksMissingPermission() throws {
        // Usage (64) is decided from the argument alone, so it precedes the
        // permission gate even when Accessibility is absent.
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            #expect(terminalCode(resolve(ref: "banana", sessionPath: path, accessibility: false)) == .usageError)
        }
    }

    @Test func missingPermissionIsExit2ForAWellFormedRef() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            #expect(terminalCode(resolve(ref: "e1", sessionPath: path, accessibility: false)) == .permissionMissing)
        }
    }

    @Test func staleTokenIsRefError3() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            let target = resolve(ref: "e999", sessionPath: path)
            #expect(terminalCode(target) == .refError)
            if case let .terminal(.failed(stderr, _)) = target {
                #expect(stderr.contains("e999"))            // names the ref
                #expect(stderr.contains("snapshot"))        // advises a re-snapshot
            }
        }
    }

    @Test func noSessionIsRefError3AndAdvisesSnapshot() {
        let target = resolve(ref: "e1", sessionPath: nil)   // no file
        #expect(terminalCode(target) == .refError)
        if case let .terminal(.failed(stderr, _)) = target {
            #expect(stderr.contains("e1"))
            #expect(stderr.contains("snapshot"))
        }
    }

    @Test func corruptSessionResolvesAsNoSessionExit3() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            try Data("}{ not json".utf8).write(to: URL(fileURLWithPath: path))
            #expect(terminalCode(resolve(ref: "e1", sessionPath: path)) == .refError)
        }
    }

    @Test func resolvedRefReturnsTheEntry() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            guard case let .resolved(entry, session, sessionPath) = resolve(ref: "e2", sessionPath: path) else {
                Issue.record("e2 should resolve"); return
            }
            #expect(entry.ref == "e2")
            #expect(entry.title == "Second")
            #expect(session.pid == 4242)
            #expect(sessionPath == path)
        }
    }
}

// MARK: - App-not-running -> exit 1 (back-half mapping via injected liveness)

@Suite struct ActRunLivenessTests {
    @Test func resolvedButProcessGoneIsRuntimeError1() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            let outcome = ActPipeline.run(
                ref: "e1", verb: .press, value: nil, json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in false },                       // process is gone
                walkLive: { _ in Issue.record("must not walk a dead process"); return nil },
                rewalk: { _ in nil },
                performAction: { _, _, _ in .success(()) },
                persist: { _, _, _, _ in },
                sleep: { _ in }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected failure"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("no longer running"))
        }
    }

    @Test func walkTimeoutIsRuntimeError1() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            let outcome = ActPipeline.run(
                ref: "e1", verb: .press, value: nil, json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in true },
                walkLive: { _ in nil },                             // bounded timeout
                rewalk: { _ in nil },
                performAction: { _, _, _ in .success(()) },
                persist: { _, _, _, _ in },
                sleep: { _ in }
            )
            guard case let .failed(_, code) = outcome else { Issue.record("expected failure"); return }
            #expect(code == .runtimeFailure)
        }
    }
}

// MARK: - Post-action settle (pure, no AX)

@Suite struct ActSettleTests {
    @Test func settleStopsEarlyOnFirstChange() {
        // rewalk yields the pre tree twice then a changed tree; the loop must stop
        // as soon as a change appears (never exhaust the budget) and never sleep
        // after the winning walk.
        let pre = Snapshot(roots: [window([button("A")])])
        let changed = [window([button("A"), button("B")])]
        var calls = 0
        var sleeps = 0
        let result = ActPipeline.settledDiff(
            pre: pre, pid: 1, expectsMenu: true,
            rewalk: { _ in
                calls += 1
                return calls < 3 ? [window([button("A")])] : changed
            },
            sleep: { _ in sleeps += 1 }
        )
        #expect(result.diff.added.count == 1)
        #expect(result.diff.added.first?.ref == "e2")
        #expect(calls == 3)
        #expect(sleeps == 2)                    // slept only between the first three walks
    }

    @Test func settleReturnsNoChangesWhenNothingHappens() {
        let pre = Snapshot(roots: [window([button("A")])])
        var calls = 0
        let result = ActPipeline.settledDiff(
            pre: pre, pid: 1, expectsMenu: false,
            rewalk: { _ in calls += 1; return [window([button("A")])] },
            sleep: { _ in }
        )
        #expect(result.diff.isEmpty)
        #expect(calls == 4)                     // non-menu budget
        #expect(DiffText.render(result.diff) == DiffText.noChangesMarker)
    }

    @Test func settleFallsBackToNoChangesWhenEveryWalkFails() {
        let pre = Snapshot(roots: [window([button("A")])])
        let result = ActPipeline.settledDiff(
            pre: pre, pid: 1, expectsMenu: false,
            rewalk: { _ in nil }, sleep: { _ in }
        )
        #expect(result.diff.isEmpty)
    }
}

// MARK: - Re-location by hint (VAL-ACT-011 / VAL-ACT-017 crux)

@Suite struct ElementRelocationTests {
    private func attrs(_ role: String, subrole: String? = nil, title: String? = nil) -> AXAttributes {
        AXAttributes(role: role, subrole: subrole, title: title)
    }

    private func entry(
        role: String, subrole: String? = nil, title: String? = nil,
        path: [Int], ancestors: [NodeHint] = []
    ) -> RefEntry {
        RefEntry(
            node: AXNode(role: role, subrole: subrole, title: title, actionable: true),
            ref: "e1", path: path, ancestors: ancestors
        )
    }

    /// The identity of a lone `AXWindow` root, the ancestor every element in these
    /// single-window fixtures carries.
    private let windowAncestors = [NodeHint(role: kAXWindowRole)]

    @Test func positionalMatchWinsWhenHintsAgree() {
        // The element survived at its path after an unrelated action.
        let index: [[Int]: AXAttributes] = [
            [0]: attrs(kAXWindowRole),
            [0, 0]: attrs(kAXButtonRole, title: "Save"),
        ]
        let path = ElementRelocation.locatePath(
            entry(role: kAXButtonRole, title: "Save", path: [0, 0], ancestors: windowAncestors), in: index
        )
        #expect(path == [0, 0])
    }

    @Test func positionalImpostorIsRejectedThenRecoveredByUniqueHint() {
        // Something else now occupies the old path (impostor). The real element
        // moved to a new path within the SAME window; a UNIQUE hint + ancestor
        // match recovers it — we never act on the impostor.
        let index: [[Int]: AXAttributes] = [
            [0]: attrs(kAXWindowRole),
            [0, 0]: attrs(kAXButtonRole, title: "Cancel"),      // impostor at old path
            [0, 1]: attrs(kAXButtonRole, title: "Save"),        // the real one, moved
        ]
        let path = ElementRelocation.locatePath(
            entry(role: kAXButtonRole, title: "Save", path: [0, 0], ancestors: windowAncestors), in: index
        )
        #expect(path == [0, 1])
    }

    @Test func missingElementIsStaleNil() {
        let index: [[Int]: AXAttributes] = [
            [0]: attrs(kAXWindowRole),
            [0, 0]: attrs(kAXButtonRole, title: "Cancel"),
        ]
        // "Save" is gone entirely -> nil (stale). The impostor is never chosen.
        #expect(ElementRelocation.locatePath(
            entry(role: kAXButtonRole, title: "Save", path: [0, 0], ancestors: windowAncestors), in: index
        ) == nil)
    }

    @Test func ambiguousHintMatchIsStaleNil() {
        // Two equally-matching candidates (same window, same hints) and neither at
        // the ref's path: ambiguous, so refuse rather than guess.
        let index: [[Int]: AXAttributes] = [
            [0]: attrs(kAXWindowRole),
            [0, 3]: attrs(kAXButtonRole, title: "Item"),
            [0, 4]: attrs(kAXButtonRole, title: "Item"),
        ]
        #expect(ElementRelocation.locatePath(
            entry(role: kAXButtonRole, title: "Item", path: [0, 0], ancestors: windowAncestors), in: index
        ) == nil)
    }

    @Test func hintsMatchDistinguishesRoleSubroleTitle() {
        let e = entry(role: kAXButtonRole, subrole: "AXCloseButton", title: "close", path: [0])
        #expect(ElementRelocation.hintsMatch(attrs(kAXButtonRole, subrole: "AXCloseButton", title: "close"), e))
        #expect(!ElementRelocation.hintsMatch(attrs(kAXButtonRole, subrole: nil, title: "close"), e))
        #expect(!ElementRelocation.hintsMatch(attrs(kAXTextFieldRole, subrole: "AXCloseButton", title: "close"), e))
        #expect(!ElementRelocation.hintsMatch(attrs(kAXButtonRole, subrole: "AXCloseButton", title: "other"), e))
    }
}

// MARK: - Ancestor identity: reject a same-hint impostor in a DIFFERENT window
// (VAL-ACT-011 — the destructive-misdelivery regression)

@Suite struct ElementRelocationAncestorTests {
    private func attrs(_ role: String, subrole: String? = nil, title: String? = nil) -> AXAttributes {
        AXAttributes(role: role, subrole: subrole, title: title)
    }

    /// A close-button ref inside a specific window, carrying that window's identity
    /// as its ancestor chain — the shape a real snapshot records. The button's own
    /// hints (AXButton / AXCloseButton / no title) are IDENTICAL across windows, so
    /// only the ancestor chain can tell two such refs apart.
    private func closeButtonRef(inWindowTitled windowTitle: String, path: [Int]) -> RefEntry {
        RefEntry(
            node: AXNode(role: kAXButtonRole, subrole: "AXCloseButton", actionable: true),
            ref: "e1", path: path,
            ancestors: [NodeHint(role: kAXWindowRole, subrole: "AXStandardWindow", title: windowTitle)]
        )
    }

    /// Two standard windows, each with one close button; the close buttons share
    /// identical local hints and only their owning window's title differs.
    private func twoWindowIndex() -> [[Int]: AXAttributes] {
        [
            [0]: attrs(kAXWindowRole, subrole: "AXStandardWindow", title: "Doc A"),
            [0, 0]: attrs(kAXButtonRole, subrole: "AXCloseButton"),
            [1]: attrs(kAXWindowRole, subrole: "AXStandardWindow", title: "Doc B"),
            [1, 0]: attrs(kAXButtonRole, subrole: "AXCloseButton"),
        ]
    }

    @Test func ancestorIdentityDisambiguatesTwoIdenticalCloseButtons() {
        // Both windows present: each ref resolves to ITS OWN close button, never the
        // other's — position + ancestor identity together pick the right one.
        let index = twoWindowIndex()
        #expect(ElementRelocation.locatePath(closeButtonRef(inWindowTitled: "Doc A", path: [0, 0]), in: index) == [0, 0])
        #expect(ElementRelocation.locatePath(closeButtonRef(inWindowTitled: "Doc B", path: [1, 0]), in: index) == [1, 0])
    }

    @Test func frontWindowClosedSlidesBackWindowIn_staleRefRejectsTheImpostor() {
        // A snapshot recorded a ref to the FRONT window's (Doc A) close button at
        // [0,0]. The front window then closes; the BACK window (Doc B) slides into
        // root index 0, so a structurally-identical close button now sits at [0,0].
        let afterClose: [[Int]: AXAttributes] = [
            [0]: attrs(kAXWindowRole, subrole: "AXStandardWindow", title: "Doc B"),
            [0, 0]: attrs(kAXButtonRole, subrole: "AXCloseButton"),
        ]
        // The positional occupant matches LOCAL hints exactly but belongs to Doc B,
        // so ancestor identity rejects it -> stale (nil). Nothing is acted on, and
        // the still-wanted back window is never closed (the destructive misdelivery).
        #expect(ElementRelocation.locatePath(closeButtonRef(inWindowTitled: "Doc A", path: [0, 0]), in: afterClose) == nil)
    }

    @Test func genuinelySurvivingElementStillResolvesAfterAnUnrelatedChange() {
        // Doc A survived; only Doc B closed. The Doc A close-button ref must still
        // resolve at its unchanged path — ancestor identity must not over-reject.
        let afterBackClosed: [[Int]: AXAttributes] = [
            [0]: attrs(kAXWindowRole, subrole: "AXStandardWindow", title: "Doc A"),
            [0, 0]: attrs(kAXButtonRole, subrole: "AXCloseButton"),
        ]
        #expect(ElementRelocation.locatePath(closeButtonRef(inWindowTitled: "Doc A", path: [0, 0]), in: afterBackClosed) == [0, 0])
    }
}

// MARK: - Ref-verb back half via the LiveElementTree fake seam
// (relocation-miss -> 3, AX-action-failure -> 1, success -> acted + persisted)

@Suite struct ActRunBackHalfTests {
    /// A fake live tree for the `sampleSnapshot` shape (window "W" with First/
    /// Second/Third buttons). `resolving` names the paths that carry a sentinel
    /// handle so a re-located element is non-nil; attributes match the session so
    /// `ElementRelocation` resolves the ref (including its window ancestor).
    private func sampleFakeTree(resolving handlePaths: [[Int]]) -> LiveElementTree {
        let attributes: [[Int]: AXAttributes] = [
            [0]: AXAttributes(role: kAXWindowRole, title: "W"),
            [0, 0]: AXAttributes(role: kAXButtonRole, title: "First", actionNames: [kAXPressAction]),
            [0, 1]: AXAttributes(role: kAXButtonRole, title: "Second", actionNames: [kAXPressAction]),
            [0, 2]: AXAttributes(role: kAXButtonRole, title: "Third", actionNames: [kAXPressAction]),
        ]
        var elements: [[Int]: AXUIElement] = [:]
        for path in handlePaths { elements[path] = AXUIElementCreateApplication(4242) }
        return LiveElementTree(
            nodes: [window([button("First"), button("Second"), button("Third")])],
            elementsByPath: elements,
            attributesByPath: attributes
        )
    }

    @Test func successActsOnTheRelocatedElementAndPersistsTheNewSession() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            var actedVerb: ActVerb?
            var persisted: Snapshot?
            let outcome = ActPipeline.run(
                ref: "e1", verb: .press, value: nil, json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in true },
                walkLive: { _ in sampleFakeTree(resolving: [[0, 0]]) },
                rewalk: { _ in [window([button("First"), button("Second"), button("Third")])] },
                performAction: { _, verb, _ in actedVerb = verb; return .success(()) },
                persist: { snapshot, _, _, _ in persisted = snapshot },
                sleep: { _ in }
            )
            guard case .acted = outcome else { Issue.record("expected an acted outcome"); return }
            #expect(actedVerb == .press)                 // acted on the located element
            #expect(persisted?.refs["e1"] != nil)        // persisted before rendering
        }
    }

    @Test func relocationMissIsRefError3AndActsOnNothing() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            // The walked tree no longer holds "First" (its window/element is gone);
            // the impostor now at [0,0] must never be pressed.
            let missTree = LiveElementTree(
                nodes: [window([button("Gone")])],
                elementsByPath: [[0, 0]: AXUIElementCreateApplication(4242)],
                attributesByPath: [
                    [0]: AXAttributes(role: kAXWindowRole, title: "W"),
                    [0, 0]: AXAttributes(role: kAXButtonRole, title: "Gone", actionNames: [kAXPressAction]),
                ]
            )
            let outcome = ActPipeline.run(
                ref: "e1", verb: .press, value: nil, json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in true },
                walkLive: { _ in missTree },
                rewalk: { _ in Issue.record("no settle when the element is gone"); return nil },
                performAction: { _, _, _ in Issue.record("must not act on a gone element"); return .success(()) },
                persist: { _, _, _, _ in Issue.record("must not persist a stale ref") },
                sleep: { _ in }
            )
            guard case let .failed(stderr, code) = outcome else { Issue.record("expected failure"); return }
            #expect(code == .refError)
            #expect(stderr.contains("e1"))
        }
    }

    @Test func axActionFailureIsRuntimeError1AndDoesNotPersist() throws {
        try withTempDir { dir in
            let path = try writeSession(sampleSnapshot(), to: dir)
            let outcome = ActPipeline.run(
                ref: "e1", verb: .press, value: nil, json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in true },
                walkLive: { _ in sampleFakeTree(resolving: [[0, 0]]) },
                rewalk: { _ in Issue.record("no settle after an action failure"); return nil },
                performAction: { _, _, _ in .failure(AXActionFailure("button 'First' cannot be pressed.")) },
                persist: { _, _, _, _ in Issue.record("must not persist after an action failure") },
                sleep: { _ in }
            )
            guard case let .failed(stderr, code) = outcome else { Issue.record("expected failure"); return }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("cannot be pressed"))
        }
    }
}
