import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

/// A calculator-style keypad button: NO title, labelled only by its localized
/// accessibility description and its stable developer identifier — the exact
/// shape that motivated criteria addressing.
private func keypadButton(_ description: String, id identifier: String) -> AXNode {
    AXNode(
        role: kAXButtonRole, description: description, identifier: identifier,
        frame: CGRect(x: 0, y: 0, width: 40, height: 40), actionable: true
    )
}

private func window(_ children: [AXNode], title: String = "W") -> AXNode {
    AXNode(role: kAXWindowRole, title: title, frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

private struct StubPermissions: PermissionProvider {
    let accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

/// Deterministic virtual clock shared by `now`/`sleep` (mirrors ActPipelineTests).
private final class Clock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
}

private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-act-criteria-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

// MARK: - Target grammar (exactly one of <ref> / --of; --of requires --app)

@Suite struct ActTargetGrammarTests {
    @Test func refAndOfTogetherIsRefused() {
        let message = ActTargetGrammar.selectionError(ref: "e5", of: "button \"Seven\"", app: "com.example.App")
        #expect(message?.contains("cannot be combined") == true)
        #expect(message?.contains("--of") == true)
    }

    @Test func neitherTargetIsRefusedNamingBothModes() {
        let message = ActTargetGrammar.selectionError(ref: nil, of: nil, app: nil)
        #expect(message?.contains("exactly one target") == true)
        // The message names BOTH modes, so an agent that only knew refs learns
        // the criteria mode exists from the refusal itself.
        #expect(message?.contains("<ref>") == true)
        #expect(message?.contains("--of") == true)
    }

    @Test func ofWithoutAppIsRefused() {
        let message = ActTargetGrammar.selectionError(ref: nil, of: "button \"Seven\"", app: nil)
        #expect(message?.contains("--of requires --app") == true)
    }

    @Test func emptyOfIsRefused() {
        #expect(ActTargetGrammar.selectionError(ref: nil, of: "   ", app: "com.example.App")?
            .contains("non-empty criteria") == true)
    }

    @Test func validSelectionsPass() {
        #expect(ActTargetGrammar.selectionError(ref: "e5", of: nil, app: nil) == nil)
        // --app beside a ref stays accepted, exactly as before this feature.
        #expect(ActTargetGrammar.selectionError(ref: "e5", of: nil, app: "com.example.App") == nil)
        #expect(ActTargetGrammar.selectionError(ref: nil, of: "button \"Seven\"", app: "com.example.App") == nil)
    }

    /// In `--of` mode set-value's payload arrives in the ref slot (the parser
    /// fills positionals in order); the shift returns it to the value slot.
    @Test func setValuePayloadShiftsOutOfTheRefSlotInOfMode() {
        let (ref, value) = ActTargetGrammar.normalizedPositionals(
            ref: "42", value: nil, of: "textfield \"Name\"", consumesValue: true
        )
        #expect(ref == nil)
        #expect(value == "42")
    }

    /// A verb that consumes no value must NOT reinterpret its positional: a ref
    /// beside --of is a conflict to refuse, never a payload.
    @Test func nonValueVerbsDoNotShiftTheirPositional() {
        let (ref, value) = ActTargetGrammar.normalizedPositionals(
            ref: "e5", value: nil, of: "button \"Seven\"", consumesValue: false
        )
        #expect(ref == "e5")
        #expect(value == nil)
        #expect(ActTargetGrammar.selectionError(ref: ref, of: "button \"Seven\"", app: "a")?
            .contains("cannot be combined") == true)
    }

    @Test func twoPositionalsBesideOfStayARefConflict() {
        // `set-value e5 42 --of ...`: the payload slot is already taken, so the
        // first positional is a ref and the combination is refused.
        let (ref, value) = ActTargetGrammar.normalizedPositionals(
            ref: "e5", value: "42", of: "textfield \"Name\"", consumesValue: true
        )
        #expect(ref == "e5")
        #expect(value == "42")
        #expect(ActTargetGrammar.selectionError(ref: ref, of: "textfield \"Name\"", app: "a") != nil)
    }

    @Test func refModeWithoutOfIsUntouchedByTheShift() {
        let (ref, value) = ActTargetGrammar.normalizedPositionals(
            ref: "e5", value: "42", of: nil, consumesValue: true
        )
        #expect(ref == "e5")
        #expect(value == "42")
    }

    @Test func makeModeBuildsTheParsedCriteria() {
        #expect(ActTargetGrammar.makeMode(ref: "e5", of: nil, app: nil) == .ref("e5"))
        let mode = ActTargetGrammar.makeMode(ref: nil, of: "button \"Seven\"", app: "com.example.App")
        #expect(mode == .criteria(
            app: "com.example.App",
            criteria: WaitCriteria(role: kAXButtonRole, substring: "Seven")
        ))
    }
}

// MARK: - Selection (exactly-one-actionable; the wait/read matcher, unchanged)

@Suite struct ActCriteriaSelectionTests {
    /// The calculator shape: buttons labelled by description + identifier only,
    /// plus a non-actionable display and static text.
    private func keypad() -> [AXNode] {
        [window([
            AXNode(role: kAXScrollAreaRole, description: "编辑字段", isScrollArea: true,
                   children: [AXNode(role: kAXStaticTextRole, value: "0")]),
            keypadButton("7", id: "Seven"),
            keypadButton("乘", id: "Multiply"),
            keypadButton("等于", id: "Equals"),
        ])]
    }

    @Test func identifierMatchSelectsTheSingleButton() {
        let verdict = ActCriteriaSelection.select(WaitCriteria(parsing: #"button "Multiply""#), in: keypad())
        guard case let .one(match) = verdict else {
            Issue.record("expected one match, got \(verdict)"); return
        }
        #expect(match.path == [0, 2])
        #expect(match.node.identifier == "Multiply")
    }

    @Test func localizedCJKDescriptionMatchSelectsTheSingleButton() {
        let verdict = ActCriteriaSelection.select(WaitCriteria(parsing: #"button "乘""#), in: keypad())
        guard case let .one(match) = verdict else {
            Issue.record("expected one match, got \(verdict)"); return
        }
        #expect(match.path == [0, 2])
    }

    @Test func descriptionMatchSelectsTheSingleButton() {
        let verdict = ActCriteriaSelection.select(WaitCriteria(parsing: #"button "等于""#), in: keypad())
        guard case let .one(match) = verdict else {
            Issue.record("expected one match, got \(verdict)"); return
        }
        #expect(match.path == [0, 3])
    }

    @Test func bareRoleOverAKeypadIsAmbiguousInDocumentOrder() {
        let verdict = ActCriteriaSelection.select(WaitCriteria(parsing: "button"), in: keypad())
        guard case let .ambiguous(matches) = verdict else {
            Issue.record("expected ambiguity, got \(verdict)"); return
        }
        #expect(matches.map(\.path) == [[0, 1], [0, 2], [0, 3]])
    }

    @Test func noMatchAtAllIsNoneWithZeroNonActionable() {
        let verdict = ActCriteriaSelection.select(WaitCriteria(parsing: #"button "Eight""#), in: keypad())
        #expect(verdict == .none(nonActionable: 0))
    }

    /// A criteria that matches only inert elements is a zero-match for act — but
    /// the count travels so the diagnostic can say "matched N non-actionable
    /// element(s)" instead of "no such element".
    @Test func nonActionableOnlyMatchesAreCountedNotSelected() {
        let verdict = ActCriteriaSelection.select(WaitCriteria(parsing: #"scrollarea "编辑字段""#), in: keypad())
        #expect(verdict == .none(nonActionable: 1))
    }

    /// Unlike `ReadSelection` (outermost-match-wins), selection descends INTO a
    /// match: the single actionable element may sit inside a matching inert
    /// container, and skipping the subtree would report "nothing actionable".
    @Test func actionableMatchInsideAMatchingInertContainerIsFound() {
        let inner = AXNode(role: kAXGroupRole, description: "answer", actionable: true)
        let outer = AXNode(role: kAXGroupRole, description: "answer", children: [inner])
        let verdict = ActCriteriaSelection.select(WaitCriteria(parsing: #"group "answer""#), in: [window([outer])])
        guard case let .one(match) = verdict else {
            Issue.record("expected the nested actionable match, got \(verdict)"); return
        }
        #expect(match.path == [0, 0, 0])
    }

    /// Two actionable matches, one nested inside the other, are still ambiguity:
    /// descending must not HIDE a match either.
    @Test func nestedActionableMatchesCountTowardAmbiguity() {
        let inner = AXNode(role: kAXGroupRole, description: "answer", actionable: true)
        let outer = AXNode(role: kAXGroupRole, description: "answer", actionable: true, children: [inner])
        let verdict = ActCriteriaSelection.select(WaitCriteria(parsing: #"group "answer""#), in: [window([outer])])
        guard case let .ambiguous(matches) = verdict else {
            Issue.record("expected ambiguity, got \(verdict)"); return
        }
        #expect(matches.count == 2)
    }
}

// MARK: - Pipeline (single acts, several refuse, zero advises; nothing guessed)

@Suite struct ActRunCriteriaTests {
    private let app = "com.example.Calc"
    private let pid: pid_t = 4242

    /// A handle-bearing keypad tree. Each path gets a DISTINGUISHABLE sentinel
    /// handle (a distinct pid's app element — CFEqual-distinct), so the test can
    /// assert WHICH element the action was performed on, not merely that one was.
    private func keypadTree() -> LiveElementTree {
        let nodes = [window([
            AXNode(role: kAXScrollAreaRole, description: "编辑字段", isScrollArea: true,
                   children: [AXNode(role: kAXStaticTextRole, value: "0")]),
            keypadButton("7", id: "Seven"),
            keypadButton("乘", id: "Multiply"),
        ])]
        var elements: [[Int]: AXUIElement] = [:]
        var attributes: [[Int]: AXAttributes] = [:]
        let paths: [[Int]] = [[0], [0, 0], [0, 0, 0], [0, 1], [0, 2]]
        for (index, path) in paths.enumerated() {
            elements[path] = AXUIElementCreateApplication(pid_t(1000 + index))
            attributes[path] = AXAttributes(role: "AXStub")
        }
        return LiveElementTree(nodes: nodes, elementsByPath: elements, attributesByPath: attributes)
    }

    /// Run `runCriteria` over the keypad with every AX seam stubbed. Failure
    /// cases inject `Issue.record` guards so "nothing was acted on" is asserted
    /// through the seam, not inferred from the exit code.
    private func run(
        criteria: String,
        verb: ActVerb = .press,
        value: String? = nil,
        accessibility: Bool = true,
        sessionDir: URL,
        tree: LiveElementTree? = nil,
        performAction: @escaping (AXUIElement, ActVerb, String?) -> Result<Void, AXActionFailure>,
        rewalk: @escaping (pid_t) -> WalkResult?,
        persist: @escaping (Snapshot) -> Void
    ) -> ActOutcome {
        let clock = Clock()
        return ActPipeline.runCriteria(
            criteria: WaitCriteria(parsing: criteria),
            verb: verb,
            value: value,
            app: app,
            json: false,
            environment: [MTouchEnvironment.sessionKey: sessionDir.appendingPathComponent("session.json").path],
            permissions: StubPermissions(accessibility: accessibility),
            loadSession: { _ in nil },
            resolvePID: { _ in pid },
            isRunning: { _, _ in true },
            walkLive: { _ in tree ?? self.keypadTree() },
            rewalk: rewalk,
            performAction: performAction,
            persist: { snapshot, _, _, _ in persist(snapshot) },
            now: clock.now,
            sleep: clock.sleep
        )
    }

    @Test func singleMatchActsOnExactlyTheMatchedElement() throws {
        try withTempDir { dir in
            let tree = keypadTree()
            var acted: (element: AXUIElement, verb: ActVerb)?
            var persisted: Snapshot?
            let outcome = run(
                criteria: #"button "Seven""#,
                sessionDir: dir,
                tree: tree,
                performAction: { element, verb, _ in
                    acted = (element, verb)
                    return .success(())
                },
                rewalk: { _ in
                    WalkResult(nodes: [window([keypadButton("7", id: "Seven")])],
                               windowIDsByPath: [:], fallbackFired: false, fallbackHelped: false,
                               truncated: false)
                },
                persist: { persisted = $0 }
            )
            guard case .acted = outcome else { Issue.record("expected an acted outcome, got \(outcome)"); return }
            let performed = try #require(acted)
            #expect(performed.verb == .press)
            // The element acted on IS the handle recorded at the "Seven" button's
            // path — not a neighbour, not the first handle in the map.
            let expected = try #require(tree.elementsByPath[[0, 1]])
            #expect(CFEqual(performed.element, expected))
            // The normal back half ran: the new session was persisted, so a later
            // ref-based act can follow this criteria-based one.
            #expect(persisted != nil)
        }
    }

    @Test func severalMatchesRefuseListingCandidatesAndActOnNothing() throws {
        try withTempDir { dir in
            let outcome = run(
                criteria: "button",                       // matches both keypad buttons
                sessionDir: dir,
                performAction: { _, _, _ in
                    Issue.record("an ambiguous criteria must act on NOTHING")
                    return .success(())
                },
                rewalk: { _ in Issue.record("no settle after a refusal"); return nil },
                persist: { _ in Issue.record("no session write after a refusal") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a refusal, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("matches 2 actionable elements"))
            #expect(stderr.contains("nothing was acted on"))
            // The candidates are listed compactly with their labels and
            // provenance, so a narrower criteria can be written from the refusal.
            #expect(stderr.contains("AXButton \"7\"@desc"))
            #expect(stderr.contains("AXButton \"乘\"@desc"))
            #expect(stderr.contains("Narrow the criteria"))
        }
    }

    @Test func zeroMatchesFailWithTheWaitSuggestion() throws {
        try withTempDir { dir in
            let outcome = run(
                criteria: #"button "Eight""#,
                sessionDir: dir,
                performAction: { _, _, _ in
                    Issue.record("a zero-match criteria must act on NOTHING")
                    return .success(())
                },
                rewalk: { _ in Issue.record("no settle after a refusal"); return nil },
                persist: { _ in Issue.record("no session write after a refusal") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("no actionable element matching AXButton \"Eight\""))
            // What WAS seen, and the way forward — consistent with read --of.
            #expect(stderr.contains("Last seen:"))
            #expect(stderr.contains("mtouch wait --app \(app) --appears"))
            #expect(stderr.contains("Nothing was acted on"))
            // No non-actionable hint when nothing matched at all.
            #expect(!stderr.contains("non-actionable"))
        }
    }

    @Test func nonActionableOnlyMatchIsAZeroMatchWithTheHint() throws {
        try withTempDir { dir in
            let outcome = run(
                criteria: #"scrollarea "编辑字段""#,        // matches only the display
                sessionDir: dir,
                performAction: { _, _, _ in
                    Issue.record("a non-actionable match must act on NOTHING")
                    return .success(())
                },
                rewalk: { _ in nil },
                persist: { _ in Issue.record("no session write after a refusal") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("matched 1 non-actionable element(s)"))
            #expect(stderr.contains("mtouch wait --app \(app) --appears"))
        }
    }

    @Test func setValueCarriesItsPayloadThroughTheSeam() throws {
        try withTempDir { dir in
            let tree = LiveElementTree(
                nodes: [window([AXNode(role: kAXTextFieldRole, title: "Name", actionable: true)])],
                elementsByPath: [[0]: AXUIElementCreateApplication(1000),
                                 [0, 0]: AXUIElementCreateApplication(1001)],
                attributesByPath: [[0]: AXAttributes(role: "AXStub"), [0, 0]: AXAttributes(role: "AXStub")]
            )
            var received: (verb: ActVerb, value: String?)?
            let outcome = run(
                criteria: #"textfield "Name""#,
                verb: .setValue,
                value: "42",
                sessionDir: dir,
                tree: tree,
                performAction: { _, verb, value in received = (verb, value); return .success(()) },
                rewalk: { _ in
                    WalkResult(nodes: [window([AXNode(role: kAXTextFieldRole, title: "Name",
                                                      value: "42", actionable: true)])],
                               windowIDsByPath: [:], fallbackFired: false, fallbackHelped: false,
                               truncated: false)
                },
                persist: { _ in }
            )
            guard case .acted = outcome else { Issue.record("expected an acted outcome, got \(outcome)"); return }
            let performed = try #require(received)
            #expect(performed.verb == .setValue)
            #expect(performed.value == "42")
        }
    }

    /// The set-value payload rule is usage (64) decided from the arguments alone,
    /// so it outranks even a missing permission — the same pinned order as the
    /// ref mode's `resolveTarget`.
    @Test func setValueWithoutValueIsUsage64BeforeThePermissionGate() throws {
        try withTempDir { dir in
            let outcome = run(
                criteria: #"textfield "Name""#,
                verb: .setValue,
                value: nil,
                accessibility: false,
                sessionDir: dir,
                performAction: { _, _, _ in Issue.record("must not act"); return .success(()) },
                rewalk: { _ in nil },
                persist: { _ in }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .usageError)
            #expect(stderr.contains("requires a value"))
            #expect(stderr.contains("--of"))
        }
    }

    @Test func missingPermissionIsExit2() throws {
        try withTempDir { dir in
            let outcome = run(
                criteria: #"button "Seven""#,
                accessibility: false,
                sessionDir: dir,
                performAction: { _, _, _ in Issue.record("must not act"); return .success(()) },
                rewalk: { _ in nil },
                persist: { _ in }
            )
            guard case let .failed(_, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .permissionMissing)
        }
    }

    @Test func walkTimeoutIsRuntime1WithTheModalHint() throws {
        try withTempDir { dir in
            let clock = Clock()
            let outcome = ActPipeline.runCriteria(
                criteria: WaitCriteria(parsing: #"button "Seven""#),
                verb: .press, value: nil, app: app, json: false,
                environment: [MTouchEnvironment.sessionKey: dir.appendingPathComponent("s.json").path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { _ in nil },
                resolvePID: { [pid] _ in pid },
                isRunning: { _, _ in true },
                walkLive: { _ in nil },                    // bounded timeout
                rewalk: { _ in nil },
                performAction: { _, _, _ in Issue.record("must not act"); return .success(()) },
                persist: { _, _, _, _ in },
                now: clock.now, sleep: clock.sleep
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("--no-verify"))        // the modal-panel way forward
        }
    }

    /// An honest AX refusal on the matched element maps exactly as the ref verbs
    /// map it: exit 1, no diff, no session write.
    @Test func axActionFailureIsRuntime1AndDoesNotPersist() throws {
        try withTempDir { dir in
            let outcome = run(
                criteria: #"button "Seven""#,
                sessionDir: dir,
                performAction: { _, _, _ in .failure(AXActionFailure("cannot press the referenced element.")) },
                rewalk: { _ in Issue.record("no settle after an action failure"); return nil },
                persist: { _ in Issue.record("must not persist after an action failure") }
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)"); return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains("cannot press"))
        }
    }
}
