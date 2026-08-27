import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures
//
// The shape under test is the one role/subrole/title cannot describe: a ROW of
// same-role controls that expose NO title and NO subrole, identified only by
// their accessibility label (`description`, or failing that `identifier`). A
// system calculator's keypad is exactly this — every key is an `AXButton` whose
// only distinguishing attribute is its description.
//
// The failure these fixtures pin is a SILENT one: a sibling appearing or
// disappearing above the row shifts every index by one, and a ref that identifies
// its element by role alone comes to address its NEIGHBOUR while still reporting
// success. A ref must instead land on the element carrying the SAME label, or go
// stale — never on the one next to it.

/// A titleless, subrole-less key identified only by its accessibility
/// description — the keypad-button shape.
private func describedKey(_ description: String) -> AXNode {
    AXNode(role: kAXButtonRole, description: description, frame: keyFrame, actionable: true)
}

/// A key whose ONLY identity is its developer-set identifier: no title, no
/// subrole, no description.
private func identifiedKey(_ identifier: String) -> AXNode {
    AXNode(role: kAXButtonRole, identifier: identifier, frame: keyFrame, actionable: true)
}

/// A titled button carrying no label at all — the pre-existing shape whose
/// behaviour must be untouched by label identity.
private func titledButton(_ title: String) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: keyFrame, actionable: true)
}

/// The transient pane whose appearance/disappearance shifts the row. Modelled on
/// the real thing: a scroll area with its own description and a text child, so
/// the noise filter keeps it and the shift is visible in the rendered view.
private func transientPane(_ text: String) -> AXNode {
    AXNode(
        role: kAXScrollAreaRole, description: "previous expression", frame: keyFrame,
        children: [AXNode(role: kAXStaticTextRole, title: text, frame: keyFrame)]
    )
}

private func keypadWindow(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

private let keyFrame = CGRect(x: 0, y: 0, width: 40, height: 40)

private func attributes(of node: AXNode) -> AXAttributes {
    AXAttributes(
        role: node.role, subrole: node.subrole, title: node.title,
        description: node.description, identifier: node.identifier,
        actionNames: node.actionable ? [kAXPressAction] : []
    )
}

/// The per-path attribute index a fresh walk of `roots` would produce — the input
/// `ElementRelocation` reads.
private func attributeIndex(_ roots: [AXNode]) -> [[Int]: AXAttributes] {
    var index: [[Int]: AXAttributes] = [:]
    func visit(_ node: AXNode, path: [Int]) {
        index[path] = attributes(of: node)
        for (childIndex, child) in node.children.enumerated() { visit(child, path: path + [childIndex]) }
    }
    for (rootIndex, root) in roots.enumerated() { visit(root, path: [rootIndex]) }
    return index
}

/// The ref a snapshot of `roots` issued for the actionable node at `path`.
private func ref(at path: [Int], in roots: [AXNode]) -> RefEntry {
    let snapshot = Snapshot(roots: roots)
    guard let token = snapshot.ref(atPath: path), let entry = snapshot.refs[token] else {
        preconditionFailure("no ref at \(path) — fixture is wrong")
    }
    return entry
}

private func diff(_ pre: [AXNode], _ post: [AXNode]) -> DiffResult {
    DiffEngine.diff(pre: Snapshot(roots: pre), post: post)
}

// MARK: - Relocation: a label is identity, so a shifted neighbour is not the element

@Suite struct RefLabelRelocationTests {
    /// Removing the pane slides the whole row up by one, so the ref's OWN path now
    /// holds the next key. Role/subrole/title are identical across the row, so
    /// without the label that positional occupant "matches" and the ref silently
    /// addresses its neighbour. With the label it is rejected, and the unique
    /// same-label element one slot up is resolved instead.
    @Test func aRefSurvivesAShiftOntoItsOwnLabelNotItsNeighbour() {
        let pre = [keypadWindow([transientPane("9+9"), describedKey("1"), describedKey("2"), describedKey("3")])]
        let entry = ref(at: [0, 1], in: pre)               // the key described "1"
        #expect(entry.description == "1")

        // The pane disappears: every key moves one index up.
        let post = [keypadWindow([describedKey("1"), describedKey("2"), describedKey("3")])]

        let located = ElementRelocation.locatePath(entry, in: attributeIndex(post))
        #expect(located == [0, 0])                          // the key still described "1"
        #expect(located != [0, 1])                          // NEVER the key described "2"
    }

    /// The same shift for a row whose only identity is `identifier`.
    @Test func anIdentifierOnlyRefSurvivesAShiftOntoItsOwnIdentifier() {
        let pre = [keypadWindow([transientPane("9+9"), identifiedKey("key.one"), identifiedKey("key.two")])]
        let entry = ref(at: [0, 1], in: pre)
        #expect(entry.identifier == "key.one")
        #expect(entry.title == nil)
        #expect(entry.description == nil)

        let post = [keypadWindow([identifiedKey("key.one"), identifiedKey("key.two")])]

        let located = ElementRelocation.locatePath(entry, in: attributeIndex(post))
        #expect(located == [0, 0])
        #expect(located != [0, 1])
    }

    /// Ref identity compares the identifier VERBATIM — the `_NS:<n>` filter the
    /// rendered LABEL slot applies is deliberately NOT applied here. An
    /// AppKit-synthesized identifier is unfit to be shown as a NAME, but within a
    /// single session (snapshot and act are the same process) it is the only thing
    /// telling two otherwise-identical siblings apart, and dropping it is what lets
    /// a ref slide onto its neighbour. See `AXLabel.usableIdentifier`.
    @Test func aSyntheticIdentifierStillDiscriminatesForRefIdentity() {
        let synthetic = AXLabel.syntheticIdentifierPrefix          // "_NS:"
        let pre = [keypadWindow([
            transientPane("9+9"), identifiedKey("\(synthetic)8"), identifiedKey("\(synthetic)9"),
        ])]
        let entry = ref(at: [0, 1], in: pre)
        // The filter would have discarded this identity; ref identity keeps it.
        #expect(AXLabel.usableIdentifier(of: AXNode(role: kAXButtonRole, identifier: entry.identifier)) == nil)
        #expect(entry.identifier == "\(synthetic)8")

        let post = [keypadWindow([identifiedKey("\(synthetic)8"), identifiedKey("\(synthetic)9")])]

        let located = ElementRelocation.locatePath(entry, in: attributeIndex(post))
        #expect(located == [0, 0])
        #expect(located != [0, 1])
    }

    /// When the labelled element is genuinely GONE, a same-role sibling now sitting
    /// at the ref's path is an impostor: the ref is stale (the act layer's exit 3),
    /// never re-pointed onto it.
    @Test func aRefWhoseLabelIsGoneIsStaleRatherThanRepointed() {
        let pre = [keypadWindow([describedKey("1"), describedKey("2"), describedKey("3")])]
        let entry = ref(at: [0, 0], in: pre)               // described "1"

        // "1" is removed; "2" and "3" slide up into its place.
        let post = [keypadWindow([describedKey("2"), describedKey("3")])]

        #expect(ElementRelocation.locatePath(entry, in: attributeIndex(post)) == nil)
    }

    /// Two candidates carrying the SAME label and neither at the ref's path stays
    /// ambiguous — the pre-existing refusal-to-guess rule is unaffected.
    @Test func twoIdenticallyLabelledCandidatesRemainAmbiguous() {
        let pre = [keypadWindow([transientPane("9+9"), describedKey("1")])]
        let entry = ref(at: [0, 1], in: pre)

        let post = [keypadWindow([describedKey("1"), describedKey("1")])]
        // Path [0,1] does hold a same-label key, so the POSITIONAL rule resolves it
        // there; the ambiguity only bites when the ref's own path is not a match.
        let shifted = ref(at: [0, 0], in: [keypadWindow([describedKey("1")])])
        #expect(ElementRelocation.locatePath(entry, in: attributeIndex(post)) == [0, 1])
        #expect(ElementRelocation.locatePath(shifted, in: attributeIndex(post)) == [0, 0])
    }

    @Test func hintsMatchDistinguishesDescriptionAndIdentifier() {
        let entry = ref(at: [0, 0], in: [keypadWindow([
            AXNode(role: kAXButtonRole, description: "seven", identifier: "key.7", frame: keyFrame, actionable: true),
        ])])
        #expect(ElementRelocation.hintsMatch(
            attributes(of: AXNode(role: kAXButtonRole, description: "seven", identifier: "key.7")), entry
        ))
        #expect(!ElementRelocation.hintsMatch(
            attributes(of: AXNode(role: kAXButtonRole, description: "eight", identifier: "key.7")), entry
        ))
        #expect(!ElementRelocation.hintsMatch(
            attributes(of: AXNode(role: kAXButtonRole, description: "seven", identifier: "key.8")), entry
        ))
        // A label the ref does not have is just as much a mismatch as a wrong one.
        #expect(!ElementRelocation.hintsMatch(
            attributes(of: AXNode(role: kAXButtonRole, identifier: "key.7")), entry
        ))
    }

    /// A title-bearing element carries no label at all, so both sides compare nil
    /// and relocation behaves EXACTLY as before: positional match when it stayed
    /// put, unique-hint recovery when it moved, stale when it is gone.
    @Test func titleBearingRelocationIsUnchanged() {
        let pre = [keypadWindow([titledButton("Save"), titledButton("Cancel")])]
        let entry = ref(at: [0, 0], in: pre)
        #expect(entry.description == nil)
        #expect(entry.identifier == nil)

        let inPlace = [keypadWindow([titledButton("Save"), titledButton("Cancel")])]
        #expect(ElementRelocation.locatePath(entry, in: attributeIndex(inPlace)) == [0, 0])

        let moved = [keypadWindow([titledButton("Cancel"), titledButton("Save")])]
        #expect(ElementRelocation.locatePath(entry, in: attributeIndex(moved)) == [0, 1])

        let gone = [keypadWindow([titledButton("Cancel")])]
        #expect(ElementRelocation.locatePath(entry, in: attributeIndex(gone)) == nil)
    }
}

// MARK: - Diff carry-over: the site where the shift was silently absorbed
//
// The relocation gate above only sees the session it is handed. The ref table is
// re-derived after EVERY action, so if the diff engine re-points a ref onto the
// shifted neighbour, the next relocation faithfully finds that neighbour and the
// wrong control is pressed with no error anywhere. Carry-over must therefore
// apply the same label identity.

@Suite struct RefLabelDiffCarryOverTests {
    /// A sibling INSERTED before the row (the pane appearing): every key's index
    /// moves down by one. Each ref must follow its own label, not stay at its old
    /// index where the previous key now sits.
    @Test func aSiblingInsertCarriesEachRefOntoItsOwnLabel() {
        let pre = [keypadWindow([describedKey("1"), describedKey("2"), describedKey("3")])]
        let post = [keypadWindow([transientPane("9+9"), describedKey("1"), describedKey("2"), describedKey("3")])]

        let result = diff(pre, post)

        #expect(result.newSnapshot.refs["e1"]?.description == "1")
        #expect(result.newSnapshot.refs["e2"]?.description == "2")
        #expect(result.newSnapshot.refs["e3"]?.description == "3")
        #expect(result.newSnapshot.refs["e1"]?.path == [0, 1])
        #expect(result.newSnapshot.refs["e2"]?.path == [0, 2])
        #expect(result.newSnapshot.refs["e3"]?.path == [0, 3])
        // Nothing went stale: every key survived, it just moved.
        #expect(result.diff.staleRefs.isEmpty)
    }

    /// A sibling REMOVED before the row (the pane disappearing) — the direction
    /// observed live, where the ref for "1" came to address "2".
    @Test func aSiblingRemoveCarriesEachRefOntoItsOwnLabel() {
        let pre = [keypadWindow([transientPane("9+9"), describedKey("1"), describedKey("2"), describedKey("3")])]
        let post = [keypadWindow([describedKey("1"), describedKey("2"), describedKey("3")])]

        let result = diff(pre, post)

        #expect(result.newSnapshot.refs["e1"]?.description == "1")
        #expect(result.newSnapshot.refs["e2"]?.description == "2")
        #expect(result.newSnapshot.refs["e3"]?.description == "3")
        #expect(result.newSnapshot.refs["e1"]?.path == [0, 0])
        #expect(result.diff.staleRefs.isEmpty)
    }

    /// An identifier-only row survives the same shift on the identifier alone.
    @Test func anIdentifierOnlyRowCarriesAcrossAShift() {
        let pre = [keypadWindow([identifiedKey("key.one"), identifiedKey("key.two")])]
        let post = [keypadWindow([transientPane("9+9"), identifiedKey("key.one"), identifiedKey("key.two")])]

        let result = diff(pre, post)

        #expect(result.newSnapshot.refs["e1"]?.identifier == "key.one")
        #expect(result.newSnapshot.refs["e2"]?.identifier == "key.two")
        #expect(result.diff.staleRefs.isEmpty)
    }

    /// When a labelled key is genuinely removed, its ref goes STALE and the key
    /// that slid into its index keeps its OWN ref — the carry-over never re-homes
    /// a ref onto a differently-labelled element.
    @Test func aRemovedKeysRefGoesStaleAndItsNeighbourKeepsItsOwnRef() {
        let pre = [keypadWindow([describedKey("1"), describedKey("2"), describedKey("3")])]
        let post = [keypadWindow([describedKey("2"), describedKey("3")])]

        let result = diff(pre, post)

        #expect(result.diff.staleRefs == ["e1"])                       // "1" is gone
        #expect(result.newSnapshot.refs["e1"] == nil)
        #expect(result.newSnapshot.refs["e2"]?.description == "2")     // not re-homed onto "2"
        #expect(result.newSnapshot.refs["e3"]?.description == "3")
        #expect(result.diff.removed.contains { $0.node.description == "1" })
    }

    /// The label is identity; the TITLE is still a changeable attribute. A titled
    /// control that merely re-titles itself keeps its ref and reads as CHANGED,
    /// exactly as before label identity existed.
    @Test func aTitleChangeStillKeepsItsRefAndReadsAsChanged() {
        let pre = [keypadWindow([titledButton("Save"), titledButton("Cancel")])]
        let post = [keypadWindow([titledButton("Saving…"), titledButton("Cancel")])]

        let result = diff(pre, post)

        #expect(result.newSnapshot.refs["e1"]?.title == "Saving…")
        #expect(result.diff.staleRefs.isEmpty)
        #expect(result.diff.added.isEmpty)
        #expect(result.diff.changed.contains { $0.node.title == "Saving…" })
    }

    /// A titled tree is untouched by label identity: same ref numbering, same
    /// rendered diff text as a tree carrying no labels can produce.
    @Test func aTitledTreeDiffIsUnaffectedByLabelIdentity() {
        let pre = [keypadWindow([titledButton("A"), titledButton("B")])]
        let post = [keypadWindow([titledButton("A"), titledButton("B"), titledButton("C")])]

        let result = diff(pre, post)

        #expect(result.newSnapshot.refs["e1"]?.title == "A")
        #expect(result.newSnapshot.refs["e2"]?.title == "B")
        #expect(result.newSnapshot.refs["e3"]?.title == "C")   // fresh, continuing ref
        #expect(result.diff.staleRefs.isEmpty)
        #expect(result.diff.added.count == 1)
    }
}

// MARK: - End-to-end through the fake provider seam
//
// The two gates above are pure. This drives the whole ref verb — resolve →
// re-locate → act — against a hand-built live tree, so the guarantee is pinned at
// the surface an agent actually sees: which element got pressed, or exit 3 with
// nothing acted on.

/// Deterministic virtual clock for the post-action settle's `now`/`sleep` seams,
/// so a test that reaches the settle spends no wall time in it.
private final class SettleClock {
    private(set) var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(_ interval: TimeInterval) { time += interval }
}

@Suite struct RefLabelActPipelineTests {
    /// The pid a sentinel handle is created with, used purely as a per-path marker
    /// so the test can tell WHICH element was pressed.
    private static func handle(marking path: [Int]) -> AXUIElement {
        AXUIElementCreateApplication(pid_t(9000 + (path.last ?? 0)))
    }

    private static func markerPID(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// A live tree over `roots` with a DISTINCT sentinel handle at every path, so a
    /// press on the wrong element is observable rather than degenerating into a
    /// missing-handle failure.
    private static func liveTree(_ roots: [AXNode]) -> LiveElementTree {
        let index = attributeIndex(roots)
        var elements: [[Int]: AXUIElement] = [:]
        for path in index.keys { elements[path] = handle(marking: path) }
        return LiveElementTree(nodes: roots, elementsByPath: elements, attributesByPath: index)
    }

    private func withSession(_ roots: [AXNode], _ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtouch-ref-label-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.json").path
        try SessionStore.save(Snapshot(roots: roots), app: "com.example.App", pid: 4242, to: path)
        try body(path)
    }

    private struct GrantedPermissions: PermissionProvider {
        var accessibilityGranted: Bool { true }
        var screenRecordingGranted: Bool { false }
    }

    /// The live reproduction, in a test: a ref issued while the pane was showing is
    /// pressed after the pane went away. It must press the key that still carries
    /// its label, never the key that slid into its index.
    @Test func aShiftedRowPressesTheLabelledKeyNotItsNeighbour() throws {
        let snapshotted = [keypadWindow([
            transientPane("9+9"), describedKey("1"), describedKey("2"), describedKey("3"),
        ])]
        try withSession(snapshotted) { sessionPath in
            // At act time the pane is gone: "1" is now at [0,0], "2" at [0,1].
            let afterShift = [keypadWindow([describedKey("1"), describedKey("2"), describedKey("3")])]
            let clock = SettleClock()
            var pressedMarker: pid_t = 0
            let outcome = ActPipeline.run(
                ref: "e1", verb: .press, value: nil, json: false,
                environment: [MTouchEnvironment.sessionKey: sessionPath],
                permissions: GrantedPermissions(),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in true },
                walkLive: { _ in Self.liveTree(afterShift) },
                rewalk: { _ in
                    WalkResult(nodes: afterShift, windowIDsByPath: [:],
                               fallbackFired: false, fallbackHelped: false, truncated: false)
                },
                performAction: { element, _, _ in
                    pressedMarker = Self.markerPID(of: element)
                    return .success(())
                },
                persist: { _, _, _, _ in },
                now: clock.now, sleep: clock.sleep
            )

            guard case .acted = outcome else {
                Issue.record("expected the ref to relocate onto its own label")
                return
            }
            #expect(pressedMarker == Self.markerPID(of: Self.handle(marking: [0, 0])))  // the key "1"
            #expect(pressedMarker != Self.markerPID(of: Self.handle(marking: [0, 1])))  // NOT the key "2"
        }
    }

    /// When the labelled key is gone, the neighbour occupying its index is NOT
    /// pressed: exit 3, and the diagnostic states nothing was acted on.
    @Test func aRefWhoseLabelVanishedExitsThreeAndActsOnNothing() throws {
        let snapshotted = [keypadWindow([describedKey("1"), describedKey("2"), describedKey("3")])]
        try withSession(snapshotted) { sessionPath in
            let withoutOne = [keypadWindow([describedKey("2"), describedKey("3")])]
            let outcome = ActPipeline.run(
                ref: "e1", verb: .press, value: nil, json: false,
                environment: [MTouchEnvironment.sessionKey: sessionPath],
                permissions: GrantedPermissions(),
                loadSession: { SessionStore.load(from: $0) },
                isRunning: { _, _ in true },
                walkLive: { _ in Self.liveTree(withoutOne) },
                rewalk: { _ in Issue.record("no settle when the element is gone"); return nil },
                performAction: { _, _, _ in
                    Issue.record("must not press the neighbour that slid into the index")
                    return .success(())
                },
                persist: { _, _, _, _ in Issue.record("must not persist a stale ref") },
                sleep: { _ in }
            )

            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a stale-ref failure")
                return
            }
            #expect(code == .refError)                       // exit 3
            #expect(code.rawValue == 3)
            #expect(stderr.contains("Nothing was acted on."))
        }
    }
}

// MARK: - Persisted shape: an old session is absent, never mis-decoded

@Suite struct RefLabelSessionVersionTests {
    private func withTempFile(_ body: (String) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtouch-ref-label-version-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("session.json").path)
    }

    private struct GrantedPermissions: PermissionProvider {
        var accessibilityGranted: Bool { true }
        var screenRecordingGranted: Bool { false }
    }

    /// The persisted `RefEntry` shape changed, so the schema version moved past the
    /// label-free one. Pinned as an inequality rather than a literal: what matters
    /// is that a label-free file can never be read back as current.
    @Test func theSchemaVersionMovedPastTheLabelFreeShape() {
        #expect(Session.currentVersion > 1)
    }

    /// A session written by the previous shape has no `description`/`identifier`
    /// keys. Decoding is tolerant, so those keys would silently read as "this
    /// element has no label" — refs that then match ANY same-role sibling, which is
    /// precisely the misdelivery being fixed. The version gate is what forbids it:
    /// the file folds into the corrupt-as-absent path.
    @Test func aLabelFreeSessionIsTreatedAsAbsentNotMisdecoded() throws {
        try withTempFile { path in
            let labelFree = """
            {"version":1,"app":"com.example.App","pid":4242,"digest":"0123456789abcdef",\
            "refs":{"e1":{"ref":"e1","role":"AXButton","path":[0,0]}}}
            """
            try Data(labelFree.utf8).write(to: URL(fileURLWithPath: path))

            #expect(SessionStore.load(from: path) == nil)                    // absent, no crash
            #expect(SessionStore.resolve("e1", from: path) == .noSession)
        }
    }

    /// The documented exit code for that state, measured through the act layer's
    /// resolution: no session is a ref error (exit 3) with the "run snapshot first"
    /// advice — never a crash, and never a resolved-but-label-free ref.
    @Test func actAgainstALabelFreeSessionIsRefError3() throws {
        try withTempFile { path in
            let labelFree = """
            {"version":1,"app":"com.example.App","pid":4242,"digest":"0123456789abcdef",\
            "refs":{"e1":{"ref":"e1","role":"AXButton","path":[0,0]}}}
            """
            try Data(labelFree.utf8).write(to: URL(fileURLWithPath: path))

            let target = ActPipeline.resolveTarget(
                ref: "e1", verb: .press, value: nil,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: GrantedPermissions(),
                loadSession: { SessionStore.load(from: $0) }
            )
            guard case let .terminal(.failed(stderr, code)) = target else {
                Issue.record("a label-free session must not resolve a ref")
                return
            }
            #expect(code == .refError)
            #expect(code.rawValue == 3)
            #expect(stderr.contains("no active snapshot session"))
        }
    }

    /// A fresh save heals the file, and the label round-trips through it — the
    /// identity the act layer will compare against is the one that was persisted.
    @Test func aFreshSaveHealsTheFileAndTheLabelRoundTrips() throws {
        try withTempFile { path in
            try Data("{\"version\":1}".utf8).write(to: URL(fileURLWithPath: path))

            let roots = [keypadWindow([
                AXNode(role: kAXButtonRole, description: "seven", identifier: "key.7",
                       frame: keyFrame, actionable: true),
            ])]
            try SessionStore.save(Snapshot(roots: roots), app: "com.example.App", pid: 4242, to: path)

            let session = try #require(SessionStore.load(from: path))
            #expect(session.version == Session.currentVersion)
            let entry = try #require(session.refs["e1"])
            #expect(entry.description == "seven")
            #expect(entry.identifier == "key.7")
        }
    }

    /// The persisted file names the label fields explicitly, so the shape change is
    /// visible on disk rather than implied. A label is a NAME, never a field's
    /// contents, so writing it keeps `RefEntry` value-free.
    @Test func theLabelIsWrittenToTheSessionFile() throws {
        try withTempFile { path in
            let roots = [keypadWindow([
                AXNode(role: kAXButtonRole, description: "seven", identifier: "key.7",
                       frame: keyFrame, actionable: true),
            ])]
            try SessionStore.save(Snapshot(roots: roots), app: "com.example.App", pid: 4242, to: path)

            let bytes = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            #expect(bytes.contains("\"description\":\"seven\""))
            #expect(bytes.contains("\"identifier\":\"key.7\""))
        }
    }
}

// MARK: - Ancestor identity keeps its owning-window protection

@Suite struct RefLabelAncestorIdentityTests {
    /// Ancestors are compared with the SAME tuple, so a labelled container is part
    /// of a ref's identity too — while the owning-window `CGWindowID` gate added
    /// earlier still rejects a same-hint element in a different window. Adding the
    /// label dimension must not weaken that.
    @Test func labelledAncestorsDiscriminateAndTheWindowGateStillHolds() throws {
        let keypad = AXNode(
            role: kAXGroupRole, description: "keypad", frame: keyFrame,
            children: [describedKey("1")]
        )
        let roots = [keypadWindow([keypad])]
        let entry = ref(at: [0, 0, 0], in: roots)
        #expect(entry.ancestors.last?.description == "keypad")

        // The same tree, but the container now answers to a different name: the
        // ref's ancestor identity no longer matches, so it is stale.
        let renamed = [keypadWindow([
            AXNode(role: kAXGroupRole, description: "sidebar", frame: keyFrame, children: [describedKey("1")]),
        ])]
        #expect(ElementRelocation.locatePath(entry, in: attributeIndex(renamed)) == nil)

        // The owning-window gate is untouched: the identical tree under a DIFFERENT
        // window id is rejected even though every hint matches.
        let stamped = Snapshot(roots: roots, windowIDsByPath: [[0]: 7001, [0, 0]: 7001, [0, 0, 0]: 7001])
        let pinned = try #require(stamped.refs["e1"])
        #expect(pinned.ownerWindowID == 7001)
        #expect(ElementRelocation.locatePath(
            pinned, in: attributeIndex(roots),
            windowIDsByPath: [[0]: 7002, [0, 0]: 7002, [0, 0, 0]: 7002]
        ) == nil)
        #expect(ElementRelocation.locatePath(
            pinned, in: attributeIndex(roots),
            windowIDsByPath: [[0]: 7001, [0, 0]: 7001, [0, 0, 0]: 7001]
        ) == [0, 0, 0])
    }
}
