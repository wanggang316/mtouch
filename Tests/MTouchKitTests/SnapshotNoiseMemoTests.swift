import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixture builders (pure AXNode trees, zero AX/TCC dependency)

private func button(_ title: String) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: rect(), enabled: true, actionable: true)
}

private func staticText(_ text: String) -> AXNode {
    AXNode(role: kAXStaticTextRole, title: text, frame: rect())
}

private func emptyGroup(_ children: [AXNode] = []) -> AXNode {
    AXNode(role: kAXGroupRole, frame: rect(), children: children)
}

private func unknownContainer(_ children: [AXNode] = []) -> AXNode {
    AXNode(role: kAXUnknownRole, frame: rect(), children: children)
}

/// A non-container, non-scrollbar, non-zero-size node: always kept.
private func image(_ title: String? = nil) -> AXNode {
    AXNode(role: "AXImage", title: title, frame: rect())
}

private func zeroSizeImage() -> AXNode {
    AXNode(role: "AXImage", frame: zeroRect())
}

private func scrollBar(_ children: [AXNode] = []) -> AXNode {
    AXNode(role: kAXScrollBarRole, frame: rect(), children: children)
}

private func window(_ children: [AXNode], title: String = "Win") -> AXNode {
    AXNode(role: kAXWindowRole, title: title, frame: rect(), children: children)
}

private func rect(_ w: CGFloat = 100, _ h: CGFloat = 20) -> CGRect {
    CGRect(x: 0, y: 0, width: w, height: h)
}

private func zeroRect() -> CGRect {
    CGRect(x: 0, y: 0, width: 0, height: 0)
}

/// Wraps `leaf` in `depth` nested empty groups, producing a deep chain.
private func deepChain(depth: Int, leaf: AXNode) -> AXNode {
    var node = leaf
    for _ in 0..<depth {
        node = emptyGroup([node])
    }
    return node
}

@Suite struct SnapshotNoiseMemoTests {
    /// A moderately large + deep tree exercising every branch of the filter:
    /// actionable nodes, static text, empty groups, zero-size images, scrollbars,
    /// nested empty containers, and candidates guarding actionable/text descendants.
    private let roots: [AXNode] = [
        window([
            // Deep chain of containers each guarding an actionable leaf -> all kept.
            deepChain(depth: 30, leaf: button("Deep Actionable")),
            // Deep chain of truly empty containers -> all noise.
            deepChain(depth: 30, leaf: emptyGroup()),
            // Deep chain of containers guarding text -> all kept.
            deepChain(depth: 20, leaf: staticText("deep text")),
            // Broad mix of every candidate/non-candidate shape.
            emptyGroup([
                button("A"),
                staticText("t"),
                emptyGroup(),                     // container, no content -> noise
                zeroSizeImage(),                  // zero-size -> noise
                scrollBar(),                      // scrollbar -> noise
                unknownContainer(),               // unknown container, empty -> noise
                unknownContainer([staticText("nested text")]), // has text -> kept
                // Zero-size container guarding an actionable descendant -> kept.
                AXNode(role: kAXGroupRole, frame: zeroRect(), children: [button("Hidden")]),
                // Zero-size container with only text (no actionable) -> still noise
                // (zero-size short-circuits before the text check).
                AXNode(role: kAXGroupRole, frame: zeroRect(), children: [staticText("x")]),
                // Scrollbar guarding an actionable descendant -> kept.
                scrollBar([button("Scroll Child")]),
            ]),
            image("visible image"),               // non-candidate -> kept
            scrollBar(),                           // noise
            zeroSizeImage(),                       // noise
        ]),
        window([staticText("bar")], title: "Second"),
    ]

    /// The correctness guard: the memoized mask's verdict must equal the reference
    /// free `isNoise(_:)` at EVERY node, walked in lockstep by child index.
    @Test func memoizedMaskMatchesReferencePredicateAtEveryNode() {
        for root in roots {
            let mask = SnapshotNoise.mask(for: root).mask
            assertMaskMatches(root, mask)
        }
    }

    private func assertMaskMatches(_ node: AXNode, _ mask: SnapshotNoise.NoiseMask) {
        #expect(mask.isNoise == isNoise(node))
        guard mask.children.count == node.children.count else {
            Issue.record("mask child count \(mask.children.count) != node child count \(node.children.count)")
            return
        }
        for (index, child) in node.children.enumerated() {
            assertMaskMatches(child, mask.children[index])
        }
    }
}
