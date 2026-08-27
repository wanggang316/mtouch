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

private func walked(_ nodes: [AXNode]) -> WalkResult {
    WalkResult(nodes: nodes, fallbackFired: false, fallbackHelped: false, truncated: false)
}

private let testApp = "com.example.App"
private let testPID: pid_t = 4242
private let onPoint = ScreenPoint(x: 100, y: 100)

private struct StubPermissions: PermissionProvider {
    let accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

private func session(for roots: [AXNode], app: String = testApp, pid: pid_t = testPID) -> Session {
    Session(snapshot: Snapshot(roots: roots), app: app, pid: pid)
}

/// Counts every call through the injectable walk seam, so "no walk was performed"
/// is asserted against the seam itself rather than inferred from the output.
private final class WalkCounter {
    private(set) var calls = 0
    var result: WalkResult?

    init(result: WalkResult? = nil) {
        self.result = result
    }

    func walk(_ pid: pid_t) -> WalkResult? {
        calls += 1
        return result
    }
}

/// Records what the pipeline delivered and, optionally, refuses.
private final class KeyRecorder {
    private(set) var actions: [KeyboardAction] = []
    var throwing: Error?

    func deliver(_ pid: pid_t, _ action: KeyboardAction) throws {
        if let throwing { throw throwing }
        actions.append(action)
    }
}

private final class PointerRecorder {
    private(set) var actions: [PointerAction] = []
    var throwing: Error?

    func deliver(_ pid: pid_t, _ action: PointerAction) throws {
        if let throwing { throw throwing }
        actions.append(action)
    }
}

private func failure(_ outcome: ActOutcome) -> (stderr: String, code: MTouchExitCode)? {
    guard case let .failed(stderr, code) = outcome else { return nil }
    return (stderr, code)
}

// MARK: - The notice and the refusals (the mode's contract, in one place)

@Suite struct UnverifiedDeliveryContractTests {
    @Test func theNoticeStatesPlainlyThatNothingWasVerified() {
        // It must read as an ABSENCE of evidence, not as a diff: an agent scanning
        // stdout for what the action did has to be told there is nothing to read.
        #expect(UnverifiedDelivery.notice == "delivered without verification (no accessibility diff was taken)")
        #expect(UnverifiedDelivery.notice.contains("without verification"))
        #expect(UnverifiedDelivery.notice != DiffText.noChangesMarker)
        #expect(UnverifiedDelivery.rendered(json: false) == UnverifiedDelivery.notice)
    }

    @Test func theJSONNoticeCarriesAMachineReadableVerifiedFlag() throws {
        let rendered = UnverifiedDelivery.rendered(json: true)
        #expect(rendered == UnverifiedDelivery.noticeJSON)
        let object = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        let parsed = try #require(object)
        #expect(parsed["verified"] as? Bool == false)
        #expect(parsed["delivered"] as? Bool == true)
        #expect(parsed["note"] as? String == UnverifiedDelivery.notice)
        // A no-verify run must NOT shape like a diff, or a client would parse it as one.
        #expect(parsed["added"] == nil)
    }

    @Test func onlyTheVerbsThatSynthesizeInputAcceptTheFlag() {
        #expect(UnverifiedDelivery.verbs == [
            "type", "key", "click", "rightclick", "doubleclick", "drag", "scroll",
        ])
        for excluded in ["press", "focus", "show-menu", "set-value", "menu"] {
            #expect(!UnverifiedDelivery.verbs.contains(excluded))
        }
    }

    @Test func theRefVerbRefusalNamesTheReasonAndTheVerbsThatDoAcceptIt() {
        let message = UnverifiedDelivery.refVerbRefusal
        #expect(message.contains("--no-verify"))
        for verb in ["press", "focus", "show-menu", "set-value"] {
            #expect(message.contains(verb))
        }
        // WHY, not just "no": the verb resolves its target by reading the tree.
        #expect(message.contains("reading the accessibility tree"))
        // And where to go instead.
        #expect(message.contains("type, key, click, rightclick, doubleclick, drag, scroll"))
    }

    @Test func theMenuRefusalNamesTheReasonAndTheVerbsThatDoAcceptIt() {
        let message = UnverifiedDelivery.menuRefusal
        #expect(message.contains("--no-verify"))
        #expect(message.contains("act menu"))
        #expect(message.contains("menu bar"))
        #expect(message.contains("type, key, click, rightclick, doubleclick, drag, scroll"))
    }
}

// MARK: - Keyboard verbs under --no-verify

@Suite struct ActKeyboardUnverifiedTests {
    @Test func deliversWithoutWalkingAndReportsThatNothingWasVerified() {
        let walker = WalkCounter(result: walked([window([textArea("")])]))
        let recorder = KeyRecorder()
        var persisted = 0

        let outcome = ActPipeline.runKeyboard(
            action: .type("hello"), appOverride: nil, json: false, noVerify: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            rewalk: { walker.walk($0) },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in persisted += 1 },
            sleep: { _ in Issue.record("a no-verify delivery must not settle") }
        )

        #expect(outcome == .deliveredUnverified(UnverifiedDelivery.notice))
        #expect(walker.calls == 0)      // neither the pre-walk nor the post-walk ran
        #expect(persisted == 0)         // nothing was read, so nothing is written back
        #expect(recorder.actions.count == 1)
        if case let .type(text) = recorder.actions.first { #expect(text == "hello") }
        else { Issue.record("expected the text to be delivered") }
    }

    @Test func jsonRendersTheMachineReadableNotice() {
        let walker = WalkCounter()
        let recorder = KeyRecorder()
        let combo = try? KeyCombo(parsing: "cmd+shift+g")

        let outcome = ActPipeline.runKeyboard(
            action: .key(combo!), appOverride: nil, json: true, noVerify: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            rewalk: { walker.walk($0) },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("must not persist") },
            sleep: { _ in }
        )

        #expect(outcome == .deliveredUnverified(UnverifiedDelivery.noticeJSON))
        #expect(walker.calls == 0)
        #expect(recorder.actions.count == 1)
    }

    /// The motivating case: the app's accessibility server is wedged behind a modal
    /// panel, so every walk times out. Without the flag that is exit 1; with it the
    /// SAME wedged target is driven successfully.
    @Test func drivesATargetWhoseTreeCannotBeReadAtAll() {
        let recorder = KeyRecorder()
        let combo = try? KeyCombo(parsing: "escape")
        func run(noVerify: Bool) -> ActOutcome {
            ActPipeline.runKeyboard(
                action: .key(combo!), appOverride: nil, json: false, noVerify: noVerify,
                environment: [:],
                permissions: StubPermissions(accessibility: true),
                loadSession: { _ in session(for: [window([textArea("")])]) },
                isRunning: { _, _ in true },
                rewalk: { _ in nil },  // the accessibility server never answers
                deliver: { try recorder.deliver($0, $1) },
                persist: { _, _, _, _ in },
                sleep: { _ in }
            )
        }

        let refused = run(noVerify: false)
        #expect(failure(refused)?.code == .runtimeFailure)
        #expect(recorder.actions.isEmpty)   // refused BEFORE delivering anything

        let delivered = run(noVerify: true)
        #expect(delivered == .deliveredUnverified(UnverifiedDelivery.notice))
        #expect(recorder.actions.count == 1)
    }

    @Test func secureInputStillRefusesWithTheFlagSet() {
        let secret = "correct horse battery staple 42"
        let walker = WalkCounter()
        let recorder = KeyRecorder()
        recorder.throwing = SecureInputActive()

        let outcome = ActPipeline.runKeyboard(
            action: .type(secret), appOverride: nil, json: false, noVerify: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            rewalk: { walker.walk($0) },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("a refusal must not persist a session") },
            sleep: { _ in }
        )

        // Exit 5 is not a verification guard, so skipping verification never skips it.
        #expect(failure(outcome)?.code == .secureInput)
        #expect(failure(outcome)?.stderr.contains(secret) == false)
        #expect(recorder.actions.isEmpty)
        #expect(walker.calls == 0)
    }

    @Test func missingPermissionIsStillExit2BeforeAnyDelivery() {
        let recorder = KeyRecorder()
        let outcome = ActPipeline.runKeyboard(
            action: .type("hi"), appOverride: nil, json: false, noVerify: true,
            environment: [:],
            permissions: StubPermissions(accessibility: false),
            loadSession: { _ in Issue.record("permission precedes the session"); return nil },
            isRunning: { _, _ in true },
            rewalk: { _ in nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        #expect(failure(outcome)?.code == .permissionMissing)
        #expect(recorder.actions.isEmpty)
    }

    @Test func noTargetIsStillExit3AndProcessGoneIsStillExit1() {
        let recorder = KeyRecorder()
        let noTarget = ActPipeline.runKeyboard(
            action: .type("hi"), appOverride: nil, json: false, noVerify: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in nil },
            isRunning: { _, _ in true },
            rewalk: { _ in nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        #expect(failure(noTarget)?.code == .refError)

        let gone = ActPipeline.runKeyboard(
            action: .type("hi"), appOverride: nil, json: false, noVerify: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in false },
            rewalk: { _ in nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        #expect(failure(gone)?.code == .runtimeFailure)
        #expect(failure(gone)?.stderr.contains("no longer running") == true)
        #expect(recorder.actions.isEmpty)
    }

    /// The contrast, in the same suite as the claim: WITHOUT the flag the very same
    /// call still walks twice and reports a diff.
    @Test func withoutTheFlagBothWalksStillHappenAndADiffIsReported() {
        let pre = [window([textArea("")])]
        let post = [window([textArea("hello")])]
        var walks = 0
        let recorder = KeyRecorder()
        var persisted = 0

        let outcome = ActPipeline.runKeyboard(
            action: .type("hello"), appOverride: nil, json: false,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: pre) },
            isRunning: { _, _ in true },
            rewalk: { _ in
                walks += 1
                return walks == 1 ? walked(pre) : walked(post)
            },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in persisted += 1 },
            sleep: { _ in }
        )

        guard case let .acted(rendered) = outcome else { Issue.record("expected a verified act"); return }
        #expect(rendered.contains("hello"))
        #expect(walks >= 2)
        #expect(persisted == 1)
    }
}

// MARK: - Coordinate verbs under --no-verify

@Suite struct ActCoordinateUnverifiedTests {
    @Test func deliversWithoutWalkingAndReportsThatNothingWasVerified() {
        let walker = WalkCounter(result: walked([window([textArea("")])]))
        let recorder = PointerRecorder()

        let outcome = ActPipeline.runCoordinate(
            action: .click(onPoint), appOverride: nil, json: false, noVerify: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            onScreen: { _ in true },
            rewalk: { walker.walk($0) },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("must not persist") },
            sleep: { _ in Issue.record("a no-verify delivery must not settle") }
        )

        #expect(outcome == .deliveredUnverified(UnverifiedDelivery.notice))
        #expect(walker.calls == 0)
        #expect(recorder.actions == [.click(onPoint)])
    }

    @Test func theOffScreenGuardStillRejectsBeforeDeliveringAnything() {
        let walker = WalkCounter()
        let recorder = PointerRecorder()

        let outcome = ActPipeline.runCoordinate(
            action: .drag(from: onPoint, to: ScreenPoint(x: 99_999, y: 99_999)),
            appOverride: nil, json: false, noVerify: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            onScreen: { $0 == onPoint },
            rewalk: { walker.walk($0) },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )

        // The guard is about the coordinate, not the tree, so skipping verification
        // never skips it: zero events for a point that is nowhere on screen.
        #expect(failure(outcome)?.code == .runtimeFailure)
        #expect(recorder.actions.isEmpty)
        #expect(walker.calls == 0)
    }

    @Test func aDeliveryFailureIsStillARuntimeError() {
        struct Boom: Error {}
        let recorder = PointerRecorder()
        recorder.throwing = Boom()

        let outcome = ActPipeline.runCoordinate(
            action: .scroll(at: onPoint, dy: -300), appOverride: nil, json: false, noVerify: true,
            environment: [:],
            permissions: StubPermissions(accessibility: true),
            loadSession: { _ in session(for: [window([textArea("")])]) },
            isRunning: { _, _ in true },
            onScreen: { _ in true },
            rewalk: { _ in nil },
            deliver: { try recorder.deliver($0, $1) },
            persist: { _, _, _, _ in Issue.record("must not persist") }, sleep: { _ in }
        )
        #expect(failure(outcome)?.code == .runtimeFailure)
    }
}

// MARK: - The actionable timeout diagnostic

@Suite struct ActInputTimeoutDiagnosticTests {
    @Test func namesTheModalPanelCauseAndTheRetryPath() {
        let message = ActPipeline.inputTimeoutDiagnostic(app: testApp, pid: testPID)
        // Everything the old message said is still said.
        #expect(message.hasPrefix(ActPipeline.timeoutDiagnostic(app: testApp, pid: testPID)))
        #expect(message.contains("appears unresponsive"))
        // Plus the way forward, which is what lets an agent self-correct.
        #expect(message.contains("modal panel"))
        #expect(message.contains("--no-verify"))
        #expect(message.contains("type, key, click, rightclick, doubleclick, drag, scroll"))
    }

    @Test func everyVerbThatDeliversInputReportsTheActionableForm() throws {
        let expected = ActPipeline.inputTimeoutDiagnostic(app: testApp, pid: testPID)
        let refs = session(for: [window([textArea("")])])
        let menuPath = try MenuPath(parsing: "File>Save")

        let keyboard = ActPipeline.runKeyboard(
            action: .type("hi"), appOverride: nil, json: false,
            environment: [:], permissions: StubPermissions(accessibility: true),
            loadSession: { _ in refs }, isRunning: { _, _ in true },
            rewalk: { _ in nil }, deliver: { _, _ in },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        #expect(failure(keyboard)?.stderr == expected)

        let coordinate = ActPipeline.runCoordinate(
            action: .click(onPoint), appOverride: nil, json: false,
            environment: [:], permissions: StubPermissions(accessibility: true),
            loadSession: { _ in refs }, isRunning: { _, _ in true },
            onScreen: { _ in true }, rewalk: { _ in nil }, deliver: { _, _ in },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        #expect(failure(coordinate)?.stderr == expected)

        let menu = ActPipeline.runMenu(
            path: menuPath, appOverride: nil, json: false,
            environment: [:], permissions: StubPermissions(accessibility: true),
            loadSession: { _ in refs }, isRunning: { _, _ in true },
            activate: { _ in }, rewalk: { _ in nil },
            invoke: { _, _ in Issue.record("must not invoke without a baseline"); return .success(()) },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        #expect(failure(menu)?.stderr == expected)
    }

    /// `read` never delivers input, so pointing it at `--no-verify` would send an
    /// agent to a flag its command does not have.
    @Test func aReadKeepsThePlainReport() {
        #expect(!ActPipeline.timeoutDiagnostic(app: testApp, pid: testPID).contains("--no-verify"))
        #expect(!ReadPipeline.appTimeoutDiagnostic(app: testApp, pid: testPID).contains("--no-verify"))
    }
}

// MARK: - Trajectory: an unverified delivery is marked as such

@Suite struct UnverifiedTrajectoryTests {
    @Test func theOutcomeMapsToADedicatedVerifiedFieldAndNoDiff() {
        let unverified = ActOutcome.deliveredUnverified(UnverifiedDelivery.notice).trajectoryInfo
        #expect(unverified.ok)
        #expect(unverified.exit == 0)
        #expect(unverified.verified == false)
        // The notice is NOT a diff and must never be recorded as one.
        #expect(unverified.diff == nil)

        // A verified act is unchanged: it carries its diff and makes no claim in
        // the new field (absence ⇒ the ordinary, verified contract held).
        let verified = ActOutcome.acted("~ e1 AXTextArea \"hi\"").trajectoryInfo
        #expect(verified.diff == "~ e1 AXTextArea \"hi\"")
        #expect(verified.verified == nil)
    }

    @Test func theRecordCarriesVerifiedFalseAndNoDiff() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtouch-unverified-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let trajectory = dir.appendingPathComponent("t.jsonl").path
        let environment = [
            "MTOUCH_TRAJECTORY": trajectory,
            "MTOUCH_SESSION": dir.appendingPathComponent("s.json").path,
        ]

        _ = try TrajectoryRecorder.record(
            command: "act",
            args: TrajectoryArgs.build([
                "verb": .string("key"), "combo": .string("escape"), "noVerify": .bool(true),
            ]),
            kind: .action,
            environment: environment,
            operation: { ActOutcome.deliveredUnverified(UnverifiedDelivery.notice) },
            describe: { $0.trajectoryInfo }
        )

        let content = try String(contentsOf: URL(fileURLWithPath: trajectory), encoding: .utf8)
        let line = try #require(content.split(separator: "\n").first)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let record = try #require(object)

        // The dedicated field an agent keys off — not a prose hint inside a diff.
        #expect(record["verified"] as? Bool == false)
        #expect(record["diff"] == nil)
        let outcome = try #require(record["outcome"] as? [String: Any])
        #expect(outcome["ok"] as? Bool == true)
        #expect(outcome["exit"] as? Int32 == 0)
        // The request that produced it is recorded too, so the record is self-explaining.
        let args = try #require(record["args"] as? [String: Any])
        #expect(args["noVerify"] as? Bool == true)
    }

    @Test func theMCPSurfaceMarksItsOwnUnverifiedDeliveriesToo() {
        let payload = ToolResult.text(UnverifiedDelivery.notice)
        let unverified = payload.trajectoryInfo(kind: .action, unverified: true)
        #expect(unverified.verified == false)
        #expect(unverified.diff == nil)   // the notice is not a diff

        // Unchanged for an ordinary action: the text IS the diff, and no claim is made.
        let verified = ToolResult.text("+ e2 AXButton \"B\"").trajectoryInfo(kind: .action)
        #expect(verified.diff == "+ e2 AXButton \"B\"")
        #expect(verified.verified == nil)
    }
}

// MARK: - MCP parity: the same flag, the same refusals, the same payload

@Suite struct MCPUnverifiedActTests {
    private func act(_ args: [String: ToolArgumentValue]) -> ToolResult {
        MCPToolDispatch.dispatch(
            tool: "act", arguments: ToolArguments(args), environment: [:],
            permissions: StubPermissions(accessibility: false)
        )
    }

    private func text(_ result: ToolResult) -> String? {
        for payload in result.payloads {
            if case let .text(value) = payload { return value }
        }
        return nil
    }

    @Test(arguments: ["press", "focus", "show-menu", "set-value"])
    func refVerbsRefuseTheFlagWithTheCLIsWording(_ verb: String) {
        let result = act(["verb": .string(verb), "ref": .string("e1"), "noVerify": .bool(true)])
        #expect(result.isError)
        #expect(text(result) == "mtouch: invalid arguments: " + UnverifiedDelivery.refVerbRefusal)
    }

    @Test func menuRefusesTheFlagWithTheCLIsWording() {
        let result = act(["verb": .string("menu"), "path": .string("File>Save"), "noVerify": .bool(true)])
        #expect(result.isError)
        #expect(text(result) == "mtouch: invalid arguments: " + UnverifiedDelivery.menuRefusal)
    }

    /// The refusal outranks a missing payload: it is decided from the flag alone,
    /// exactly as the CLI decides it at parse time.
    @Test func theRefusalPrecedesTheMissingArgumentCheck() {
        let result = act(["verb": .string("press"), "noVerify": .bool(true)])
        #expect(text(result) == "mtouch: invalid arguments: " + UnverifiedDelivery.refVerbRefusal)
    }

    /// An input verb still reaches the pipeline, where the pinned precedence puts
    /// the permission gate (2) ahead of everything the flag touches.
    @Test func inputVerbsCarryTheFlagIntoThePipeline() {
        let result = act(["verb": .string("key"), "combo": .string("escape"), "noVerify": .bool(true)])
        #expect(result.isError)
        #expect(text(result)?.contains("Accessibility") == true)
    }

    @Test func theToolAdvertisesTheFlagWithoutChangingTheToolSet() throws {
        #expect(MCPToolCatalog.tools.count == 10)
        let spec = try #require(MCPToolCatalog.tools.first { $0.name == "act" })
        let property = try #require(spec.properties.first { $0.name == "noVerify" })
        #expect(property.type == "boolean")
        // Optional: adding it must not change what a client MUST send.
        #expect(spec.required == ["verb"])
        // The description says what is traded away, and which verbs may trade it.
        #expect(property.description.contains("NOT verified"))
        #expect(property.description.contains("type, key, click, rightclick, doubleclick, drag, scroll"))
    }
}
