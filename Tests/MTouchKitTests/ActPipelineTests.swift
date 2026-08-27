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

/// Wrap a walked tree (optionally with per-root window ids) as a `WalkResult` —
/// the shape `rewalk` now yields so the post-action reconcile sees owning-window
/// ids. Defaults to no ids, preserving the single-window fixtures' behaviour.
private func walked(_ nodes: [AXNode], windowIDs: [[Int]: CGWindowID] = [:]) -> WalkResult {
    WalkResult(nodes: nodes, windowIDsByPath: windowIDs,
               fallbackFired: false, fallbackHelped: false, truncated: false)
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

/// Deterministic virtual clock shared by `now`/`sleep`, so the settle's timing —
/// how long it waited, and how long it was allowed to — is asserted with no wall
/// time at all. Time advances ONLY when the code under test sleeps.
private final class Clock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
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
    /// The pre tree every case below diffs against.
    private func pre() -> Snapshot { Snapshot(roots: [window([button("A")])]) }

    /// A tree distinguishable from every other `changed(n)` — so "which walk did the
    /// reported diff come from" is answerable from the diff itself.
    private func changed(_ label: String) -> [AXNode] {
        [window([button("A"), button(label)])]
    }

    /// THE FIX. The first walk after an action routinely catches the interface
    /// mid-render, so the first NON-EMPTY diff is not the action's effect — measured
    /// against a real application it reported a half-typed value, and sometimes a
    /// wholly unrelated element. The settle therefore returns the first reading that
    /// REPEATS across two consecutive walks, and nothing earlier.
    @Test func settleReturnsTheFirstReadingThatRepeats() {
        let clock = Clock()
        var calls = 0
        var sleeps = 0
        let result = ActPipeline.settledDiff(
            pre: pre(), pid: 1, expectsMenu: false,
            rewalk: { _ in
                calls += 1
                // Two different mid-render readings, then one that holds still.
                return walked(changed(["B", "C", "D", "D"][min(calls, 4) - 1]))
            },
            now: clock.now,
            sleep: { clock.sleep($0); sleeps += 1 }
        )
        #expect(result.settled)
        #expect(calls == 4)                      // stopped at the repeat, not before
        #expect(sleeps == 3)
        // The REPEATED reading is what is reported — never "B", the first non-empty
        // diff, which is exactly what the old loop returned.
        #expect(result.reading.diff.added.map(\.node.title) == ["D"])
    }

    /// An immediately-stable change costs the minimum a repeat can be observed in —
    /// two walks and one interval — and not one walk more.
    @Test func anImmediatelyStableReadingReturnsAtTheSecondWalk() {
        let clock = Clock()
        var calls = 0
        var sleeps = 0
        let result = ActPipeline.settledDiff(
            pre: pre(), pid: 1, expectsMenu: false,
            rewalk: { _ in calls += 1; return walked(changed("B")) },
            now: clock.now,
            sleep: { clock.sleep($0); sleeps += 1 }
        )
        #expect(result.settled)
        #expect(calls == 2)
        #expect(sleeps == 1)
        #expect(clock.time == SettleBudget.standard.interval)
        #expect(result.reading.diff.added.count == 1)
    }

    /// A reading that never holds still cannot be reported as the action's effect.
    /// The budget expires, the MOST RECENT reading is returned — it is the closest
    /// thing to the truth, and the snapshot persisted alongside it comes from that
    /// same walk — and it is marked as not settled.
    @Test func aReadingThatNeverRepeatsExpiresUnsettledWithTheLatestObservation() {
        let clock = Clock()
        var calls = 0
        let result = ActPipeline.settledDiff(
            pre: pre(), pid: 1, expectsMenu: false,
            rewalk: { _ in calls += 1; return walked(changed("v\(calls)")) },
            now: clock.now, sleep: clock.sleep
        )
        #expect(!result.settled)
        #expect(calls > 2)
        #expect(result.reading.diff.added.map(\.node.title) == ["v\(calls)"])
        // Bounded: the whole settle stayed inside its budget, never running on
        // indefinitely against an interface that never sits still.
        #expect(clock.time <= SettleBudget.standard.deadline + SettleBudget.standard.interval)
    }

    /// An EMPTY diff never ends the loop early: "nothing has changed yet" is exactly
    /// the state a slow sheet or window is in on its way to appearing. The settle
    /// keeps walking and reports the change once it holds still.
    @Test func anEmptyReadingKeepsWaitingForALateChange() {
        let clock = Clock()
        var calls = 0
        let result = ActPipeline.settledDiff(
            pre: pre(), pid: 1, expectsMenu: false,
            rewalk: { _ in
                calls += 1
                return calls <= 5 ? walked([window([button("A")])]) : walked(changed("Late"))
            },
            now: clock.now, sleep: clock.sleep
        )
        #expect(result.settled)
        #expect(calls == 7)                      // 5 empty, then seen and confirmed
        #expect(result.reading.diff.added.map(\.node.title) == ["Late"])
    }

    /// A genuine no-op spends its budget (the change might still be coming) and then
    /// reports "(no changes)" as a SETTLED fact: every walk agreed the tree still
    /// equals the pre tree, which is proof rather than a guess.
    @Test func aGenuineNoOpExpiresSettledWithNoChanges() {
        let clock = Clock()
        var calls = 0
        let result = ActPipeline.settledDiff(
            pre: pre(), pid: 1, expectsMenu: false,
            rewalk: { _ in calls += 1; return walked([window([button("A")])]) },
            now: clock.now, sleep: clock.sleep
        )
        #expect(result.settled)
        #expect(result.reading.diff.isEmpty)
        #expect(calls > 2)                       // waited rather than answering at once
        #expect(DiffText.render(result.reading.diff, settled: result.settled)
            == DiffText.noChangesMarker)
    }

    /// Every walk timed out, so nothing was observed at all. The fallback reading is
    /// still "(no changes)", but claiming it SETTLED would be a lie — nothing was
    /// read to settle.
    @Test func settleFallsBackToAnUnsettledNoChangesWhenEveryWalkFails() {
        let clock = Clock()
        let result = ActPipeline.settledDiff(
            pre: pre(), pid: 1, expectsMenu: false,
            rewalk: { _ in nil }, now: clock.now, sleep: clock.sleep
        )
        #expect(result.reading.diff.isEmpty)
        #expect(!result.settled)
    }

    /// A walk that fails BETWEEN two identical walks observed nothing, so it is not
    /// evidence of a settled tree: it restarts the quiet window, exactly as it does
    /// for `wait --stable`.
    @Test func aFailedWalkRestartsTheQuietWindow() {
        let clock = Clock()
        var calls = 0
        let result = ActPipeline.settledDiff(
            pre: pre(), pid: 1, expectsMenu: false,
            rewalk: { _ in
                calls += 1
                return calls == 2 ? nil : walked(changed("B"))
            },
            now: clock.now, sleep: clock.sleep
        )
        #expect(result.settled)
        // Walk 1 saw it, walk 2 failed (window restarted), walks 3 and 4 agree.
        #expect(calls == 4)
    }

    /// A menu-opening verb gets the longer budget, because the `AXMenu` it opens
    /// only becomes walkable once it reports a real frame.
    @Test func aMenuVerbSettlesOnTheLongerBudget() {
        let clock = Clock()
        var calls = 0
        _ = ActPipeline.settledDiff(
            pre: pre(), pid: 1, expectsMenu: true,
            rewalk: { _ in calls += 1; return walked(changed("v\(calls)")) },
            now: clock.now, sleep: clock.sleep
        )
        #expect(clock.time > SettleBudget.standard.deadline)
        #expect(clock.time <= SettleBudget.menu.deadline + SettleBudget.menu.interval)
    }

    /// The quiet window is shorter than the poll interval BY CONSTRUCTION, which is
    /// what makes the time-based quiescence rule mean "identical on two consecutive
    /// walks" here rather than "identical for a while".
    @Test func theQuietWindowIsShorterThanThePollInterval() {
        #expect(SettleBudget.standard.window < SettleBudget.standard.interval)
        #expect(SettleBudget.menu.window < SettleBudget.menu.interval)
    }
}

// MARK: - Rendering an unsettled reading (stdout + --json)

@Suite struct UnsettledDiffRenderingTests {
    private func sampleDiff() -> Diff {
        DiffEngine.diff(
            pre: Snapshot(roots: [window([button("A")])]),
            post: [window([button("A"), button("B")])]
        ).diff
    }

    @Test func textLeadsWithTheMarkerAndKeepsTheDiffBodyByteIdentical() {
        let diff = sampleDiff()
        let settled = DiffText.render(diff)
        let unsettled = DiffText.render(diff, settled: false)

        #expect(settled == DiffText.render(diff, settled: true))
        #expect(unsettled == DiffText.unsettledMarker + "\n" + settled)
        // The marker is parenthesized like "(no changes)", so it can never be read
        // as one of the +/-/~ diff lines.
        #expect(DiffText.unsettledMarker.hasPrefix("("))
        #expect(unsettled.contains("snapshot"))     // says how to get a real reading
    }

    @Test func anUnsettledNoChangesStillSaysNoChanges() {
        let empty = Diff(added: [], removed: [], changed: [], staleRefs: [])
        let rendered = DiffText.render(empty, settled: false)
        #expect(rendered == DiffText.unsettledMarker + "\n" + DiffText.noChangesMarker)
    }

    @Test func jsonAddsSettledFalseAndOtherwiseStaysByteIdentical() {
        let diff = sampleDiff()
        let settled = DiffJSON.render(diff)
        let unsettled = DiffJSON.render(diff, settled: false)

        // A settled diff is byte-for-byte what this always emitted: the field's
        // ABSENCE keeps meaning "the ordinary contract held".
        #expect(!settled.contains("settled"))
        #expect(unsettled == String(settled.dropLast()) + ",\"settled\":false}")
    }

    @Test func theFreeFunctionsForwardTheFlag() {
        let diff = sampleDiff()
        #expect(renderDiffText(diff, settled: false) == DiffText.render(diff, settled: false))
        #expect(renderDiffJSON(diff, settled: false) == DiffJSON.render(diff, settled: false))
        #expect(renderDiffText(diff) == DiffText.render(diff))
        #expect(renderDiffJSON(diff) == DiffJSON.render(diff))
    }
}

// MARK: - An unsettled reading reaches every surface as its own fact

@Suite struct UnsettledActOutcomeTests {
    private let app = "com.example.App"
    private let pid: pid_t = 4242

    private func liveSession() -> Session {
        Session(snapshot: Snapshot(roots: [window([button("A")])]), app: app, pid: pid)
    }

    /// A verb whose interface never holds still reports `.actedUnsettled`, not
    /// `.acted`: the diff is real, but it is not the finished effect, and no
    /// consumer may reach the payload without learning that.
    private func runNeverSettling(json: Bool, persist: @escaping (Snapshot) -> Void = { _ in })
        -> ActOutcome {
        let clock = Clock()
        var walks = 0
        return ActPipeline.runKeyboard(
            action: .type("hi"), appOverride: nil, json: json,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in liveSession() },
            isRunning: { _, _ in true },
            rewalk: { _ in
                walks += 1
                // The pre-walk baseline, then a tree that changes on every read.
                return walks == 1
                    ? walked([window([button("A")])])
                    : walked([window([button("A"), button("v\(walks)")])])
            },
            deliver: { _, _ in },
            persist: { snapshot, _, _, _ in persist(snapshot) },
            now: clock.now, sleep: clock.sleep
        )
    }

    @Test func aVerbWhoseReadingNeverSettlesReportsItOnStdout() {
        var persisted: Snapshot?
        let outcome = runNeverSettling(json: false, persist: { persisted = $0 })
        guard case let .actedUnsettled(rendered) = outcome else {
            Issue.record("expected an unsettled act, got \(outcome)"); return
        }
        #expect(rendered.hasPrefix(DiffText.unsettledMarker))
        #expect(rendered.contains("+ "))            // the diff it DID read is still there
        // The session is still written — from the same walk the diff came from — so a
        // ref an agent reads about is a ref it can act on next.
        #expect(persisted != nil)
    }

    @Test func theJSONFormCarriesSettledFalse() throws {
        let outcome = runNeverSettling(json: true)
        guard case let .actedUnsettled(rendered) = outcome else {
            Issue.record("expected an unsettled act, got \(outcome)"); return
        }
        let object = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        let parsed = try #require(object)
        #expect(parsed["settled"] as? Bool == false)
        #expect((parsed["added"] as? [Any])?.isEmpty == false)
    }

    /// A settled verb is completely unchanged — same case, same bytes, no new field.
    @Test func aSettledVerbIsUntouched() {
        let clock = Clock()
        var walks = 0
        let outcome = ActPipeline.runKeyboard(
            action: .type("hi"), appOverride: nil, json: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in liveSession() },
            isRunning: { _, _ in true },
            rewalk: { _ in
                walks += 1
                return walks == 1
                    ? walked([window([button("A")])])
                    : walked([window([button("A"), button("B")])])
            },
            deliver: { _, _ in },
            persist: { _, _, _, _ in },
            now: clock.now, sleep: clock.sleep
        )
        guard case let .acted(rendered) = outcome else {
            Issue.record("expected a settled act, got \(outcome)"); return
        }
        #expect(!rendered.contains("settled"))
    }

    @Test func theOutcomeMapsToSettledFalseWhileKeepingItsDiff() {
        let unsettled = ActOutcome.actedUnsettled("~ e1 AXTextArea \"h\"").trajectoryInfo
        #expect(unsettled.settled == false)
        // Unlike the unverified/unconfirmed cases, a reading WAS taken, so the diff
        // is recorded — it is the only evidence there is.
        #expect(unsettled.diff == "~ e1 AXTextArea \"h\"")
        // It says nothing about delivery or verification, which are separate facts.
        #expect(unsettled.verified == nil)
        #expect(unsettled.deliveryConfirmed == nil)

        // A settled act claims nothing at all.
        #expect(ActOutcome.acted("~ e1 AXTextArea \"hi\"").trajectoryInfo.settled == nil)
        #expect(ActOutcome.deliveredUnverified(UnverifiedDelivery.notice).trajectoryInfo.settled == nil)
    }

    @Test func theRecordCarriesSettledFalseAlongsideTheDiff() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtouch-unsettled-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let trajectory = dir.appendingPathComponent("t.jsonl").path
        _ = try TrajectoryRecorder.record(
            command: "act",
            args: TrajectoryArgs.build(["verb": .string("type"), "text": .string("hi")]),
            kind: .action,
            environment: [
                "MTOUCH_TRAJECTORY": trajectory,
                "MTOUCH_SESSION": dir.appendingPathComponent("s.json").path,
            ],
            operation: { ActOutcome.actedUnsettled("~ e1 AXTextArea \"h\"") },
            describe: { $0.trajectoryInfo }
        )

        let content = try String(contentsOf: URL(fileURLWithPath: trajectory), encoding: .utf8)
        let line = try #require(content.split(separator: "\n").first)
        let record = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(record["settled"] as? Bool == false)
        #expect(record["diff"] as? String == "~ e1 AXTextArea \"h\"")
        // Distinct from the other two honesty fields, which make different claims.
        #expect(record["verified"] == nil)
        #expect(record["deliveryConfirmed"] == nil)
        let outcome = try #require(record["outcome"] as? [String: Any])
        #expect(outcome["ok"] as? Bool == true)
        #expect(outcome["exit"] as? Int32 == 0)
    }

    @Test func theMCPSurfaceMarksItsOwnUnsettledReadingsToo() {
        let payload = ToolResult(payloads: [.text("~ e1 AXTextArea \"h\"")], isError: false, settled: false)
        let info = payload.trajectoryInfo(kind: .action)
        #expect(info.settled == false)
        #expect(info.diff == "~ e1 AXTextArea \"h\"")   // the reading survives
        #expect(info.verified == nil)

        // Unchanged for an ordinary action.
        let settled = ToolResult.text("+ e2 AXButton \"B\"").trajectoryInfo(kind: .action)
        #expect(settled.settled == nil)
        #expect(settled.diff == "+ e2 AXButton \"B\"")
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

// MARK: - Owning-window identity by CGWindowID (VAL-ACT-011 round 2)
// The airtight regression the title-based ancestor chain could NOT cover: two
// UNTITLED windows share the title `未命名`, so their ancestor chains are
// identical and only the stable, unique CGWindowID tells them apart.

@Suite struct ElementRelocationWindowIdentityTests {
    private func attrs(_ role: String, subrole: String? = nil, title: String? = nil) -> AXAttributes {
        AXAttributes(role: role, subrole: subrole, title: title)
    }

    /// Localized "Untitled": BOTH untitled TextEdit windows carry this EXACT title,
    /// so a title-based ancestor chain is identical across them.
    private let untitled = "未命名"

    /// A LOW popup-button ref (e.g. e7) owned by an untitled window whose unique id
    /// is `windowID`. Its own hints and its window-titled ancestor chain are
    /// IDENTICAL to the twin in the sibling window; only `ownerWindowID` differs.
    private func popupRef(path: [Int], windowID: CGWindowID?) -> RefEntry {
        RefEntry(
            node: AXNode(role: kAXPopUpButtonRole, actionable: true),
            ref: "e7", path: path,
            ancestors: [NodeHint(role: kAXWindowRole, subrole: "AXStandardWindow", title: untitled)],
            ownerWindowID: windowID
        )
    }

    /// Two untitled windows, each with one popup button; every hint AND the window
    /// title is identical — only the CGWindowID differs (front 4001, back 4002).
    private func twoUntitledWindows() -> (attrs: [[Int]: AXAttributes], ids: [[Int]: CGWindowID]) {
        let attributes: [[Int]: AXAttributes] = [
            [0]: attrs(kAXWindowRole, subrole: "AXStandardWindow", title: untitled),
            [0, 0]: attrs(kAXPopUpButtonRole),
            [1]: attrs(kAXWindowRole, subrole: "AXStandardWindow", title: untitled),
            [1, 0]: attrs(kAXPopUpButtonRole),
        ]
        let ids: [[Int]: CGWindowID] = [[0]: 4001, [0, 0]: 4001, [1]: 4002, [1, 0]: 4002]
        return (attributes, ids)
    }

    @Test func windowIDDisambiguatesTwoIdenticallyTitledWindows() {
        // Both untitled windows present. The ancestor chain is IDENTICAL, so round 1
        // could not tell them apart; the window id does — each ref resolves to ITS
        // OWN popup, never the twin's.
        let (attributes, ids) = twoUntitledWindows()
        #expect(ElementRelocation.locatePath(
            popupRef(path: [0, 0], windowID: 4001), in: attributes, windowIDsByPath: ids
        ) == [0, 0])
        #expect(ElementRelocation.locatePath(
            popupRef(path: [1, 0], windowID: 4002), in: attributes, windowIDsByPath: ids
        ) == [1, 0])
    }

    @Test func frontWindowClosedSlidesTwinIn_lowRefIsStaleNotMisdelivered() {
        // THE regression. A LOW ref (e7) recorded on the FRONT untitled window
        // (id 4001) at [0,0]. The front window closes; the BACK untitled window
        // (id 4002) slides into root index 0, so a structurally-identical popup —
        // same hints, SAME title `未命名`, so an IDENTICAL ancestor chain — now
        // sits at [0,0]. Title-based identity would accept it (the round-1 hole);
        // the differing window id rejects it -> STALE (nil). Nothing is acted on in
        // the surviving window (no menu/popover opens there).
        let afterClose: [[Int]: AXAttributes] = [
            [0]: attrs(kAXWindowRole, subrole: "AXStandardWindow", title: untitled),
            [0, 0]: attrs(kAXPopUpButtonRole),
        ]
        let ids: [[Int]: CGWindowID] = [[0]: 4002, [0, 0]: 4002]
        #expect(ElementRelocation.locatePath(
            popupRef(path: [0, 0], windowID: 4001), in: afterClose, windowIDsByPath: ids
        ) == nil)
    }

    @Test func movedLowRefResolvesToItsOwnWindowAmongIdenticalTwins() {
        // The popup shifted off its recorded path and BOTH untitled windows still
        // hold a same-hint popup. Hint + ancestor matching alone is ambiguous (two
        // identical-title candidates), so round 1 would give up (stale). The window
        // id filters to the ONE popup in the ref's own window (4001).
        let (attributes, ids) = twoUntitledWindows()
        #expect(ElementRelocation.locatePath(
            popupRef(path: [9, 9], windowID: 4001), in: attributes, windowIDsByPath: ids
        ) == [0, 0])
    }

    @Test func genuineSurvivorInItsOwnWindowStillResolves() {
        // The front (id 4001) window survived unchanged; only the back closed. The
        // ref must still resolve at its path — the window gate must not over-reject
        // a true survivor.
        let survived: [[Int]: AXAttributes] = [
            [0]: attrs(kAXWindowRole, subrole: "AXStandardWindow", title: untitled),
            [0, 0]: attrs(kAXPopUpButtonRole),
        ]
        let ids: [[Int]: CGWindowID] = [[0]: 4001, [0, 0]: 4001]
        #expect(ElementRelocation.locatePath(
            popupRef(path: [0, 0], windowID: 4001), in: survived, windowIDsByPath: ids
        ) == [0, 0])
    }

    @Test func olderSessionWithoutWindowIDDegradesToAncestorPositional() {
        // A ref persisted before window ids existed carries ownerWindowID == nil.
        // The window gate must not reject it (no id to compare) — it resolves by
        // ancestor/position exactly as a round-1 session would, so upgrading the
        // tool never bricks a live session.
        let (attributes, ids) = twoUntitledWindows()
        #expect(ElementRelocation.locatePath(
            popupRef(path: [0, 0], windowID: nil), in: attributes, windowIDsByPath: ids
        ) == [0, 0])
    }
}

// MARK: - LiveElementTree window-id seam

@Suite struct LiveElementTreeWindowIDTests {
    @Test func memberwiseInitCarriesTheWindowIDMap() {
        let tree = LiveElementTree(
            nodes: [], elementsByPath: [:], attributesByPath: [:],
            windowIDsByPath: [[0]: 5501, [0, 0]: 5501]
        )
        #expect(tree.windowIDsByPath == [[0]: 5501, [0, 0]: 5501])
    }

    @Test func memberwiseInitDefaultsToNoWindowIDs() {
        let tree = LiveElementTree(nodes: [], elementsByPath: [:], attributesByPath: [:])
        #expect(tree.windowIDsByPath.isEmpty)
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
            let clock = Clock()
            var actedVerb: ActVerb?
            var persisted: Snapshot?
            let outcome = ActPipeline.run(
                ref: "e1", verb: .press, value: nil, json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in true },
                walkLive: { _ in sampleFakeTree(resolving: [[0, 0]]) },
                rewalk: { _ in walked([window([button("First"), button("Second"), button("Third")])]) },
                performAction: { _, verb, _ in actedVerb = verb; return .success(()) },
                persist: { snapshot, _, _, _ in persisted = snapshot },
                now: clock.now, sleep: clock.sleep
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
