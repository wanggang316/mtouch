import ApplicationServices
import CoreGraphics

/// Populates `scrollPosition` on scroll-area nodes after a walk.
///
/// No standard AX attribute exposes a scroll area's content offset, so we derive
/// it from the area's `AXScrollBar` children: each scrollbar's `AXValue` is a
/// Double in `0.0...1.0` giving the thumb's fractional position along its axis
/// (0 = start, 1 = end). Orientation is not carried on `AXNode`, but the frame
/// is, so each scrollbar's axis is classified by its frame aspect (wider than
/// tall ⇒ horizontal, else vertical). The result is stored as
/// `scrollPosition = {x: horizontalFraction, y: verticalFraction}`.
///
/// UNIT: normalized `0...1` fractions, NOT points — a missing axis defaults to 0.
/// A scroll area with no readable scrollbars keeps `scrollPosition == nil`.
public enum ScrollEnrichment {
    /// Returns a copy of `nodes` with `scrollPosition` filled in on every
    /// scroll-area node (at any depth) that can derive one.
    public static func enrich(_ nodes: [AXNode]) -> [AXNode] {
        nodes.map(enrich(_:))
    }

    /// Recursively enriches `node` and its subtree. Children are enriched first
    /// so nested scroll areas are handled; then the node itself gains a
    /// `scrollPosition` when it is a scroll area that lacks one and exposes
    /// readable scrollbars.
    public static func enrich(_ node: AXNode) -> AXNode {
        var updated = node
        updated.children = node.children.map(enrich(_:))
        if node.isScrollArea, node.scrollPosition == nil,
           let position = scrollPosition(ofScrollArea: updated) {
            updated.scrollPosition = position
        }
        return updated
    }

    /// Normalized `0...1` scroll position derived from a scroll area's direct
    /// `AXScrollBar` children, or nil when none carry a readable fraction.
    static func scrollPosition(ofScrollArea node: AXNode) -> CGPoint? {
        var horizontal: CGFloat?
        var vertical: CGFloat?
        for child in node.children where child.role == kAXScrollBarRole {
            guard let value = child.value, let fraction = Double(value) else { continue }
            if isHorizontal(child) {
                horizontal = CGFloat(fraction)
            } else {
                vertical = CGFloat(fraction)
            }
        }
        guard horizontal != nil || vertical != nil else { return nil }
        return CGPoint(x: horizontal ?? 0, y: vertical ?? 0)
    }

    /// A scrollbar is horizontal when its frame is wider than it is tall. With no
    /// frame it is treated as vertical (the common case), so a single
    /// unclassifiable bar still contributes a position.
    private static func isHorizontal(_ scrollBar: AXNode) -> Bool {
        guard let frame = scrollBar.frame else { return false }
        return frame.width > frame.height
    }
}
