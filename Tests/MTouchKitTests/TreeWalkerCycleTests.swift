import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Cyclic fixture seam (zero AX/TCC dependency)

/// A REFERENCE-typed fixture element, because a value tree cannot express a cycle
/// at all: `AXNode` is a struct, so "a node that is its own child" is unwritable
/// with it. Shipping apps do expose exactly that, so the fixture has to be a
/// graph, not a tree.
private final class CycleElement {
    /// Stable, distinct per element; the provider boxes it as the element's
    /// identity so the walker's visited set is keyed by IDENTITY (never by
    /// role/title, which repeat legitimately everywhere).
    let id: Int
    let attributes: AXAttributes
    var children: [CycleElement] = []

    init(id: Int, attributes: AXAttributes) {
        self.id = id
        self.attributes = attributes
    }
}

/// Vends fixture elements with distinct identities. An instance per test keeps
/// the numbering deterministic without any global mutable state.
private final class CycleGraph {
    private var nextID = 0

    func make(
        role: String,
        title: String? = nil,
        actionable: Bool = false,
        frame: CGRect? = nil
    ) -> CycleElement {
        nextID += 1
        return CycleElement(
            id: nextID,
            attributes: AXAttributes(
                role: role, title: title, frame: frame,
                actionNames: actionable ? [kAXPressAction] : []
            )
        )
    }
}

/// Drives `AXTreeWalker` from a `CycleElement` GRAPH. Identity is reported
/// through the same `AXElementIdentity` box the live walker uses, so the fixture
/// exercises the production identity path rather than a parallel one.
private final class CycleTreeProvider: AXTreeProvider {
    typealias Element = CycleElement

    private let rootElements: [CycleElement]
    private(set) var childReads = 0

    init(roots: [CycleElement]) { rootElements = roots }

    func roots() -> [CycleElement] { rootElements }

    func children(of element: CycleElement) -> [CycleElement] {
        childReads += 1
        return element.children
    }

    func attributes(of element: CycleElement) -> AXAttributes { element.attributes }

    func identity(of element: CycleElement) -> AXElementIdentity? {
        AXElementIdentity(element.id as CFNumber)
    }

    func enableManualAccessibilityFallback() {}
}

/// How many levels of descendants sit below `node` (0 for a leaf).
private func levelsBelow(_ node: AXNode) -> Int {
    1 + (node.children.map(levelsBelow).max() ?? -1)
}

// MARK: - Cycle detection

@Suite struct AXTreeWalkerCycleTests {
    @Test func selfReferentialElementTerminatesAndIsCutOnce() {
        // The measured shape: an application element that lists ITSELF as its own
        // first child, next to real content.
        let graph = CycleGraph()
        let app = graph.make(role: kAXApplicationRole, title: "App")
        let ok = graph.make(role: kAXButtonRole, title: "OK", actionable: true)
        app.children = [app, ok]

        let result = AXTreeWalker.walk(provider: CycleTreeProvider(roots: [app]))

        #expect(result.nodes.count == 1)
        // The self-reference is cut: the application appears ONCE, and its real
        // child survives at the index the cut child vacated.
        #expect(result.nodes[0].children.map(\.title) == ["OK"])
        #expect(result.cyclesCut == 1)
        // Cycle detection is what stopped it — NOT the depth cap. Uncut, this tree
        // descended `maxDepth` levels; now the button is the only level below.
        #expect(result.truncated == false)
        #expect(levelsBelow(result.nodes[0]) == 1)
    }

    @Test func longerCycleTerminatesAndEmitsEachElementOnceAlongThePath() {
        // A -> B -> C -> A: the loop closes three levels down, so a per-path guard
        // (not a "is this my own parent?" check) is required to see it.
        let graph = CycleGraph()
        let a = graph.make(role: kAXWindowRole, title: "A")
        let b = graph.make(role: kAXGroupRole, title: "B")
        let c = graph.make(role: kAXGroupRole, title: "C")
        let leaf = graph.make(role: kAXButtonRole, title: "Go", actionable: true)
        a.children = [b]
        b.children = [c]
        c.children = [a, leaf]

        let result = AXTreeWalker.walk(provider: CycleTreeProvider(roots: [a]))

        let titles = result.nodes.flatMap(\.flattened).compactMap(\.title)
        // Each element on the path appears exactly once; the repeat of A is gone.
        #expect(titles == ["A", "B", "C", "Go"])
        #expect(result.cyclesCut == 1)
        #expect(result.truncated == false)
    }

    @Test func repeatedElementInASIBLINGSubtreeIsNotACycle() {
        // Scope check: the visited set is the current PATH, not the whole walk. The
        // same element under two different parents is a DAG, not a loop, and both
        // occurrences must survive — de-duplicating it would silently delete real,
        // reachable, actionable content.
        let graph = CycleGraph()
        let window = graph.make(role: kAXWindowRole, title: "W")
        let left = graph.make(role: kAXGroupRole, title: "Left")
        let right = graph.make(role: kAXGroupRole, title: "Right")
        let shared = graph.make(role: kAXButtonRole, title: "Shared", actionable: true)
        window.children = [left, right]
        left.children = [shared]
        right.children = [shared]

        let result = AXTreeWalker.walk(provider: CycleTreeProvider(roots: [window]))

        let shown = result.nodes.flatMap(\.flattened).filter { $0.title == "Shared" }
        #expect(shown.count == 2)
        #expect(result.cyclesCut == 0)
    }

    @Test func acyclicTreeIsWalkedExactlyAsBefore() {
        // The guard must be invisible on a normal tree: same shape, nothing cut.
        let graph = CycleGraph()
        let window = graph.make(role: kAXWindowRole, title: "Untitled")
        let group = graph.make(role: kAXGroupRole)
        let button = graph.make(role: kAXButtonRole, title: "OK", actionable: true)
        let text = graph.make(role: kAXStaticTextRole, title: "Hello")
        window.children = [group]
        group.children = [button, text]

        let result = AXTreeWalker.walk(provider: CycleTreeProvider(roots: [window]))

        #expect(result.nodes == [
            AXNode(role: kAXWindowRole, title: "Untitled", children: [
                AXNode(role: kAXGroupRole, children: [
                    AXNode(role: kAXButtonRole, title: "OK", actionable: true),
                    AXNode(role: kAXStaticTextRole, title: "Hello"),
                ]),
            ]),
        ])
        #expect(result.cyclesCut == 0)
    }
}

// MARK: - The user-visible failure: a cyclic root crowding out a real window

/// A cyclic application root with enough repeated content that, WITHOUT the cut,
/// its `maxDepth` expansion overflows the render budget and pushes everything
/// after it out of the output — plus a perfectly normal window as the NEXT root.
/// Returns `[cyclicRoot, window]`.
private func cyclicRootThenWindow() -> [CycleElement] {
    let graph = CycleGraph()
    let app = graph.make(role: kAXApplicationRole, title: "App")
    let menuBars = (0..<2).map { barIndex -> CycleElement in
        let bar = graph.make(role: kAXMenuBarRole)
        bar.children = (0..<6).map {
            graph.make(role: kAXMenuBarItemRole, title: "Menu\(barIndex)-\($0)", actionable: true)
        }
        return bar
    }
    app.children = [app] + menuBars

    let window = graph.make(
        role: kAXWindowRole, title: "Main", frame: CGRect(x: 0, y: 0, width: 800, height: 600)
    )
    let content = graph.make(role: kAXGroupRole, frame: CGRect(x: 0, y: 0, width: 800, height: 560))
    content.children = [
        graph.make(role: kAXStaticTextRole, title: "Ready"),
        graph.make(role: kAXButtonRole, title: "Send", actionable: true),
    ]
    window.children = [content]
    return [app, window]
}

@Suite struct CyclicRootDoesNotCrowdOutSiblingsTests {
    @Test func realWindowStillRendersWithItsRefsAfterACyclicRoot() {
        let result = AXTreeWalker.walk(provider: CycleTreeProvider(roots: cyclicRootThenWindow()))

        // Both roots survive, and the cyclic one collapsed to its real content.
        #expect(result.nodes.count == 2)
        #expect(result.nodes[0].role == kAXApplicationRole)
        #expect(result.nodes[0].children.map(\.role) == [kAXMenuBarRole, kAXMenuBarRole])
        #expect(result.nodes[1].role == kAXWindowRole)
        #expect(result.cyclesCut == 1)

        // Uncut, this root alone expanded to maxDepth * 13 nodes; the whole tree is
        // now smaller than the render budget, so nothing is crowded out.
        let total = result.nodes.flatMap(\.flattened).count
        #expect(total < SnapshotText.maxNodes)

        let snapshot = Snapshot(roots: result.nodes)
        let text = SnapshotPipeline.renderTextOutput(snapshot, note: nil, cyclesCut: result.cyclesCut)

        // The window itself renders (a non-actionable line — the first casualty of
        // an overflowing budget), and so does its content, with a ref.
        #expect(text.contains("AXWindow \"Main\""))
        #expect(text.contains("AXStaticText \"Ready\""))
        let sendRef = snapshot.refs.values.first { $0.title == "Send" }?.ref
        #expect(sendRef != nil)
        #expect(text.contains("AXButton \"Send\" #\(sendRef ?? "")"))
        // Nothing was dropped to fit.
        #expect(!text.contains("output truncated"))
    }

    @Test func refsAreNotBurnedOnRepeatedCopiesOfTheCyclicSubtree() {
        let result = AXTreeWalker.walk(provider: CycleTreeProvider(roots: cyclicRootThenWindow()))
        let snapshot = Snapshot(roots: result.nodes)

        // 12 menu-bar items + 1 button. Uncut, the same menu items were re-issued
        // once per level of the cycle, burning ~1200 refs before the window's.
        #expect(snapshot.refs.count == 13)
    }
}

// MARK: - The cut is reported, never silent

@Suite struct CycleReportingTests {
    @Test func textOutputCarriesTheCycleMarker() {
        let result = AXTreeWalker.walk(provider: CycleTreeProvider(roots: cyclicRootThenWindow()))
        let text = SnapshotPipeline.renderTextOutput(
            Snapshot(roots: result.nodes), note: nil, cyclesCut: result.cyclesCut
        )

        #expect(text.hasSuffix(SnapshotText.cycleMarker(cut: 1)))
        #expect(text.contains("cycle detected: 1 element(s)"))
    }

    @Test func aCycleOverANOTHERWISEEmptyTreeIsDistinguishableFromAnEmptyApp() {
        // The distinction that matters to an agent: "this app's tree points back at
        // itself, so content is missing" must not read as "this app has nothing".
        let graph = CycleGraph()
        let app = graph.make(role: kAXApplicationRole, frame: .zero)
        app.children = [app]

        let result = AXTreeWalker.walk(provider: CycleTreeProvider(roots: [app]))
        let text = SnapshotPipeline.renderTextOutput(
            Snapshot(roots: result.nodes), note: nil, cyclesCut: result.cyclesCut
        )

        #expect(text.contains(SnapshotText.emptyTreeMarker))
        #expect(text.contains("cycle detected"))
    }

    @Test func jsonOutputCarriesTheCycleReportInItsNote() {
        let result = AXTreeWalker.walk(provider: CycleTreeProvider(roots: cyclicRootThenWindow()))
        let json = SnapshotPipeline.renderJSONOutput(
            Snapshot(roots: result.nodes), note: nil, cyclesCut: result.cyclesCut
        )

        #expect(json.contains("\"note\":\"cycle detected: 1 element(s)"))
    }

    @Test func aFallbackNoteAndACycleReportBothSurvive() {
        let snapshot = Snapshot(roots: [AXNode(role: kAXWindowRole, title: "W")])
        let json = SnapshotPipeline.renderJSONOutput(snapshot, note: "fallback fired", cyclesCut: 2)
        #expect(json.contains("\"note\":\"fallback fired; cycle detected: 2 element(s)"))

        let text = SnapshotPipeline.renderTextOutput(snapshot, note: "fallback fired", cyclesCut: 2)
        #expect(text.hasPrefix("note: fallback fired\n"))
        #expect(text.hasSuffix(SnapshotText.cycleMarker(cut: 2)))
    }

    @Test func anAcyclicWalkRendersExactlyTheBareTree() {
        // The regression guard for every pinned snapshot expectation: with nothing
        // cut, the pipeline's output is the renderer's output, byte for byte.
        let snapshot = Snapshot(roots: [
            AXNode(role: kAXWindowRole, title: "W", children: [
                AXNode(role: kAXButtonRole, title: "OK", actionable: true),
            ]),
        ])
        #expect(SnapshotPipeline.renderTextOutput(snapshot, note: nil, cyclesCut: 0) == renderText(snapshot))
        #expect(
            SnapshotPipeline.renderJSONOutput(snapshot, note: nil, cyclesCut: 0)
                == "{\"nodes\":\(renderJSON(snapshot))}"
        )
    }
}

// MARK: - Element identity (CFEqual/CFHash, not pointer identity)

@Suite struct AXElementIdentityTests {
    /// Hermetic: elements are only CREATED and compared — no attribute is ever
    /// read, so this needs neither a TCC grant nor a display.
    @Test func twoHandlesForTheSameElementAreOneIdentity() {
        let first = AXUIElementCreateApplication(999_991)
        let second = AXUIElementCreateApplication(999_991)

        // The crux: `AXUIElement` handles for the same element are separate CF
        // objects, so a pointer-keyed set would hold BOTH and never see the cycle.
        #expect(AXElementIdentity(first) == AXElementIdentity(second))
        #expect(AXElementIdentity(first).hashValue == AXElementIdentity(second).hashValue)
        #expect(Set([AXElementIdentity(first), AXElementIdentity(second)]).count == 1)
    }

    @Test func differentElementsAreDifferentIdentities() {
        let first = AXUIElementCreateApplication(999_991)
        let other = AXUIElementCreateApplication(999_992)

        #expect(AXElementIdentity(first) != AXElementIdentity(other))
        #expect(Set([AXElementIdentity(first), AXElementIdentity(other)]).count == 2)
    }

    @Test func aProviderThatCannotVouchForIdentityFallsBackToTheDepthCap() {
        // `FakeTreeProvider`'s elements are value-typed `AXNode`s with no identity,
        // so it reports nil — and a pathological chain is still bounded, by depth.
        var leaf = AXNode(role: kAXGroupRole)
        for _ in 0..<(AXTreeWalker.maxDepth + 10) {
            leaf = AXNode(role: kAXGroupRole, children: [leaf])
        }
        let provider = FakeTreeProvider(before: [AXNode(role: kAXWindowRole, children: [leaf])])

        let result = AXTreeWalker.walk(provider: provider)

        #expect(provider.identity(of: leaf) == nil)
        #expect(result.truncated == true)
        #expect(result.cyclesCut == 0)
    }
}

// MARK: - The handle-retaining walk cuts in the SAME places

/// A provider whose elements are REAL `AXUIElement` handles — created for
/// synthetic pids and never read from (attributes and children come from the
/// fixture), so no AX/TCC access occurs — wired into an arbitrary graph so a cycle
/// can be expressed against the act layer's walk.
private final class HandleGraphProvider: AXTreeProvider {
    typealias Element = AXUIElement

    private let rootElements: [AXUIElement]
    private let childrenByElement: [AXElementIdentity: [AXUIElement]]
    private let attributesByElement: [AXElementIdentity: AXAttributes]

    init(
        roots: [AXUIElement],
        children: [AXElementIdentity: [AXUIElement]],
        attributes: [AXElementIdentity: AXAttributes]
    ) {
        rootElements = roots
        childrenByElement = children
        attributesByElement = attributes
    }

    func roots() -> [AXUIElement] { rootElements }

    func children(of element: AXUIElement) -> [AXUIElement] {
        childrenByElement[AXElementIdentity(element)] ?? []
    }

    func attributes(of element: AXUIElement) -> AXAttributes {
        attributesByElement[AXElementIdentity(element)] ?? AXAttributes(role: kAXUnknownRole)
    }

    func enableManualAccessibilityFallback() {}
}

@Suite struct LiveElementTreeCycleTests {
    @Test func theHandleWalkCutsWhereTheSnapshotWalkCuts() {
        // app -> [app (cycle), button]: the act layer's walk must produce the same
        // shape as the snapshot walk, or a ref's structural path would address a
        // different element than the one it was assigned to.
        let app = AXUIElementCreateApplication(999_881)
        let button = AXUIElementCreateApplication(999_882)
        let provider = HandleGraphProvider(
            roots: [app],
            children: [AXElementIdentity(app): [app, button]],
            attributes: [
                AXElementIdentity(app): AXAttributes(role: kAXApplicationRole, title: "App"),
                AXElementIdentity(button): AXAttributes(
                    role: kAXButtonRole, title: "OK", actionNames: [kAXPressAction]
                ),
            ]
        )

        let walked = AXTreeWalker.walk(provider: provider)
        let live = LiveElementTree.walk(provider: provider)

        #expect(walked.cyclesCut == 1)
        #expect(live.nodes == walked.nodes)
        // The surviving button sits at index 0 — the slot the cut child vacated —
        // in the derived tree AND in the handle index, so they agree.
        #expect(live.nodes[0].children.map(\.title) == ["OK"])
        #expect(live.attributesByPath[[0, 0]]?.title == "OK")
        #expect(live.elementsByPath[[0, 0]].map { CFEqual($0, button) } == true)
        // Nothing was recorded for the cut occurrence.
        #expect(live.attributesByPath.count == 2)
    }
}
