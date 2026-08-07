import ApplicationServices

/// Rendering-only noise predicate (the named function the validation contract
/// points at). Returns true when a node should be OMITTED from the rendered
/// snapshot — text and JSON alike. The underlying `AXNode` model is never
/// mutated; this only gates rendering.
///
/// Two invariants make a noise node always safe to skip together with its whole
/// subtree:
///   1. an ACTIONABLE (ref-bearing) node is never noise — even disabled, even
///      zero-size (the pinned rule); and
///   2. a node that has an actionable descendant is never noise — so refs always
///      render in their real structural context.
/// Therefore a noise node has no actionable descendant, and dropping its subtree
/// cannot drop a ref-bearing element.
public func isNoise(_ node: AXNode) -> Bool {
    SnapshotNoise.computeIsNoise(
        node,
        hasActionableDescendant: SnapshotNoise.hasActionableDescendant(node),
        subtreeHasText: SnapshotNoise.subtreeHasText(node)
    )
}

/// Helpers backing `isNoise`, grouped for the validator to point at.
enum SnapshotNoise {
    /// Structural wrappers with no inherent meaning of their own: droppable when
    /// they hold neither actionable content nor text.
    static let containerRoles: Set<String> = [kAXGroupRole, kAXUnknownRole]

    /// The pure noise decision, given the two subtree facts already computed.
    /// This is the SINGLE source of truth for the filter rule: both the O(subtree)
    /// reference `isNoise(_:)` and the O(n) memoized `mask(for:)` feed it the same
    /// facts, so they cannot diverge on which nodes get dropped.
    static func computeIsNoise(
        _ node: AXNode,
        hasActionableDescendant: Bool,
        subtreeHasText: Bool
    ) -> Bool {
        // Pinned: actionable nodes always render (independent of enabled / size).
        if node.actionable { return false }

        let isScrollBar = node.role == kAXScrollBarRole
        let isZeroSize = node.frame.map { $0.width == 0 || $0.height == 0 } ?? false
        let isContainer = containerRoles.contains(node.role)

        // Only scrollbars, zero-area elements, and empty containers are candidates;
        // everything else (text, images, windows, …) is kept.
        guard isScrollBar || isZeroSize || isContainer else { return false }

        // A candidate that guards an actionable descendant is kept regardless.
        if hasActionableDescendant { return false }

        if isScrollBar || isZeroSize { return true }
        // Container candidate: drop only when it holds no text anywhere either.
        return !subtreeHasText
    }

    static func hasActionableDescendant(_ node: AXNode) -> Bool {
        node.children.contains { $0.actionable || hasActionableDescendant($0) }
    }

    /// Whether any node in the subtree (including `node`) carries readable text,
    /// per the walker's `nodeHasTextContent` notion.
    static func subtreeHasText(_ node: AXNode) -> Bool {
        node.flattened.contains(where: nodeHasTextContent)
    }

    /// A precomputed noise verdict per node, mirroring the AXNode tree shape
    /// (`children` in original order). Renderers walk the AXNode tree and its
    /// `NoiseMask` in lockstep by child index, reading the precomputed `isNoise`
    /// instead of re-deriving the two subtree facts at every node.
    struct NoiseMask {
        let isNoise: Bool
        let children: [NoiseMask]
    }

    /// Compute the noise mask for a subtree in ONE bottom-up (post-order) pass —
    /// O(n) total, no per-node subtree re-walk. Each call returns the node's mask
    /// plus the two aggregated facts its parent needs:
    ///   - `hasActionable`: whether a STRICT descendant is actionable (excludes
    ///     `node` itself), matching `hasActionableDescendant`.
    ///   - `hasText`: whether `node` OR any descendant carries text (includes
    ///     self), matching `subtreeHasText` (which flattens self + descendants).
    /// The node's own `isNoise` is then `computeIsNoise` fed exactly these facts,
    /// so the mask agrees with the reference `isNoise(_:)` at every position.
    static func mask(for node: AXNode) -> (mask: NoiseMask, hasActionable: Bool, hasText: Bool) {
        var childMasks: [NoiseMask] = []
        childMasks.reserveCapacity(node.children.count)
        var hasActionable = false
        var hasText = nodeHasTextContent(node)
        for child in node.children {
            let childResult = mask(for: child)
            childMasks.append(childResult.mask)
            hasActionable = hasActionable || child.actionable || childResult.hasActionable
            hasText = hasText || childResult.hasText
        }
        let isNoise = computeIsNoise(
            node, hasActionableDescendant: hasActionable, subtreeHasText: hasText
        )
        return (NoiseMask(isNoise: isNoise, children: childMasks), hasActionable, hasText)
    }
}
