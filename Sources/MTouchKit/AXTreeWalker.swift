import CoreGraphics
import Foundation

/// Outcome of a tree walk. Carries the nodes plus the observable signals the
/// snapshot CLI and the validation contract (VAL-SNAP-010) key off of.
public struct WalkResult: Equatable, Sendable {
    /// Root nodes: the app's windows plus the menu bar.
    public let nodes: [AXNode]
    /// Root index path (`[0]`, `[1]`, …) -> the owning-window CGWindowID for each
    /// top-level WINDOW root, captured once per root during the walk (the menu bar
    /// and non-live providers contribute none). The snapshot threads this in so
    /// each ref records its owning-window identity (VAL-ACT-011); a window's
    /// descendants inherit their root's id, which the snapshot derives from the
    /// ref's path prefix rather than needing a per-descendant entry here.
    public let windowIDsByPath: [[Int]: CGWindowID]
    /// Whether the AXManualAccessibility fallback was attempted (the first pass
    /// came back effectively empty).
    public let fallbackFired: Bool
    /// Whether the fallback's retry pass became non-empty.
    public let fallbackHelped: Bool
    /// Whether the walk stopped early at the depth cap (partial tree). A hung
    /// target instead degrades individual reads to defaults via the messaging
    /// timeout; this flag specifically marks the depth-cap guard firing.
    public let truncated: Bool

    public init(
        nodes: [AXNode],
        windowIDsByPath: [[Int]: CGWindowID] = [:],
        fallbackFired: Bool,
        fallbackHelped: Bool,
        truncated: Bool
    ) {
        self.nodes = nodes
        self.windowIDsByPath = windowIDsByPath
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
    /// Maximum descent depth. Real AX trees are shallow (tens of levels), so 100
    /// is a generous ceiling that still guards pathological or cyclic trees —
    /// where it caps the walk and sets `truncated` rather than recursing without
    /// bound. Kept this low deliberately: `buildNode` recurses, so the cap also
    /// bounds recursion depth, and 100 frames stay stack-safe on constrained
    /// worker-thread stacks (the swift-testing Task stack, and small-stack
    /// background queues) where a deeper cap can overflow the stack (SIGBUS).
    public static let maxDepth = 100

    /// Walks a live application's tree by pid.
    public static func walk(pid: pid_t) -> WalkResult {
        walk(provider: LiveTreeProvider(pid: pid))
    }

    /// Walks any provider. Runs one pass; if it is effectively empty, enables
    /// the AXManualAccessibility fallback EXACTLY ONCE and re-walks. Never loops
    /// beyond that single retry.
    public static func walk<Provider: AXTreeProvider>(provider: Provider) -> WalkResult {
        var truncated = false
        var windowIDs: [[Int]: CGWindowID] = [:]
        let firstPass = walkOnce(provider: provider, windowIDsByPath: &windowIDs, truncated: &truncated)

        guard isEffectivelyEmpty(firstPass) else {
            return WalkResult(
                nodes: firstPass, windowIDsByPath: windowIDs,
                fallbackFired: false, fallbackHelped: false, truncated: truncated
            )
        }

        provider.enableManualAccessibilityFallback()
        let secondPass = walkOnce(provider: provider, windowIDsByPath: &windowIDs, truncated: &truncated)
        return WalkResult(
            nodes: secondPass,
            windowIDsByPath: windowIDs,
            fallbackFired: true,
            fallbackHelped: !isEffectivelyEmpty(secondPass),
            truncated: truncated
        )
    }

    private static func walkOnce<Provider: AXTreeProvider>(
        provider: Provider,
        windowIDsByPath: inout [[Int]: CGWindowID],
        truncated: inout Bool
    ) -> [AXNode] {
        // Capture each root WINDOW's id once (the menu bar reports nil); descendants
        // inherit it via their path prefix, so only root entries are recorded.
        windowIDsByPath.removeAll()
        return provider.roots().enumerated().map { index, element in
            if let id = provider.windowID(of: element) { windowIDsByPath[[index]] = id }
            return buildNode(provider: provider, element: element, depth: 0, truncated: &truncated)
        }
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
        let children = descendableChildren(provider: provider, ownerRole: attributes.role, of: element).map {
            buildNode(provider: provider, element: $0, depth: depth + 1, truncated: &truncated)
        }
        return AXNode(attributes: attributes, children: children)
    }

    /// The children to actually descend into. Identical to the raw child list
    /// except for menu owners, whose CLOSED submenus are dropped so the snapshot
    /// exposes only what an agent can currently act on (see `MenuDescent`). The
    /// extra child read is gated to menu owners, so the rest of the tree is
    /// untouched.
    ///
    /// Internal (not private) so the act layer's handle-retaining walk
    /// (`LiveElementTree`) indexes children in the EXACT same order the snapshot
    /// used to assign ref paths — otherwise a ref's structural path would not line
    /// up with the live element at re-location time.
    static func descendableChildren<Provider: AXTreeProvider>(
        provider: Provider,
        ownerRole: String,
        of element: Provider.Element
    ) -> [Provider.Element] {
        let children = provider.children(of: element)
        guard MenuDescent.ownsSubmenu(ownerRole: ownerRole) else { return children }
        return children.filter { !MenuDescent.isClosedSubmenu(provider.attributes(of: $0)) }
    }
}
