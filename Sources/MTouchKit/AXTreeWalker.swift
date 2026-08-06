import Foundation

/// Outcome of a tree walk. Carries the nodes plus the observable signals the
/// snapshot CLI and the validation contract (VAL-SNAP-010) key off of.
public struct WalkResult: Equatable, Sendable {
    /// Root nodes: the app's windows plus the menu bar.
    public let nodes: [AXNode]
    /// Whether the AXManualAccessibility fallback was attempted (the first pass
    /// came back effectively empty).
    public let fallbackFired: Bool
    /// Whether the fallback's retry pass became non-empty.
    public let fallbackHelped: Bool
    /// Whether the walk stopped early at the depth cap (partial tree). A hung
    /// target instead degrades individual reads to defaults via the messaging
    /// timeout; this flag specifically marks the depth-cap guard firing.
    public let truncated: Bool

    public init(nodes: [AXNode], fallbackFired: Bool, fallbackHelped: Bool, truncated: Bool) {
        self.nodes = nodes
        self.fallbackFired = fallbackFired
        self.fallbackHelped = fallbackHelped
        self.truncated = truncated
    }
}

/// Depth-first walker over an `AXTreeProvider`. Bounded on two axes: the
/// messaging timeout (provider-level, so a hung app cannot hang a read) and a
/// depth cap (below, guarding pathological depth and cycles — AX element
/// identity is not reliable enough to track a visited set).
public enum AXTreeWalker {
    /// Maximum descent depth. Real AX trees are shallow (tens of levels); this
    /// cap only ever fires on pathological or cyclic trees, where it caps the
    /// walk and sets `truncated` rather than recursing without bound.
    public static let maxDepth = 256

    /// Walks a live application's tree by pid.
    public static func walk(pid: pid_t) -> WalkResult {
        walk(provider: LiveTreeProvider(pid: pid))
    }

    /// Walks any provider. Runs one pass; if it is effectively empty, enables
    /// the AXManualAccessibility fallback EXACTLY ONCE and re-walks. Never loops
    /// beyond that single retry.
    public static func walk<Provider: AXTreeProvider>(provider: Provider) -> WalkResult {
        var truncated = false
        let firstPass = walkOnce(provider: provider, truncated: &truncated)

        guard isEffectivelyEmpty(firstPass) else {
            return WalkResult(nodes: firstPass, fallbackFired: false, fallbackHelped: false, truncated: truncated)
        }

        provider.enableManualAccessibilityFallback()
        let secondPass = walkOnce(provider: provider, truncated: &truncated)
        return WalkResult(
            nodes: secondPass,
            fallbackFired: true,
            fallbackHelped: !isEffectivelyEmpty(secondPass),
            truncated: truncated
        )
    }

    private static func walkOnce<Provider: AXTreeProvider>(
        provider: Provider,
        truncated: inout Bool
    ) -> [AXNode] {
        provider.roots().map { buildNode(provider: provider, element: $0, depth: 0, truncated: &truncated) }
    }

    private static func buildNode<Provider: AXTreeProvider>(
        provider: Provider,
        element: Provider.Element,
        depth: Int,
        truncated: inout Bool
    ) -> AXNode {
        let attributes = provider.attributes(of: element)
        guard depth < maxDepth else {
            truncated = true
            return AXNode(attributes: attributes, children: [])
        }
        let children = provider.children(of: element).map {
            buildNode(provider: provider, element: $0, depth: depth + 1, truncated: &truncated)
        }
        return AXNode(attributes: attributes, children: children)
    }
}
