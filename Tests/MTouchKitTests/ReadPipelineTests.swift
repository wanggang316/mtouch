import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

private struct StubPermissions: PermissionProvider {
    let accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

private func staticText(_ value: String) -> AXNode {
    AXNode(role: kAXStaticTextRole, value: value, frame: CGRect(x: 0, y: 0, width: 200, height: 16))
}

/// The element `read` targets: an actionable group (so it earns a ref) holding
/// whatever text the test wants to read back.
private func article(_ children: [AXNode], title: String? = nil) -> AXNode {
    AXNode(role: kAXGroupRole, title: title, frame: CGRect(x: 0, y: 0, width: 200, height: 400),
           actionable: true, children: children)
}

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 600),
           children: children)
}

private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-read-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

/// A live tree whose per-path attributes mirror `roots`, so `ElementRelocation`
/// resolves every ref by position + hints. Handles are sentinels: `read` never
/// acts on them, it only needs the derived `AXNode` subtree.
private func fakeLiveTree(_ roots: [AXNode]) -> LiveElementTree {
    var attributes: [[Int]: AXAttributes] = [:]
    var elements: [[Int]: AXUIElement] = [:]
    func visit(_ node: AXNode, path: [Int]) {
        attributes[path] = AXAttributes(
            role: node.role, subrole: node.subrole, title: node.title, value: node.value,
            frame: node.frame, enabled: node.enabled,
            actionNames: node.actionable ? [kAXPressAction] : []
        )
        elements[path] = AXUIElementCreateApplication(4242)
        for (index, child) in node.children.enumerated() { visit(child, path: path + [index]) }
    }
    for (index, root) in roots.enumerated() { visit(root, path: [index]) }
    return LiveElementTree(nodes: roots, elementsByPath: elements, attributesByPath: attributes)
}

/// Snapshot → session on disk → `ReadPipeline.run` against the SAME tree, which
/// is the ordinary flow (snapshot, then read a ref it issued).
private func read(
    _ ref: String,
    tree: [AXNode],
    liveTree: [AXNode]? = nil,
    json: Bool = false,
    accessibility: Bool = true,
    isRunning: Bool = true,
    sessionOnDisk: Bool = true
) throws -> ReadOutcome {
    var outcome: ReadOutcome?
    try withTempDir { dir in
        let path = dir.appendingPathComponent("session.json").path
        if sessionOnDisk {
            try SessionStore.save(Snapshot(roots: tree), app: "com.example.App", pid: 4242, to: path)
        }
        outcome = ReadPipeline.run(
            ref: ref, json: json,
            environment: [MTouchEnvironment.sessionKey: path],
            permissions: StubPermissions(accessibility: accessibility),
            loadSession: { SessionStore.load(from: $0) },
            isRunning: { _, _ in isRunning },
            walkLive: { _ in fakeLiveTree(liveTree ?? tree) }
        )
    }
    return try #require(outcome)
}

private func readText(_ outcome: ReadOutcome) -> String? {
    guard case let .read(output) = outcome else { return nil }
    return output
}

// MARK: - Text extraction

@Suite struct ElementTextTests {
    @Test func blocksAreEmittedInDocumentOrder() {
        let node = article([staticText("first"), staticText("second"), staticText("third")])
        #expect(ElementText.blocks(of: node) == ["first", "second", "third"])
    }

    @Test func aValueWinsOverATitleBecauseItIsTheContent() {
        // A labelled field must read back what is IN it, not the label beside it.
        let field = AXNode(role: kAXTextFieldRole, title: "Name", value: "Ada", actionable: true)
        #expect(ElementText.blocks(of: field) == ["Ada"])
    }

    @Test func aTitleIsUsedWhenThereIsNoValue() {
        #expect(ElementText.blocks(of: AXNode(role: kAXButtonRole, title: "Save")) == ["Save"])
    }

    @Test func blankAndWhitespaceOnlyBlocksAreSkipped() {
        let node = article([staticText(""), staticText("   \n\t "), staticText("real")])
        #expect(ElementText.blocks(of: node) == ["real"])
    }

    @Test func aContainerLabelIsNotRepeatedByItsTextChild() {
        // The common real shape: a group titled with the very string its only text
        // child carries. Emitting both would double every label mid-prose.
        let node = article([staticText("Copy")], title: "Copy")
        #expect(ElementText.blocks(of: node) == ["Copy"])
    }

    @Test func onlyIMMEDIATELYConsecutiveRepeatsCollapse() {
        // A repeated string that is separated by other text is real content and
        // must survive — the collapse is not a global de-duplication.
        let node = article([staticText("yes"), staticText("yes"), staticText("no"), staticText("yes")])
        #expect(ElementText.blocks(of: node) == ["yes", "no", "yes"])
    }

    @Test func nestedSubtreesAreFlattenedInPreOrder() {
        let node = article([
            AXNode(role: kAXGroupRole, children: [staticText("a"), staticText("b")]),
            AXNode(role: kAXGroupRole, children: [staticText("c")]),
        ])
        #expect(ElementText.render(node) == "a\nb\nc")
    }

    @Test func aSecureValueIsMaskedNotLeaked() {
        let secure = AXNode(role: kAXSecureTextFieldSubrole, title: "Password", value: "hunter2")
        #expect(ElementText.blocks(of: secure) == [SecureField.mask])
        #expect(ElementText.render(secure).contains("hunter2") == false)
    }

    @Test func aSecureFieldNestedInTheSubtreeIsMaskedToo() {
        let node = article([staticText("Sign in"), AXNode(
            role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, value: "s3cret", actionable: true
        )])
        let rendered = ElementText.render(node)
        #expect(rendered.contains("s3cret") == false)
        #expect(rendered.contains(SecureField.mask))
    }
}

// MARK: - Untruncated output

@Suite struct ReadUntruncatedTests {
    @Test func aSubtreeFarLargerThanTheSnapshotBudgetIsNotTruncated() throws {
        // 3× the text-snapshot node budget, all NON-actionable — exactly the class
        // of node `SnapshotText` drops first, and exactly the long answer `read`
        // exists to recover.
        let count = SnapshotText.maxNodes * 3
        let paragraphs = (0..<count).map { staticText("paragraph \($0)") }
        let tree = [window([article(paragraphs)])]

        let outcome = try read("e1", tree: tree)
        let output = try #require(readText(outcome))
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == count)
        #expect(lines.first == "paragraph 0")
        #expect(lines.last == "paragraph \(count - 1)")
        #expect(output.contains("truncated") == false)

        // The contrast that motivates the command: the text snapshot of the SAME
        // tree does truncate and does lose the tail.
        let snapshotText = renderText(Snapshot(roots: tree))
        #expect(snapshotText.contains("output truncated"))
        #expect(snapshotText.contains("paragraph \(count - 1)") == false)
    }

    @Test func jsonCarriesTheRawStringWithTheRefAndRole() throws {
        let tree = [window([article([staticText("line one"), staticText("line two")])])]
        let outcome = try read("e1", tree: tree, json: true)
        let output = try #require(readText(outcome))

        let data = try #require(output.data(using: .utf8))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["ref"] as? String == "e1")
        #expect(decoded["role"] as? String == kAXGroupRole)
        #expect(decoded["text"] as? String == "line one\nline two")
    }

    @Test func jsonEscapesTheTextRatherThanBreakingTheDocument() throws {
        let tree = [window([article([staticText("quote \" and \\ and\ttab")])])]
        let outcome = try read("e1", tree: tree, json: true)
        let output = try #require(readText(outcome))
        let data = try #require(output.data(using: .utf8))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["text"] as? String == "quote \" and \\ and\ttab")
    }

    @Test func aTextlessSubtreeSaysSoRatherThanPrintingNothing() throws {
        let tree = [window([article([AXNode(role: kAXImageRole)])])]
        let outcome = try read("e1", tree: tree)
        #expect(readText(outcome) == ReadPipeline.emptyMarker)
    }

    @Test func aTextlessSubtreeIsAnEmptyStringInJSON() throws {
        // The marker is a HUMAN affordance; the machine surface stays a raw string.
        let tree = [window([article([AXNode(role: kAXImageRole)])])]
        let outcome = try read("e1", tree: tree, json: true)
        let output = try #require(readText(outcome))
        #expect(output.contains("\"text\":\"\""))
        #expect(output.contains(ReadPipeline.emptyMarker) == false)
    }
}

// MARK: - Exit-code parity with act

@Suite struct ReadExitCodeParityTests {
    private let tree = [window([article([staticText("body")])])]

    private func failure(_ outcome: ReadOutcome) -> (stderr: String, code: MTouchExitCode)? {
        guard case let .failed(stderr, code) = outcome else { return nil }
        return (stderr, code)
    }

    @Test func anUnknownTokenIsAUsageError64ByteIdenticalToAct() throws {
        let outcome = try read("banana", tree: tree)
        let failed = try #require(failure(outcome))
        #expect(failed.code == .usageError)
        #expect(failed.stderr == ActPipeline.unknownRefDiagnostic("banana"))
    }

    @Test func aStaleRefIsRefError3ByteIdenticalToAct() throws {
        // Token-shaped but absent from the session (only e1 was issued).
        let outcome = try read("e99", tree: tree)
        let failed = try #require(failure(outcome))
        #expect(failed.code == .refError)
        #expect(failed.stderr == ActPipeline.staleRefDiagnostic("e99"))
    }

    @Test func noSessionIsRefError3ByteIdenticalToAct() throws {
        let outcome = try read("e1", tree: tree, sessionOnDisk: false)
        let failed = try #require(failure(outcome))
        #expect(failed.code == .refError)
        #expect(failed.stderr == ActPipeline.noSessionDiagnostic("e1"))
    }

    @Test func aMissingGrantIsPermissionError2AndOutranksTheSession() throws {
        let outcome = try read("e1", tree: tree, accessibility: false)
        let failed = try #require(failure(outcome))
        #expect(failed.code == .permissionMissing)
        #expect(failed.stderr == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func aMalformedTokenOutranksEvenTheMissingGrant() throws {
        // Pinned precedence 64 -> 2 -> 3, identical to act: the argument is decided
        // from itself, before any permission is consulted.
        let outcome = try read("banana", tree: tree, accessibility: false)
        let failed = try #require(failure(outcome))
        #expect(failed.code == .usageError)
    }

    @Test func aDeadProcessIsRuntimeFailure1() throws {
        let outcome = try read("e1", tree: tree, isRunning: false)
        let failed = try #require(failure(outcome))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == ActPipeline.notRunningDiagnostic(app: "com.example.App", pid: 4242))
    }

    @Test func aGoneElementIsRefError3AndReadsNothing() throws {
        // The session issued e1 for a group titled "A"; the live tree now holds a
        // different element at that position. Reading the impostor would be worse
        // than failing, so it fails exactly as act does.
        let session = [window([article([staticText("body")], title: "A")])]
        let live = [window([article([staticText("someone else's body")], title: "B")])]
        let outcome = try read("e1", tree: session, liveTree: live)
        let failed = try #require(failure(outcome))
        #expect(failed.code == .refError)
        #expect(failed.stderr == ActPipeline.goneRefDiagnostic("e1"))
    }

    @Test func aWedgedTargetIsABoundedRuntimeFailure1NotAHang() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            try SessionStore.save(Snapshot(roots: tree), app: "com.example.App", pid: 4242, to: path)
            let outcome = ReadPipeline.run(
                ref: "e1", json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in true },
                walkLive: { _ in nil }
            )
            let failed = try #require(failure(outcome))
            #expect(failed.code == .runtimeFailure)
            #expect(failed.stderr == ActPipeline.timeoutDiagnostic(app: "com.example.App", pid: 4242))
        }
    }
}

// MARK: - Read is a pure read

@Suite struct ReadPurityTests {
    @Test func readingLeavesTheSessionFileByteIdentical() throws {
        let tree = [window([article([staticText("body")])])]
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            try SessionStore.save(Snapshot(roots: tree), app: "com.example.App", pid: 4242, to: path)
            let before = try Data(contentsOf: URL(fileURLWithPath: path))

            let outcome = ReadPipeline.run(
                ref: "e1", json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissions(accessibility: true),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in true },
                walkLive: { _ in fakeLiveTree(tree) }
            )
            guard case .read = outcome else { Issue.record("expected a successful read"); return }

            // Refs an agent is holding must survive a read: no renumbering, no
            // rewrite, not even an identical one.
            let after = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(before == after)
        }
    }

    @Test func nodeAtPathWalksTheSameStructuralPathTheRefTableUses() {
        let roots = [window([article([staticText("a"), staticText("b")])])]
        #expect(ReadPipeline.node(at: [0, 0, 1], in: roots)?.value == "b")
        #expect(ReadPipeline.node(at: [0], in: roots)?.role == kAXWindowRole)
        #expect(ReadPipeline.node(at: [0, 0, 9], in: roots) == nil)
        #expect(ReadPipeline.node(at: [7], in: roots) == nil)
        #expect(ReadPipeline.node(at: [], in: roots) == nil)
    }
}

// MARK: - Fixtures for the criteria / whole-app modes

/// An INERT container: no ref is ever issued for it (refs go only to actionable
/// elements), which is precisely why its text needs a non-ref address.
private func inertGroup(_ children: [AXNode], title: String? = nil, value: String? = nil) -> AXNode {
    AXNode(role: kAXGroupRole, title: title, value: value,
           frame: CGRect(x: 0, y: 0, width: 200, height: 400), children: children)
}

private func titledWindow(_ title: String, _ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: title, frame: CGRect(x: 0, y: 0, width: 400, height: 600),
           children: children)
}

private func menuBar(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXMenuBarRole, children: children)
}

private func walkResult(_ roots: [AXNode]) -> WalkResult {
    WalkResult(nodes: roots, fallbackFired: false, fallbackHelped: false, truncated: false)
}

/// `ReadPipeline.runApp` against a hand-built tree: no AX, no TCC, no session — the
/// mode takes none, which is itself part of the contract (it cannot renumber refs).
private func readApp(
    _ criteria: String?,
    tree: [AXNode],
    json: Bool = false,
    accessibility: Bool = true,
    bundleId: String = "com.example.App",
    resolvePID: (String) throws -> pid_t = { _ in 4242 },
    walk: ((pid_t) -> WalkResult?)? = nil,
    diagnoseEmptyTree: (pid_t) -> AXReadFailure? = { _ in nil },
    // Default: ALIVE — the fixture pid is fabricated, so the liveness probe must
    // never reach the real kernel (a pid that happens to exist would flip the verdict).
    isAlive: (pid_t) -> Bool = { _ in true }
) -> ReadOutcome {
    ReadPipeline.runApp(
        bundleId: bundleId,
        criteria: criteria.map { WaitCriteria(parsing: $0) },
        json: json,
        permissions: StubPermissions(accessibility: accessibility),
        resolvePID: resolvePID,
        walk: walk ?? { _ in walkResult(tree) },
        diagnoseEmptyTree: diagnoseEmptyTree,
        isAlive: isAlive
    )
}

private func readFailure(_ outcome: ReadOutcome) -> (stderr: String, code: MTouchExitCode)? {
    guard case let .failed(stderr, code) = outcome else { return nil }
    return (stderr, code)
}

// MARK: - Which elements a criteria addresses

@Suite struct ReadSelectionTests {
    @Test func aCriteriaSelectsEveryMatchInDocumentOrder() {
        let tree = [titledWindow("W", [
            inertGroup([staticText("first")], title: "answer 1"),
            inertGroup([staticText("noise")], title: "sidebar"),
            inertGroup([staticText("second")], title: "answer 2"),
        ])]
        let matched = ReadSelection.elements(in: tree, matching: WaitCriteria(parsing: "group \"answer\""))
        #expect(matched.map(\.title) == ["answer 1", "answer 2"])
    }

    @Test func aMatchNestedInsideAnotherMatchIsNotRepeated() {
        // The outer group's rendering already contains the inner one's text, so
        // emitting both would print the same prose twice.
        let inner = inertGroup([staticText("body")], title: "answer inner")
        let tree = [titledWindow("W", [inertGroup([inner], title: "answer outer")])]
        let matched = ReadSelection.elements(in: tree, matching: WaitCriteria(parsing: "group \"answer\""))
        #expect(matched.map(\.title) == ["answer outer"])
        #expect(ElementText.render(matched[0]).contains("body"))
    }

    @Test func noCriteriaSelectsTheWindowsAndNotTheMenuBar() {
        // The menu bar is chrome every app carries; dumping it into "everything on
        // screen" would bury the content that was actually asked for.
        let tree = [
            menuBar([AXNode(role: kAXMenuBarItemRole, title: "File", actionable: true)]),
            titledWindow("One", [staticText("a")]),
            titledWindow("Two", [staticText("b")]),
        ]
        let matched = ReadSelection.elements(in: tree, matching: nil)
        #expect(matched.map(\.title) == ["One", "Two"])
    }

    @Test func anExplicitCriteriaMayStillReachIntoTheMenuBar() {
        let tree = [menuBar([AXNode(role: kAXMenuBarItemRole, title: "File", actionable: true)])]
        let matched = ReadSelection.elements(in: tree, matching: WaitCriteria(parsing: "menubaritem"))
        #expect(matched.map(\.title) == ["File"])
    }

    @Test func theCriteriaGrammarIsTheOneWaitParses() {
        // Same vectors as the wait grammar: a friendly role maps to its AX role, a
        // raw AX role passes through, and the quoted substring is matched over BOTH
        // title and value.
        let tree = [titledWindow("W", [
            AXNode(role: kAXTextAreaRole, value: "typed", actionable: true),
            inertGroup([], title: "titled answer"),
            inertGroup([], value: "valued answer"),
        ])]
        #expect(ReadSelection.elements(in: tree, matching: WaitCriteria(parsing: "textarea"))
            .map(\.value) == ["typed"])
        #expect(ReadSelection.elements(in: tree, matching: WaitCriteria(parsing: "AXTextArea"))
            .map(\.value) == ["typed"])
        #expect(ReadSelection.elements(in: tree, matching: WaitCriteria(parsing: "group \"answer\""))
            .count == 2)
        #expect(ReadSelection.elements(in: tree, matching: WaitCriteria(parsing: "AXBanana")).isEmpty)
    }
}

// MARK: - Reading by criteria

@Suite struct ReadByCriteriaTests {
    @Test func aSingleMatchReadsItsFullTextThroughInertContainers() {
        // The motivating shape: the answer sits under a chain of inert groups whose
        // refs are all nil, so no ref addresses it — but a criteria does.
        let tree = [titledWindow("W", [
            inertGroup([inertGroup([inertGroup([
                staticText("Paragraph one."), staticText("Paragraph two."),
            ])])], title: "answer"),
        ])]
        let outcome = readApp("group \"answer\"", tree: tree)
        #expect(readText(outcome) == "answer\nParagraph one.\nParagraph two.")
    }

    @Test func everyMatchIsPrintedInDocumentOrderSeparatedByABlankLine() {
        // Silently choosing one of several matches is exactly the quiet wrong answer
        // this surface refuses; all three come back, in tree order.
        let tree = [titledWindow("W", [
            inertGroup([staticText("first answer")], title: "answer"),
            inertGroup([staticText("second answer")], title: "answer"),
            inertGroup([staticText("third answer")], title: "answer"),
        ])]
        let outcome = readApp("group \"answer\"", tree: tree)
        #expect(readText(outcome) == """
        answer
        first answer

        answer
        second answer

        answer
        third answer
        """)
    }

    @Test func jsonReturnsAnArrayOfMatchesNotJustTheFirst() throws {
        let tree = [titledWindow("W", [
            inertGroup([staticText("one")], title: "answer"),
            inertGroup([staticText("two")], title: "answer"),
        ])]
        let output = try #require(readText(readApp("group \"answer\"", tree: tree, json: true)))
        let data = try #require(output.data(using: .utf8))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(decoded.count == 2)
        #expect(decoded.map { $0["role"] as? String } == [kAXGroupRole, kAXGroupRole])
        #expect(decoded.map { $0["text"] as? String } == ["answer\none", "answer\ntwo"])
    }

    @Test func nothingMatchingIsAFailureNamingTheCriteria() throws {
        let tree = [titledWindow("W", [inertGroup([staticText("body")], title: "sidebar")])]
        let failed = try #require(readFailure(readApp("group \"answer\"", tree: tree)))
        // Exit 1, not an empty exit 0: "no such element" must stay distinguishable
        // from an element that holds no text.
        #expect(failed.code == .runtimeFailure)
        // Echoed as the criteria RESOLVES (the friendly role mapped to its AX role),
        // the same phrasing a wait timeout reports.
        #expect(failed.stderr.contains("no element matching AXGroup \"answer\""))
        #expect(failed.stderr.contains("com.example.App"))
        // The summary of what WAS there is the correction hint.
        #expect(failed.stderr.contains("Last seen:"))
        #expect(failed.stderr.contains(kAXGroupRole))
    }

    @Test func matchedButTextlessIsASuccessfulEmptyMarkerNotAFailure() throws {
        // The pair that must stay distinguishable: this matched and holds no text
        // (exit 0 + marker); the test above matched nothing (exit 1).
        let tree = [titledWindow("W", [inertGroup([AXNode(role: kAXImageRole)], title: "answer")])]
        let outcome = readApp("AXImage", tree: tree)
        #expect(readText(outcome) == ReadPipeline.emptyMarker)
    }

    @Test func aTextlessMatchDoesNotPadTheOutputWithBlankLines() {
        let tree = [titledWindow("W", [
            inertGroup([staticText("real")], title: nil),
            inertGroup([AXNode(role: kAXImageRole)], title: nil),
        ])]
        #expect(readText(readApp("group", tree: tree)) == "real")
    }

    @Test func aTextlessMatchStillAppearsInTheJSONArray() throws {
        let tree = [titledWindow("W", [
            inertGroup([staticText("real")], title: nil),
            inertGroup([AXNode(role: kAXImageRole)], title: nil),
        ])]
        let output = try #require(readText(readApp("group", tree: tree, json: true)))
        let data = try #require(output.data(using: .utf8))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(decoded.map { $0["text"] as? String } == ["real", ""])
    }

    @Test func aMatchFarLargerThanTheSnapshotBudgetIsNotTruncated() throws {
        let count = SnapshotText.maxNodes * 3
        let paragraphs = (0..<count).map { staticText("paragraph \($0)") }
        let tree = [titledWindow("W", [inertGroup(paragraphs, title: nil)])]

        let output = try #require(readText(readApp("group", tree: tree)))
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == count)
        #expect(lines.first == "paragraph 0")
        #expect(lines.last == "paragraph \(count - 1)")
        #expect(output.contains("truncated") == false)
    }

    @Test func secureValuesAreMaskedInCriteriaModeToo() throws {
        let tree = [titledWindow("W", [inertGroup([
            staticText("Sign in"),
            AXNode(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, value: "s3cret", actionable: true),
        ], title: nil)])]
        let output = try #require(readText(readApp("group", tree: tree)))
        #expect(output.contains("s3cret") == false)
        #expect(output.contains(SecureField.mask))
    }
}

// MARK: - Reading a whole application

@Suite struct ReadWholeAppTests {
    @Test func everyWindowIsRead() throws {
        let tree = [
            menuBar([AXNode(role: kAXMenuBarItemRole, title: "File", actionable: true)]),
            titledWindow("One", [staticText("text in one")]),
            titledWindow("Two", [staticText("text in two")]),
        ]
        let output = try #require(readText(readApp(nil, tree: tree)))
        #expect(output == "One\ntext in one\n\nTwo\ntext in two")
        // The menu bar is not dumped into the content.
        #expect(output.contains("File") == false)
    }

    @Test func jsonReturnsOneEntryPerWindow() throws {
        let tree = [
            titledWindow("One", [staticText("a")]),
            titledWindow("Two", [staticText("b")]),
        ]
        let output = try #require(readText(readApp(nil, tree: tree, json: true)))
        let data = try #require(output.data(using: .utf8))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(decoded.map { $0["role"] as? String } == [kAXWindowRole, kAXWindowRole])
        #expect(decoded.map { $0["text"] as? String } == ["One\na", "Two\nb"])
    }

    @Test func secureValuesAreMaskedInWholeAppModeToo() throws {
        let tree = [titledWindow("W", [
            AXNode(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, value: "hunter2", actionable: true),
        ])]
        let output = try #require(readText(readApp(nil, tree: tree)))
        #expect(output.contains("hunter2") == false)
        #expect(output.contains(SecureField.mask))
    }

    @Test func anApplicationWithNoWindowSaysSoRatherThanPrintingNothing() throws {
        let tree = [menuBar([AXNode(role: kAXMenuBarItemRole, title: "File", actionable: true)])]
        let failed = try #require(readFailure(readApp(nil, tree: tree)))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr.contains("exposes no window to read"))
        #expect(failed.stderr.contains("com.example.App"))
    }

    @Test func untruncatedAcrossTheWholeApplication() throws {
        let count = SnapshotText.maxNodes * 3
        let tree = [titledWindow("W", (0..<count).map { staticText("line \($0)") })]
        let output = try #require(readText(readApp(nil, tree: tree)))
        #expect(output.split(separator: "\n").last == "line \(count - 1)")
    }
}

// MARK: - Failure precedence for the app-scoped modes

@Suite struct ReadAppFailureTests {
    private let tree = [titledWindow("W", [staticText("body")])]

    @Test func aMissingGrantIsPermissionError2AndOutranksEverything() throws {
        let failed = try #require(readFailure(readApp(
            nil, tree: tree, accessibility: false,
            resolvePID: { _ in Issue.record("pid must not be resolved without the grant"); return 1 }
        )))
        #expect(failed.code == .permissionMissing)
        #expect(failed.stderr == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func aResolutionFailureCarriesItsOwnExitCode() throws {
        // A `--pid` that contradicts `--app` is a self-contradictory invocation: 64,
        // exactly as every other app-scoped command reports it.
        let mismatch = PidBundleMismatchError(pid: 99, requested: "com.example.App", actual: "com.example.Other")
        let failed = try #require(readFailure(readApp(nil, tree: tree, resolvePID: { _ in throw mismatch })))
        #expect(failed.code == .usageError)
        #expect(failed.stderr == mismatch.message)
    }

    @Test func aWedgedTargetIsABoundedRuntimeFailure1NotAHang() throws {
        let failed = try #require(readFailure(readApp(nil, tree: tree, walk: { _ in nil })))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == ReadPipeline.appTimeoutDiagnostic(app: "com.example.App", pid: 4242))
        // Named for read, not for act: this mode never resolved a reference.
        #expect(failed.stderr.contains("read timed out"))
    }

    @Test func aRefusedAccessibilityReadIsNamedRatherThanReportedAsNoMatch() throws {
        // An empty tree is ambiguous: an app that exposes nothing looks exactly like
        // one whose accessibility interface refused every read. Saying "nothing
        // matched" for a question that was never answered is the falsehood.
        let failed = try #require(readFailure(readApp(
            "group", tree: [], walk: { _ in walkResult([]) },
            diagnoseEmptyTree: { pid in AXReadFailure(pid: pid, error: .apiDisabled) }
        )))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr == AXReadFailure(pid: 4242, error: .apiDisabled)
            .diagnostic(reading: "the accessibility tree", of: "com.example.App"))
    }

    @Test func anEmptyTreeThatTheAppANSWEREDStaysANoMatch() throws {
        let failed = try #require(readFailure(readApp(
            "group", tree: [], walk: { _ in walkResult([]) }, diagnoseEmptyTree: { _ in nil }
        )))
        #expect(failed.code == .runtimeFailure)
        #expect(failed.stderr.contains("no element matching"))
    }
}

// MARK: - Addressing grammar

@Suite struct ReadGrammarTests {
    @Test func aRefAloneIsValid() {
        #expect(ReadGrammar.selectionError(ref: "e5", of: nil, app: nil) == nil)
        #expect(ReadGrammar.makeMode(ref: "e5", of: nil, app: nil) == .ref("e5"))
    }

    @Test func anAppWithACriteriaIsValid() {
        #expect(ReadGrammar.selectionError(ref: nil, of: "group \"answer\"", app: "com.example.App") == nil)
        #expect(ReadGrammar.makeMode(ref: nil, of: "group \"answer\"", app: "com.example.App")
            == .criteria(app: "com.example.App", criteria: WaitCriteria(role: kAXGroupRole, substring: "answer")))
    }

    @Test func aBareAppIsValidAndMeansTheWholeApplication() {
        #expect(ReadGrammar.selectionError(ref: nil, of: nil, app: "com.example.App") == nil)
        #expect(ReadGrammar.makeMode(ref: nil, of: nil, app: "com.example.App")
            == .wholeApp(app: "com.example.App"))
    }

    @Test func aRefWithACriteriaNamesTheConflict() throws {
        let message = try #require(ReadGrammar.selectionError(ref: "e5", of: "textarea", app: "com.example.App"))
        #expect(message.contains("<ref>"))
        #expect(message.contains("--of"))
        #expect(message.contains("--app"))
    }

    @Test func aRefWithABareAppNamesTheConflict() throws {
        let message = try #require(ReadGrammar.selectionError(ref: "e5", of: nil, app: "com.example.App"))
        #expect(message.contains("<ref>"))
        #expect(message.contains("--app"))
        #expect(message.contains("--of") == false)
    }

    @Test func aCriteriaWithoutAnAppIsRefused() throws {
        let message = try #require(ReadGrammar.selectionError(ref: nil, of: "textarea", app: nil))
        #expect(message.contains("--of requires --app"))
    }

    @Test func noAddressingModeAtAllIsRefused() throws {
        let message = try #require(ReadGrammar.selectionError(ref: nil, of: nil, app: nil))
        #expect(message.contains("addressing mode"))
        #expect(message.contains("<ref>"))
    }

    @Test func anEmptyCriteriaIsRefusedRatherThanMatchingNothing() throws {
        let message = try #require(ReadGrammar.selectionError(ref: nil, of: "  ", app: "com.example.App"))
        #expect(message.contains("non-empty criteria"))
    }
}
