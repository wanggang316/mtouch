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
