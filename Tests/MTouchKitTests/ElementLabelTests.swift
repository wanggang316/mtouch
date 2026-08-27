import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

/// The shape that motivated this feature, measured on a stock macOS calculator:
/// a button with NO title, NO value and NO description, identified ONLY by its
/// developer-set `AXIdentifier`. Rendered without that attribute, twenty-odd of
/// these are indistinguishable `""` lines and no agent can find the digit 7.
private func identifierOnlyButton(_ identifier: String) -> AXNode {
    AXNode(role: kAXButtonRole, identifier: identifier, frame: rect(), actionable: true)
}

/// A control labelled by its ACCESSIBILITY DESCRIPTION only — the other half of
/// the gap, and the commoner one (any SwiftUI control given an accessibility
/// label but no title reports this shape).
private func descriptionOnlyButton(_ description: String) -> AXNode {
    AXNode(role: kAXButtonRole, description: description, frame: rect(), actionable: true)
}

private func window(_ children: [AXNode], title: String = "Untitled") -> AXNode {
    AXNode(role: kAXWindowRole, title: title, frame: rect(400, 300), children: children)
}

private func rect(_ w: CGFloat = 100, _ h: CGFloat = 20) -> CGRect {
    CGRect(x: 0, y: 0, width: w, height: h)
}

/// Permission stub so the `read --of` end-to-end assertion needs no TCC grant.
private struct GrantedPermissions: PermissionProvider {
    var accessibilityGranted: Bool { true }
    var screenRecordingGranted: Bool { false }
}

/// `read --app <id> --of <criteria>` end-to-end over a literal tree.
private func readApp(_ criteria: String, tree: [AXNode]) -> ReadOutcome {
    ReadPipeline.runApp(
        bundleId: "com.example.App",
        criteria: WaitCriteria(parsing: criteria),
        json: false,
        permissions: GrantedPermissions(),
        resolvePID: { _ in 4242 },
        walk: { _ in
            WalkResult(nodes: tree, fallbackFired: false, fallbackHelped: false, truncated: false)
        },
        diagnoseEmptyTree: { _ in nil }
    )
}

// MARK: - Reading the attributes

@Suite struct ElementLabelAttributeTests {
    @Test func anEmptyLabelAttributeNormalizesToNil() {
        // Apps answer these reads with "" as readily as they refuse them, and the
        // two are the same fact: this element has no such label.
        #expect(AXValueRendering.label(from: "" as CFString) == nil)
        #expect(AXValueRendering.label(from: nil) == nil)
    }

    @Test func aNonEmptyLabelAttributePassesThroughAndOtherTypesDoNot() {
        #expect(AXValueRendering.label(from: "AllClear" as CFString) == "AllClear")
        #expect(AXValueRendering.label(from: " " as CFString) == " ")
        // A label is a string; a number/boolean answer is not one, and guessing a
        // rendering for it would invent a label the app never gave.
        #expect(AXValueRendering.label(from: 42 as CFNumber) == nil)
        #expect(AXValueRendering.label(from: kCFBooleanTrue) == nil)
    }

    @Test func theWalkerCarriesDescriptionAndIdentifierFromTheProviderIntoTheNode() {
        // The provider seam, end to end: whatever a provider reports for these two
        // attributes must reach the built `AXNode` unchanged, or every surface
        // below is working from a tree that has already lost the label.
        let fixture = [window([
            AXNode(role: kAXButtonRole, description: "Clear", identifier: "AllClear",
                   frame: rect(), actionable: true),
        ])]
        let result = AXTreeWalker.walk(provider: FakeTreeProvider(before: fixture))

        #expect(result.nodes == fixture)
        #expect(result.nodes[0].children[0].description == "Clear")
        #expect(result.nodes[0].children[0].identifier == "AllClear")
    }

    @Test func anElementWithoutTheseAttributesReportsNilForBoth() {
        let node = AXNode(role: kAXButtonRole, title: "Save", actionable: true)
        #expect(node.description == nil)
        #expect(node.identifier == nil)
    }
}

// MARK: - Text label priority and provenance

@Suite struct SnapshotLabelRenderingTests {
    @Test func titleWinsOverEveryOtherLabelAndIsRenderedUnmarked() {
        let node = AXNode(role: kAXButtonRole, title: "Save", value: "v",
                          description: "Save the document", identifier: "SaveButton",
                          frame: rect(), actionable: true)
        #expect(SnapshotText.line(for: node, ref: "e1", indent: 0) == "AXButton \"Save\" #e1")
    }

    @Test func valueLabelsATitlelessElementAndIsRenderedUnmarked() {
        // Pinned pre-existing precedence: a control's VALUE is its content, and a
        // static description must never be shown in place of what a field holds.
        let node = AXNode(role: kAXTextFieldRole, value: "typed text",
                          description: "Search", identifier: "SearchField",
                          frame: rect(), actionable: true)
        #expect(SnapshotText.line(for: node, ref: "e1", indent: 0) == "AXTextField \"typed text\" #e1")
    }

    @Test func descriptionLabelsAnElementWithNoTitleOrValueAndIsMarked() {
        let node = descriptionOnlyButton("Clear")
        #expect(SnapshotText.line(for: node, ref: "e1", indent: 0) == "AXButton \"Clear\"@desc #e1")
    }

    @Test func identifierLabelsAnElementWithNoOtherLabelAndIsMarked() {
        let node = identifierOnlyButton("Seven")
        #expect(SnapshotText.line(for: node, ref: "e5", indent: 0) == "AXButton \"Seven\"@id #e5")
    }

    @Test func descriptionOutranksIdentifierWhenBothArePresent() {
        // The description is the user-visible label; the identifier is a developer
        // string, so it is the LAST resort, not a peer.
        let node = AXNode(role: kAXButtonRole, description: "Delete", identifier: "AllClear",
                          frame: rect(), actionable: true)
        #expect(SnapshotText.line(for: node, ref: "e1", indent: 0) == "AXButton \"Delete\"@desc #e1")
    }

    @Test func anElementWithNoLabelAtAllStillRendersTheEmptySlotUnmarked() {
        let node = AXNode(role: kAXGroupRole, frame: rect())
        #expect(SnapshotText.line(for: node, ref: nil, indent: 1) == "  AXGroup \"\"")
    }

    @Test func theMarkerSitsInsideTheLabelSlotBeforeRefAndDisabled() {
        // Grammar check: the marker binds to the label (no space), and the ref and
        // disabled tokens keep their positions after it.
        let node = AXNode(role: kAXButtonRole, subrole: "AXCloseButton", identifier: "Close",
                          frame: rect(), enabled: false, actionable: true)
        #expect(SnapshotText.line(for: node, ref: "e7", indent: 2)
            == "    AXButton [AXCloseButton] \"Close\"@id #e7 [disabled]")
    }

    @Test func aTitleBearingTreeRendersByteIdenticallyWhetherOrNotLabelsExist() {
        // The hard requirement: adding label SOURCES must not move a single byte of
        // a tree whose nodes all carry titles. The two trees differ ONLY in the new
        // attributes, so an identical rendering is the proof.
        let plain = [window([
            AXNode(role: kAXButtonRole, title: "OK", frame: rect(), actionable: true),
            AXNode(role: kAXStaticTextRole, title: "Ready", frame: rect()),
        ], title: "Doc")]
        let labelled = [window([
            AXNode(role: kAXButtonRole, title: "OK", description: "Confirm", identifier: "OKButton",
                   frame: rect(), actionable: true),
            AXNode(role: kAXStaticTextRole, title: "Ready", description: "Status", identifier: "Status",
                   frame: rect()),
        ], title: "Doc")]

        let expected = """
        AXWindow "Doc"
          AXButton "OK" #e1
          AXStaticText "Ready"
        """
        #expect(SnapshotText.render(Snapshot(roots: plain)) == expected)
        #expect(SnapshotText.render(Snapshot(roots: labelled)) == expected)
    }

    @Test func aKeypadOfIdentifierOnlyButtonsRendersDistinguishableAddressableLines() {
        // The regression this feature exists for: before it, every one of these was
        // `AXButton "" #eN` and no agent could tell 7 from x.
        let snapshot = Snapshot(roots: [window([
            identifierOnlyButton("Seven"),
            identifierOnlyButton("Multiply"),
            identifierOnlyButton("AllClear"),
        ])])
        #expect(SnapshotText.render(snapshot) == """
        AXWindow "Untitled"
          AXButton "Seven"@id #e1
          AXButton "Multiply"@id #e2
          AXButton "AllClear"@id #e3
        """)
    }

    @Test func anAppKitSynthesizedIdentifierNeverFillsTheLabelSlot() {
        // AppKit hands nearly every nib-decoded view an `_NS:<n>` identifier
        // (measured: 10 of 11 in the system text editor). Rendering it would put a
        // meaningless, build-unstable string where a name belongs — worse than the
        // empty slot, which at least does not pretend to know something.
        let node = AXNode(role: kAXScrollAreaRole, identifier: "_NS:8", frame: rect())
        #expect(SnapshotText.line(for: node, ref: nil, indent: 0) == "AXScrollArea \"\"")
        #expect(AXLabel.usableIdentifier(of: node) == nil)
    }

    @Test func aRealIdentifierIsStillUsedEvenWhenItLooksTechnical() {
        // Only AppKit's exact synthetic prefix is refused; a developer-set name is
        // a name whatever its spelling.
        let node = AXNode(role: kAXButtonRole, identifier: "NS_ClearButton", frame: rect(), actionable: true)
        #expect(SnapshotText.line(for: node, ref: "e1", indent: 0) == "AXButton \"NS_ClearButton\"@id #e1")
    }

    @Test func aDescriptionStillWinsOverASynthesizedIdentifier() {
        let node = AXNode(role: kAXMenuButtonRole, description: "Document actions", identifier: "_NS:34",
                          frame: rect(), actionable: true)
        #expect(SnapshotText.line(for: node, ref: "e5", indent: 0)
            == "AXMenuButton \"Document actions\"@desc #e5")
    }

    @Test func aLabelIsEscapedOntoOneLineExactlyAsATitleIs() {
        let node = AXNode(role: kAXButtonRole, description: "line1\nline2\tend",
                          frame: rect(), actionable: true)
        let line = SnapshotText.line(for: node, ref: "e1", indent: 0)
        #expect(line == "AXButton \"line1\\nline2\\tend\"@desc #e1")
        #expect(line.split(separator: "\n", omittingEmptySubsequences: false).count == 1)
    }
}

// MARK: - JSON keeps full precision

@Suite struct SnapshotLabelJSONTests {
    @Test func jsonCarriesBothLabelsAsTheirOwnFieldsRightAfterTitle() {
        let node = AXNode(role: kAXButtonRole, title: "T", value: "v",
                          description: "D", identifier: "I", actionable: true)
        #expect(SnapshotJSON.render(Snapshot(roots: [node]))
            == #"[{"role":"AXButton","title":"T","description":"D","identifier":"I","#
                + #""value":"v","ref":"e1","enabled":true,"children":[]}]"#)
    }

    @Test func jsonOmitsALabelFieldThatIsAbsentRatherThanEmittingItEmpty() {
        let node = AXNode(role: kAXButtonRole, identifier: "Seven", actionable: true)
        #expect(SnapshotJSON.render(Snapshot(roots: [node]))
            == #"[{"role":"AXButton","identifier":"Seven","ref":"e1","enabled":true,"children":[]}]"#)
    }

    @Test func anElementWithNeitherLabelKeepsTheUnchangedKeyOrder() {
        // Byte-stability for the machine surface: nothing new appears for an element
        // that carries neither attribute.
        let node = AXNode(role: kAXButtonRole, subrole: "AXCloseButton", title: "Close", value: "v",
                          frame: CGRect(x: 1, y: 2, width: 3, height: 4),
                          enabled: false, actionable: true)
        #expect(SnapshotJSON.render(Snapshot(roots: [node]))
            == #"[{"role":"AXButton","subrole":"AXCloseButton","title":"Close",""#
                + #"value":"v","ref":"e1","enabled":false,"frame":{"x":1,"y":2,"w":3,"h":4},"children":[]}]"#)
    }

    @Test func jsonNamesTheAttributeTheTextSurfaceCollapsedIntoOneLabel() throws {
        // The text line shows `"Delete"@desc` and nothing else; a machine consumer
        // must not have to infer which attribute that was.
        let node = AXNode(role: kAXButtonRole, description: "Delete", identifier: "AllClear",
                          frame: rect(), actionable: true)
        let json = SnapshotJSON.render(Snapshot(roots: [node]))
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        #expect(parsed[0]["description"] as? String == "Delete")
        #expect(parsed[0]["identifier"] as? String == "AllClear")
        #expect(parsed[0]["title"] == nil)
    }
}

// MARK: - Criteria matching

@Suite struct CriteriaLabelMatchingTests {
    private let keypad = [window([
        AXNode(role: kAXButtonRole, identifier: "Seven", frame: rect(), actionable: true),
        AXNode(role: kAXButtonRole, description: "Clear", frame: rect(), actionable: true),
        AXNode(role: kAXStaticTextRole, value: "0", frame: rect()),
    ])]

    @Test func appearsMatchesOnIdentifier() {
        #expect(WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: #"button "Seven""#)), in: keypad))
    }

    @Test func appearsMatchesOnDescription() {
        #expect(WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: #"button "Clear""#)), in: keypad))
    }

    @Test func appearsStillRejectsALabelNoElementCarries() {
        #expect(!WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: #"button "Eight""#)), in: keypad))
    }

    @Test func disappearsIsTheNegationOfTheSameWiderMatch() {
        #expect(!WaitEvaluator.evaluate(.disappears(WaitCriteria(parsing: #"button "Seven""#)), in: keypad))
        #expect(WaitEvaluator.evaluate(.disappears(WaitCriteria(parsing: #"button "Eight""#)), in: keypad))
    }

    @Test func valueEqualsScopesItsSearchByADescriptionOrIdentifierCriteria() {
        let tree = [window([
            AXNode(role: kAXTextFieldRole, value: "42", identifier: "Total", frame: rect(), actionable: true),
            AXNode(role: kAXTextFieldRole, value: "7", identifier: "Subtotal", frame: rect(), actionable: true),
        ])]
        #expect(WaitEvaluator.evaluate(
            .valueEquals("42", of: WaitCriteria(parsing: #"textfield "Total""#)), in: tree
        ))
        #expect(!WaitEvaluator.evaluate(
            .valueEquals("7", of: WaitCriteria(parsing: #"textfield "Total""#)), in: tree
        ))
    }

    @Test func theTextConditionStaysNarrowToStringsAUserCanSee() {
        // `--text` answers "is this visible on screen". A developer identifier is
        // never displayed, so matching it would report text as visible that nobody
        // can read. Title and value still match, exactly as before.
        #expect(!WaitEvaluator.evaluate(.text("Seven"), in: keypad))
        #expect(WaitEvaluator.evaluate(.text("0"), in: keypad))
    }

    @Test func criteriaMatchingStillReachesASynthesizedIdentifier() {
        // Asymmetric on purpose: the label slot hides `_NS:<n>` because a false
        // name misleads, but JSON still publishes the attribute verbatim, so a
        // caller who read it there must be able to address the element with it. An
        // explicit quoted substring is never an accident.
        let tree = [window([AXNode(role: kAXScrollAreaRole, identifier: "_NS:8", frame: rect())])]
        #expect(WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: #"scrollarea "_NS:8""#)), in: tree))
    }

    @Test func readOfSelectsAnElementByItsIdentifier() {
        let tree = [window([
            AXNode(role: kAXGroupRole, identifier: "Answer", frame: rect(), children: [
                AXNode(role: kAXStaticTextRole, value: "56088", frame: rect()),
            ]),
        ])]
        let matched = ReadSelection.elements(in: tree, matching: WaitCriteria(parsing: #"group "Answer""#))
        #expect(matched.count == 1)
        #expect(ElementText.render(matched[0]) == "56088")
    }

    @Test func readByCriteriaReturnsTheTextOfADescriptionLabelledElement() {
        let tree = [window([
            AXNode(role: kAXGroupRole, description: "Result", frame: rect(), children: [
                AXNode(role: kAXStaticTextRole, value: "56088", frame: rect()),
            ]),
        ])]
        #expect(readApp(#"group "Result""#, tree: tree) == .read("56088"))
    }
}

// MARK: - Noise filtering

@Suite struct LabelledNodeNoiseTests {
    @Test func aDescriptionOnlyContainerIsNotTreatedAsEmpty() {
        // An empty container is droppable; a container that carries an accessibility
        // label is not empty — dropping it would delete the only thing naming it.
        #expect(isNoise(AXNode(role: kAXGroupRole, frame: rect())))
        #expect(!isNoise(AXNode(role: kAXGroupRole, description: "Keypad", frame: rect())))
    }

    @Test func anIdentifierOnlyContainerIsNotTreatedAsEmpty() {
        #expect(!isNoise(AXNode(role: kAXGroupRole, identifier: "keypad-grid", frame: rect())))
    }

    @Test func aLabelledDescendantKeepsItsContainerRendered() {
        let container = AXNode(role: kAXGroupRole, frame: rect(), children: [
            AXNode(role: kAXGroupRole, description: "Keypad", frame: rect()),
        ])
        #expect(!isNoise(container))
        #expect(SnapshotText.render(Snapshot(roots: [container])) == """
        AXGroup ""
          AXGroup "Keypad"@desc
        """)
    }

    @Test func theMemoizedMaskAgreesWithTheReferencePredicateOnLabelledContainers() {
        // The O(n) mask and the O(subtree) reference rule must not diverge on the
        // newly non-empty case, or text and JSON would list different nodes.
        let root = AXNode(role: kAXGroupRole, frame: rect(), children: [
            AXNode(role: kAXGroupRole, identifier: "grid", frame: rect()),
            AXNode(role: kAXGroupRole, frame: rect()),
        ])
        let mask = SnapshotNoise.mask(for: root).mask
        #expect(mask.isNoise == isNoise(root))
        #expect(mask.children[0].isNoise == isNoise(root.children[0]))
        #expect(mask.children[1].isNoise == isNoise(root.children[1]))
        #expect(mask.children[0].isNoise == false)
        #expect(mask.children[1].isNoise == true)
    }

    @Test func aSynthesizedIdentifierDoesNotResurrectAnEmptyContainer() {
        // The mirror of the label rule: a wrapper whose ONLY identification is
        // AppKit's nib index is still the contentless wrapper the filter drops, so
        // this feature does not quietly re-flood every Cocoa snapshot.
        #expect(isNoise(AXNode(role: kAXGroupRole, identifier: "_NS:833", frame: rect())))
        #expect(isEffectivelyEmpty([window([AXNode(role: kAXGroupRole, identifier: "_NS:8", frame: rect())])]))
    }

    @Test func aWindowWhoseOnlyContentIsALabelIsNotEffectivelyEmpty() {
        // The AXManualAccessibility fallback fires for a tree that exposes NOTHING.
        // A tree that answered with labels did expose something, just not a title.
        #expect(isEffectivelyEmpty([window([AXNode(role: kAXGroupRole, frame: rect())])]))
        #expect(!isEffectivelyEmpty([window([AXNode(role: kAXGroupRole, description: "Keypad", frame: rect())])]))
        #expect(!isEffectivelyEmpty([window([AXNode(role: kAXGroupRole, identifier: "grid", frame: rect())])]))
    }
}
