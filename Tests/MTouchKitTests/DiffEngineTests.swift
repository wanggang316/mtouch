import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixture builders (pure AXNode trees, zero AX/TCC dependency)

private func button(_ title: String, enabled: Bool = true) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: rect(), enabled: enabled, actionable: true)
}

private func textField(_ value: String, title: String? = nil) -> AXNode {
    AXNode(role: kAXTextFieldRole, title: title, value: value, frame: rect(), actionable: true)
}

private func secureField(_ value: String, title: String? = nil) -> AXNode {
    AXNode(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, title: title,
           value: value, frame: rect(), actionable: true)
}

private func staticText(_ text: String) -> AXNode {
    AXNode(role: kAXStaticTextRole, title: text, frame: rect())
}

private func group(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXGroupRole, frame: rect(), children: children)
}

private func scrollBar() -> AXNode {
    AXNode(role: kAXScrollBarRole, frame: rect())
}

private func zeroSizeImage() -> AXNode {
    AXNode(role: kAXImageRole, frame: CGRect(x: 0, y: 0, width: 0, height: 10))
}

private func window(_ children: [AXNode], title: String = "W") -> AXNode {
    AXNode(role: kAXWindowRole, title: title, frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

private func rect(_ w: CGFloat = 100, _ h: CGFloat = 20) -> CGRect {
    CGRect(x: 0, y: 0, width: w, height: h)
}

private func diff(_ pre: [AXNode], _ post: [AXNode]) -> DiffResult {
    DiffEngine.diff(pre: Snapshot(roots: pre), post: post)
}

// MARK: - (a) Added node -> +added with a fresh, continuing ref

@Suite struct DiffEngineAddTests {
    @Test func addedNodeIsReportedWithAFreshContinuingRef() {
        let pre = [window([button("A")])]                    // A -> e1
        let post = [window([button("A"), button("B")])]      // A -> e1, B -> e2 (fresh)

        let result = diff(pre, post)

        // B is the only added node; it continues the counter to e2.
        #expect(result.diff.added.count == 1)
        let added = result.diff.added[0]
        #expect(added.node.title == "B")
        #expect(added.ref == "e2")

        // The surviving element keeps its ref; the added ref is act-able (present
        // in the new snapshot's ref table).
        #expect(result.newSnapshot.refs["e1"]?.title == "A")
        #expect(result.newSnapshot.refs["e2"]?.title == "B")
        #expect(result.diff.removed.isEmpty)
        #expect(result.diff.changed.isEmpty)
    }

    @Test func addedRefContinuesPastFreedNumbersNeverReusing() throws {
        // A (e1), B (e2) in a group; C (e3) a sibling. Remove B (frees e2 WITHOUT
        // shifting other slots) and append D at a new path. D must continue the
        // counter to e4 — the freed e2 is never reused.
        let pre = [window([group([button("A"), button("B")]), button("C")])]
        let post = [window([group([button("A")]), button("C"), button("D")])]

        let result = diff(pre, post)

        let added = try #require(result.diff.added.first)
        #expect(added.node.title == "D")
        #expect(added.ref == "e4")
        #expect(result.newSnapshot.refs["e4"]?.title == "D")

        // B's ref went stale; A and C kept theirs.
        #expect(result.diff.staleRefs == ["e2"])
        #expect(result.newSnapshot.refs["e1"]?.title == "A")
        #expect(result.newSnapshot.refs["e3"]?.title == "C")
        #expect(result.newSnapshot.refs["e2"] == nil)
    }

    @Test func addedTextLineCarriesTheFreshRef() {
        let post = [window([button("A"), button("B")])]
        let text = DiffText.render(diff([window([button("A")])], post).diff)
        #expect(text.contains("+ "))
        #expect(text.contains("\"B\""))
        #expect(text.contains("#e2"))
    }
}

// MARK: - (b) Removed node -> -removed, ref goes stale

@Suite struct DiffEngineRemoveTests {
    @Test func removedNodeIsReportedAndItsRefGoesStale() {
        let pre = [window([button("A"), button("B")])]   // A -> e1, B -> e2
        let post = [window([button("A")])]               // B gone

        let result = diff(pre, post)

        #expect(result.diff.removed.count == 1)
        let removed = result.diff.removed[0]
        #expect(removed.node.title == "B")
        #expect(removed.ref == "e2")

        // e2 is recorded stale and is absent from the new ref table; e1 survives.
        #expect(result.diff.staleRefs == ["e2"])
        #expect(result.newSnapshot.refs["e1"]?.title == "A")
        #expect(result.newSnapshot.refs["e2"] == nil)
        #expect(result.diff.added.isEmpty)
    }

    @Test func staleRefResolvesAsStaleInThePersistedSession() {
        let result = diff([window([button("A"), button("B")])], [window([button("A")])])
        let session = Session(snapshot: result.newSnapshot, app: "com.example.App", pid: 42)
        #expect(session.resolve("e2") == .stale)          // removed ref
        if case .resolved = session.resolve("e1") {} else {
            Issue.record("expected e1 to still resolve")
        }
    }

    @Test func removedTextLineUsesMinusMarker() {
        let text = DiffText.render(diff([window([button("A"), button("B")])], [window([button("A")])]).diff)
        #expect(text.contains("- "))
        #expect(text.contains("\"B\""))
        #expect(text.contains("#e2"))
    }
}

// MARK: - (c) Changed value -> ~changed keeping the ref

@Suite struct DiffEngineChangeTests {
    @Test func changedValueKeepsTheRef() {
        let pre = [window([textField("old")])]   // e1
        let post = [window([textField("new")])]

        let result = diff(pre, post)

        #expect(result.diff.changed.count == 1)
        let changed = result.diff.changed[0]
        #expect(changed.ref == "e1")                  // ref preserved across the change
        #expect(changed.node.value == "new")          // renders the POST state
        #expect(changed.previous?.value == "old")     // PRE state available
        #expect(result.newSnapshot.refs["e1"] != nil)
        #expect(result.diff.added.isEmpty)
        #expect(result.diff.removed.isEmpty)
        #expect(result.diff.staleRefs.isEmpty)
    }

    @Test func titleChangeAtStablePathIsChangedNotReplaced() {
        // A title change (not just value) with a stable role+path is a CHANGE,
        // never a remove+add — the ref survives.
        let result = diff([window([button("Save")])], [window([button("Apply")])])
        #expect(result.diff.changed.count == 1)
        #expect(result.diff.changed[0].ref == "e1")
        #expect(result.diff.added.isEmpty && result.diff.removed.isEmpty)
    }

    @Test func enabledChangeIsReportedAsChanged() {
        let result = diff([window([button("Go", enabled: true)])], [window([button("Go", enabled: false)])])
        #expect(result.diff.changed.count == 1)
        #expect(result.diff.changed[0].node.enabled == false)
    }

    @Test func roleChangeAtSamePathIsReplaceNotChange() {
        // A different role at the same position is a distinct element: the PRE
        // element is removed (ref stale) and the POST element added (fresh ref).
        let result = diff([window([button("A")])], [window([textField("x")])])
        #expect(result.diff.changed.isEmpty)
        #expect(result.diff.removed.count == 1)
        #expect(result.diff.removed[0].ref == "e1")
        #expect(result.diff.added.count == 1)
        #expect(result.diff.added[0].ref == "e2")     // fresh, continuing
        #expect(result.diff.staleRefs == ["e1"])
    }

    @Test func changedTextLineUsesTildeMarker() {
        let text = DiffText.render(diff([window([textField("old")])], [window([textField("new")])]).diff)
        #expect(text.contains("~ "))
        #expect(text.contains("\"new\""))
        #expect(text.contains("#e1"))
        #expect(!text.contains("\"old\""))            // shows the POST state only
    }
}

// MARK: - (d) Identical trees -> no-changes + equal digests

@Suite struct DiffEngineNoChangesTests {
    private func tree() -> [AXNode] { [window([button("A"), staticText("hi"), textField("v")])] }

    @Test func identicalTreesReportNoChanges() {
        let result = diff(tree(), tree())
        #expect(result.diff.isEmpty)
        #expect(result.diff.added.isEmpty)
        #expect(result.diff.removed.isEmpty)
        #expect(result.diff.changed.isEmpty)
        #expect(result.diff.staleRefs.isEmpty)
    }

    @Test func noChangesTextIsAnExplicitMarkerNeverBlank() {
        let text = DiffText.render(diff(tree(), tree()).diff)
        #expect(text == DiffText.noChangesMarker)
        #expect(!text.isEmpty)
    }

    @Test func noChangesJSONIsExplicitEmptyArraysNeverBlankNeverATree() {
        let json = DiffJSON.render(diff(tree(), tree()).diff)
        #expect(json == #"{"added":[],"removed":[],"changed":[]}"#)
    }

    @Test func identicalTreesYieldEqualDigestsAndPreserveEveryRef() {
        let pre = Snapshot(roots: tree())
        let result = DiffEngine.diff(pre: pre, post: tree())
        #expect(DiffEngine.digest(of: pre) == DiffEngine.digest(of: result.newSnapshot))
        #expect(result.newSnapshot.refs == pre.refs)   // refs carried unchanged
    }
}

// MARK: - (e) Digest sensitivity

@Suite struct DiffEngineDigestTests {
    @Test func digestIsStableForIdenticalTrees() {
        let a = [window([button("A"), textField("v")])]
        #expect(DiffEngine.digest(of: a) == DiffEngine.digest(of: a))
    }

    @Test func digestFlipsOnValueChange() {
        #expect(DiffEngine.digest(of: [window([textField("old")])])
            != DiffEngine.digest(of: [window([textField("new")])]))
    }

    @Test func digestFlipsOnTitleChange() {
        #expect(DiffEngine.digest(of: [window([button("Save")])])
            != DiffEngine.digest(of: [window([button("Apply")])]))
    }

    @Test func digestFlipsOnEnabledChange() {
        #expect(DiffEngine.digest(of: [window([button("A", enabled: true)])])
            != DiffEngine.digest(of: [window([button("A", enabled: false)])]))
    }

    @Test func digestFlipsOnAddedNode() {
        #expect(DiffEngine.digest(of: [window([button("A")])])
            != DiffEngine.digest(of: [window([button("A"), button("B")])]))
    }

    @Test func digestReusesTheSessionDigestScheme() {
        // Must be the SAME scheme the recorder chains — not a second one.
        let snapshot = Snapshot(roots: [window([button("A")])])
        #expect(DiffEngine.digest(of: snapshot) == Session.digest(of: snapshot))
    }

    @Test func digestIgnoresSecureUnderlyingValueBecauseItIsMasked() {
        // Two trees differing only in a secret's underlying value hash the SAME:
        // the digest is over the masked JSON, so a secret never affects it.
        #expect(DiffEngine.digest(of: [window([secureField("secret-one")])])
            == DiffEngine.digest(of: [window([secureField("secret-two")])]))
    }
}

// MARK: - (f) Grammar parity with the snapshot line grammar

@Suite struct DiffEngineGrammarTests {
    @Test func changedDiffLineEqualsTheSnapshotLineModuloPrefix() throws {
        let result = diff([window([textField("old")])], [window([textField("new")])])
        let entry = try #require(result.diff.changed.first)

        // The diff line, minus its 2-char "~ " prefix, is byte-identical to the
        // element's snapshot line (same role/value/ref/indent grammar).
        let diffLine = try #require(DiffText.render(result.diff).split(separator: "\n").first(where: { $0.hasPrefix("~ ") }))
        let expected = SnapshotText.line(for: entry.node, ref: entry.ref, indent: entry.depth)
        #expect(String(diffLine.dropFirst(2)) == expected)

        // And that same line appears verbatim in the POST snapshot's own render.
        #expect(SnapshotText.render(result.newSnapshot).contains(expected))
    }

    @Test func addedDiffLineEqualsTheSnapshotLineModuloPrefix() throws {
        let result = diff([window([button("A")])], [window([button("A"), button("B")])])
        let entry = try #require(result.diff.added.first)
        let diffLine = try #require(DiffText.render(result.diff).split(separator: "\n").first(where: { $0.hasPrefix("+ ") }))
        let expected = SnapshotText.line(for: entry.node, ref: entry.ref, indent: entry.depth)
        #expect(String(diffLine.dropFirst(2)) == expected)
    }

    @Test func diffJSONNodeSharesTheSnapshotNodeShape() {
        // The added node object matches the snapshot's per-node field grammar.
        let result = diff([window([button("A")])], [window([button("A"), button("B")])])
        let json = DiffJSON.render(result.diff)
        #expect(json.contains(#""role":"AXButton""#))
        #expect(json.contains(#""title":"B""#))
        #expect(json.contains(#""ref":"e2""#))
        #expect(json.contains(#""children":[]"#))
    }
}

// MARK: - (g) Secure fields stay masked in the diff

@Suite struct DiffEngineSecureTests {
    private static let secret = "hunter2-topsecret"

    @Test func addedSecureFieldIsMaskedInTextAndJSON() {
        let result = diff([window([button("A")])],
                          [window([button("A"), secureField(Self.secret)])])   // no title -> value slot

        let text = DiffText.render(result.diff)
        #expect(!text.contains(Self.secret))
        #expect(text.contains(SecureField.mask))

        let json = DiffJSON.render(result.diff)
        #expect(!json.contains(Self.secret))
        #expect(json.contains(SecureField.mask))
    }

    @Test func labelledSecureFieldNeverLeaksItsSecret() {
        let result = diff([window([button("A")])],
                          [window([button("A"), secureField(Self.secret, title: "Password")])])
        let text = DiffText.render(result.diff)
        let json = DiffJSON.render(result.diff)
        #expect(!text.contains(Self.secret) && !json.contains(Self.secret))
        #expect(text.contains("Password") && json.contains("Password"))
    }
}

// MARK: - (h) Noise churn is filtered out of the diff

@Suite struct DiffEngineNoiseTests {
    @Test func addedScrollBarChurnIsFilteredOutAsNoChanges() {
        let result = diff([window([button("A")])],
                          [window([button("A"), scrollBar()])])
        #expect(result.diff.isEmpty)
        #expect(DiffText.render(result.diff) == DiffText.noChangesMarker)
    }

    @Test func addedZeroSizeChurnIsFilteredOutAsNoChanges() {
        let result = diff([window([button("A")])],
                          [window([button("A"), zeroSizeImage()])])
        #expect(result.diff.isEmpty)
    }

    @Test func pureNoiseDeltaLeavesTheDigestUnchanged() {
        // The digest is over the noise-filtered JSON, so scrollbar/zero-size
        // churn never flips it — consistent with the "no changes" verdict.
        #expect(DiffEngine.digest(of: [window([button("A")])])
            == DiffEngine.digest(of: [window([button("A"), scrollBar(), zeroSizeImage()])]))
    }

    @Test func noiseIsNeverEmittedButRealSiblingChangesStillAre() {
        // A genuine change alongside noise churn: only the real change surfaces.
        let result = diff([window([textField("old")])],
                          [window([textField("new"), scrollBar()])])
        #expect(result.diff.changed.count == 1)
        #expect(result.diff.added.isEmpty)             // scrollbar filtered
        #expect(!DiffText.render(result.diff).contains(kAXScrollBarRole))
    }
}
