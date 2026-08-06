import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixture builders (pure AXNode trees, zero AX/TCC dependency)

private func button(_ title: String, enabled: Bool = true) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: rect(), enabled: enabled, actionable: true)
}

private func staticText(_ text: String) -> AXNode {
    AXNode(role: kAXStaticTextRole, title: text, frame: rect())
}

private func group(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXGroupRole, frame: rect(), children: children)
}

private func window(_ children: [AXNode], title: String = "Untitled") -> AXNode {
    AXNode(role: kAXWindowRole, title: title, frame: rect(), children: children)
}

private func rect(_ w: CGFloat = 100, _ h: CGFloat = 20) -> CGRect {
    CGRect(x: 0, y: 0, width: w, height: h)
}

// MARK: - Ref assignment

@Suite struct TextualizerRefTests {
    @Test func refsAreAssignedToActionableNodesInPreOrder() {
        let snapshot = Snapshot(roots: [
            window([group([button("First"), staticText("label"), button("Second")]),
                    button("Third")]),
        ])

        // Three actionable nodes -> e1, e2, e3 in pre-order.
        #expect(snapshot.refs.count == 3)
        #expect(snapshot.refs["e1"]?.title == "First")
        #expect(snapshot.refs["e2"]?.title == "Second")
        #expect(snapshot.refs["e3"]?.title == "Third")
    }

    @Test func nonActionableNodesCarryNoRef() {
        let snapshot = Snapshot(roots: [window([staticText("just text")])])
        #expect(snapshot.refs.isEmpty)
    }

    @Test func disabledActionableNodeStillGetsARef() {
        let snapshot = Snapshot(roots: [window([button("Save", enabled: false)])])
        #expect(snapshot.refs["e1"]?.title == "Save")
        // The disabled state is recorded, not a reason to drop the ref.
        #expect(snapshot.refs.count == 1)
    }

    @Test func refEntryCarriesReResolutionHintsAndIsCodable() throws {
        let snapshot = Snapshot(roots: [window([group([button("Go")])])])
        let entry = try #require(snapshot.refs["e1"])
        #expect(entry.role == kAXButtonRole)
        #expect(entry.path == [0, 0, 0])
        #expect(entry.frame == rect())

        // The persisted form round-trips (session-store depends on this).
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RefEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test func refTableAndRenderedTextAgreeOnRefs() {
        let snapshot = Snapshot(roots: [window([button("A"), button("B")])])
        let text = SnapshotText.render(snapshot)
        for ref in snapshot.refs.keys {
            #expect(text.contains("#\(ref)"))
        }
    }
}

// MARK: - Noise filtering

@Suite struct TextualizerNoiseTests {
    @Test func scrollBarIsNoise() {
        #expect(isNoise(AXNode(role: kAXScrollBarRole, frame: rect())))
    }

    @Test func zeroSizeElementIsNoise() {
        #expect(isNoise(AXNode(role: kAXImageRole, frame: CGRect(x: 0, y: 0, width: 0, height: 30))))
        #expect(isNoise(AXNode(role: kAXImageRole, frame: CGRect(x: 0, y: 0, width: 30, height: 0))))
    }

    @Test func emptyContainerIsNoise() {
        #expect(isNoise(group([group([])])))
    }

    @Test func actionableNodeIsNeverNoise() {
        // Pinned: actionable survives even when zero-size or disabled.
        let zeroSizeButton = AXNode(
            role: kAXButtonRole, frame: CGRect(x: 0, y: 0, width: 0, height: 0),
            enabled: false, actionable: true
        )
        #expect(!isNoise(zeroSizeButton))
    }

    @Test func containerWithActionableDescendantIsKept() {
        #expect(!isNoise(group([group([button("Deep")])])))
    }

    @Test func containerWithTextIsKept() {
        #expect(!isNoise(group([staticText("hello")])))
    }

    @Test func scrollBarGuardingActionableIsKept() {
        // A candidate that guards an actionable descendant must not be dropped.
        let node = AXNode(role: kAXScrollBarRole, frame: rect(), children: [button("Inside")])
        #expect(!isNoise(node))
    }

    @Test func noiseIsDroppedFromRenderedTextButActionableSurvives() {
        let snapshot = Snapshot(roots: [
            window([
                AXNode(role: kAXScrollBarRole, frame: rect()),        // dropped
                group([group([])]),                                    // dropped (empty)
                AXNode(role: kAXImageRole, frame: rect(0, 10)),        // dropped (zero-size)
                button("Keep"),                                        // kept
                staticText("visible"),                                 // kept
            ]),
        ])
        let text = SnapshotText.render(snapshot)
        #expect(!text.contains(kAXScrollBarRole))
        #expect(!text.contains(kAXImageRole))
        #expect(text.contains("#e1"))
        #expect(text.contains("\"Keep\""))
        #expect(text.contains("\"visible\""))
    }
}

// MARK: - Empty tree (VAL-SNAP-009)

@Suite struct TextualizerEmptyTests {
    @Test func emptyRootsRenderExplicitMarkerNeverBlank() {
        let text = SnapshotText.render(Snapshot(roots: []))
        #expect(text == SnapshotText.emptyTreeMarker)
        #expect(!text.isEmpty)
    }

    @Test func treeOfPureNoiseRendersEmptyMarker() {
        let snapshot = Snapshot(roots: [group([group([]), AXNode(role: kAXScrollBarRole, frame: rect())])])
        #expect(SnapshotText.render(snapshot) == SnapshotText.emptyTreeMarker)
    }

    @Test func emptyTreeJSONIsAnEmptyArrayNotBlank() {
        #expect(SnapshotJSON.render(Snapshot(roots: [])) == "[]")
    }
}

// MARK: - Truncation (VAL-SNAP-012)

@Suite struct TextualizerTruncationTests {
    @Test func oversizedTreeTruncatesLoudlyKeepingEveryRefBearingElement() {
        // Window + more inert nodes than the budget, then actionable nodes that
        // fall AFTER the budget is exhausted. Every actionable node must survive.
        let inert = (0..<(SnapshotText.maxNodes + 100)).map { staticText("row\($0)") }
        let buttons = (0..<5).map { button("Action\($0)") }
        let snapshot = Snapshot(roots: [window(inert + buttons)])

        let text = SnapshotText.render(snapshot)

        // Loud marker present.
        #expect(text.contains("truncated"))
        // Every ref-bearing element still listed, even past the budget.
        #expect(snapshot.refs.count == 5)
        for ref in snapshot.refs.keys {
            #expect(text.contains("#\(ref)"))
        }
    }

    @Test func withinBudgetTreeHasNoTruncationMarker() {
        let snapshot = Snapshot(roots: [window([button("A"), staticText("b")])])
        #expect(!SnapshotText.render(snapshot).contains("truncated"))
    }
}

// MARK: - Secure fields (VAL-SNAP-017)

@Suite struct TextualizerSecureTests {
    private static let secret = "hunter2-topsecret-password"

    private func secureFieldByRole() -> AXNode {
        AXNode(role: kAXSecureTextFieldSubrole, title: "Password", value: Self.secret,
               frame: rect(), actionable: true)
    }

    private func secureFieldBySubrole() -> AXNode {
        AXNode(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, title: "Password",
               value: Self.secret, frame: rect(), actionable: true)
    }

    @Test func isSecureRecognisesRoleAndSubrole() {
        #expect(SecureField.isSecure(secureFieldByRole()))
        #expect(SecureField.isSecure(secureFieldBySubrole()))
        #expect(!SecureField.isSecure(AXNode(role: kAXTextFieldRole, value: "plain")))
    }

    @Test func secretIsAbsentFromTextButFieldLineIsPresentAndMasked() {
        for field in [secureFieldByRole(), secureFieldBySubrole()] {
            let text = SnapshotText.render(Snapshot(roots: [window([field])]))
            #expect(!text.contains(Self.secret))       // secret never rendered
            #expect(text.contains("Password"))          // field line present
            #expect(text.contains("#e1"))               // still ref-annotated
        }
    }

    @Test func secretIsAbsentFromJSONButFieldIsMasked() {
        let field = AXNode(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole,
                           value: Self.secret, frame: rect(), actionable: true)
        let json = SnapshotJSON.render(Snapshot(roots: [window([field])]))
        #expect(!json.contains(Self.secret))
        #expect(json.contains(SecureField.mask))
    }

    @Test func secretIsAbsentFromThePersistedRefTable() {
        // RefEntry stores no value at all, so a secret cannot leak via session-store.
        let snapshot = Snapshot(roots: [window([secureFieldBySubrole()])])
        let json = String(data: try! JSONEncoder().encode(snapshot.refs), encoding: .utf8)!
        #expect(!json.contains(Self.secret))
    }
}

// MARK: - Escaping

@Suite struct TextualizerEscapingTests {
    private static let multiline = "line1\nline2\tend"

    @Test func textEscapesNewlineAndTabIntoASingleLine() {
        let field = AXNode(role: kAXTextFieldRole, value: Self.multiline, frame: rect(), actionable: true)
        let text = SnapshotText.render(Snapshot(roots: [field]))

        // The node's value renders on ONE line with literal \n and \t.
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 1)
        #expect(text.contains("\\n"))
        #expect(text.contains("\\t"))
    }

    @Test func jsonKeepsRealCharactersThatRoundTrip() throws {
        let field = AXNode(role: kAXTextFieldRole, value: Self.multiline, frame: rect(), actionable: true)
        let json = SnapshotJSON.render(Snapshot(roots: [field]))

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        #expect(parsed[0]["value"] as? String == Self.multiline)   // real newline + tab
    }
}

// MARK: - Line grammar / JSON shape

@Suite struct TextualizerRenderTests {
    @Test func lineGrammarIncludesSubroleRefAndDisabledTokens() {
        let node = AXNode(role: kAXButtonRole, subrole: "AXCloseButton", title: "Close",
                          frame: rect(), enabled: false, actionable: true)
        let line = SnapshotText.line(for: node, ref: "e7", indent: 2)
        #expect(line == "    AXButton [AXCloseButton] \"Close\" #e7 [disabled]")
    }

    @Test func nonActionableLineOmitsRefToken() {
        let line = SnapshotText.line(for: staticText("hi"), ref: nil, indent: 0)
        #expect(line == "AXStaticText \"hi\"")
    }

    @Test func jsonIsByteStableWithFixedKeyOrder() {
        let node = AXNode(role: kAXButtonRole, subrole: "AXCloseButton", title: "Close",
                          value: "v", frame: CGRect(x: 1, y: 2, width: 3, height: 4),
                          enabled: false, actionable: true)
        let json = SnapshotJSON.render(Snapshot(roots: [node]))
        #expect(json == #"[{"role":"AXButton","subrole":"AXCloseButton","title":"Close",""#
            + #"value":"v","ref":"e1","enabled":false,"frame":{"x":1,"y":2,"w":3,"h":4},"children":[]}]"#)
        // Deterministic across runs.
        #expect(json == SnapshotJSON.render(Snapshot(roots: [node])))
    }

    @Test func jsonEmitsScrollPositionForScrollAreas() {
        let scroll = AXNode(role: kAXScrollAreaRole, frame: rect(),
                            isScrollArea: true, scrollPosition: CGPoint(x: 5, y: 10),
                            children: [button("Inside")])
        let json = SnapshotJSON.render(Snapshot(roots: [scroll]))
        #expect(json.contains("\"scrollPosition\":{\"x\":5,\"y\":10}"))
    }
}
