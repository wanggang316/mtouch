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
    // Pinned: actionable nodes always render (independent of enabled / size).
    if node.actionable { return false }

    let isScrollBar = node.role == kAXScrollBarRole
    let isZeroSize = node.frame.map { $0.width == 0 || $0.height == 0 } ?? false
    let isContainer = SnapshotNoise.containerRoles.contains(node.role)

    // Only scrollbars, zero-area elements, and empty containers are candidates;
    // everything else (text, images, windows, …) is kept.
    guard isScrollBar || isZeroSize || isContainer else { return false }

    // A candidate that guards an actionable descendant is kept regardless.
    if SnapshotNoise.hasActionableDescendant(node) { return false }

    if isScrollBar || isZeroSize { return true }
    // Container candidate: drop only when it holds no text anywhere either.
    return !SnapshotNoise.subtreeHasText(node)
}

/// Helpers backing `isNoise`, grouped for the validator to point at.
enum SnapshotNoise {
    /// Structural wrappers with no inherent meaning of their own: droppable when
    /// they hold neither actionable content nor text.
    static let containerRoles: Set<String> = [kAXGroupRole, kAXUnknownRole]

    static func hasActionableDescendant(_ node: AXNode) -> Bool {
        node.children.contains { $0.actionable || hasActionableDescendant($0) }
    }

    /// Whether any node in the subtree (including `node`) carries readable text,
    /// per the walker's `nodeHasTextContent` notion.
    static func subtreeHasText(_ node: AXNode) -> Bool {
        node.flattened.contains(where: nodeHasTextContent)
    }
}
