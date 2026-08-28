import Foundation

/// Which element a criteria-targeted `act` verb acts on, chosen from a walked
/// tree. Pure and AX-free so the selection rules are unit-testable with literal
/// `AXNode` fixtures.
///
/// The pinned stance: acting is only safe on EXACTLY ONE element. `read --of`
/// returns EVERY match because reading many is harmless; ACTING on "the first
/// match" is the silent-misdelivery class this tool exists to prevent, so several
/// matches are refused and listed, never guessed between.
public enum ActCriteriaSelection {
    /// One matching element: its structural path (the walk's scheme — root index,
    /// then child index per level, the same scheme `LiveElementTree` records its
    /// handles under) and the node itself, for the diagnostics and for the
    /// menu-settle decision.
    public struct Match: Equatable, Sendable {
        public let path: [Int]
        public let node: AXNode

        public init(path: [Int], node: AXNode) {
            self.path = path
            self.node = node
        }
    }

    /// The verdict over the tree's ACTIONABLE matches.
    public enum Verdict: Equatable, Sendable {
        /// Exactly one actionable element matched: act on it.
        case one(Match)
        /// Two or more actionable elements matched (document order): refuse.
        case ambiguous([Match])
        /// No actionable element matched. `nonActionable` counts the elements
        /// that DID satisfy the criteria but cannot be acted on — the hint that
        /// separates "no such element" from "that element is not a control".
        case none(nonActionable: Int)
    }

    /// Selects over EVERY node in the tree, using the SAME per-node predicate
    /// `wait` and `read --of` match with (`WaitEvaluator.matches`, i.e. role plus
    /// `criteriaContains` over title/value/description/identifier).
    ///
    /// Unlike `ReadSelection`, a match's descendants are still visited. Reading
    /// skips them because their text is already inside the ancestor's rendering;
    /// acting must not: the single actionable element may sit INSIDE a matching
    /// inert container, and a nested actionable match must count toward ambiguity
    /// rather than hide behind its ancestor.
    public static func select(_ criteria: WaitCriteria, in roots: [AXNode]) -> Verdict {
        var actionable: [Match] = []
        var nonActionable = 0
        func visit(_ node: AXNode, path: [Int]) {
            if WaitEvaluator.matches(node, criteria) {
                if node.actionable {
                    actionable.append(Match(path: path, node: node))
                } else {
                    nonActionable += 1
                }
            }
            for (index, child) in node.children.enumerated() { visit(child, path: path + [index]) }
        }
        for (index, root) in roots.enumerated() { visit(root, path: [index]) }
        if actionable.count > 1 { return .ambiguous(actionable) }
        guard let sole = actionable.first else { return .none(nonActionable: nonActionable) }
        return .one(sole)
    }
}
