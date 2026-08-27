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
    /// How many descents this walk REFUSED because the child element was already
    /// on the current root-to-node path — the number of cycles cut in the returned
    /// tree. Zero for every well-formed app. Non-zero is reported, never silent
    /// (see `SnapshotText.cycleMarker`): an agent must be able to tell "this app's
    /// accessibility tree loops on itself" from "this app exposes nothing".
    public let cyclesCut: Int

    public init(
        nodes: [AXNode],
        windowIDsByPath: [[Int]: CGWindowID] = [:],
        fallbackFired: Bool,
        fallbackHelped: Bool,
        truncated: Bool,
        cyclesCut: Int = 0
    ) {
        self.nodes = nodes
        self.windowIDsByPath = windowIDsByPath
        self.fallbackFired = fallbackFired
        self.fallbackHelped = fallbackHelped
        self.truncated = truncated
        self.cyclesCut = cyclesCut
    }
}

/// Depth-first walker over an `AXTreeProvider`. Bounded on three axes: the
/// messaging timeout (provider-level, so a hung app cannot hang a read), CYCLE
/// DETECTION (see `AXCycleGuard` — real shipping apps do expose an element as its
/// own descendant), and a depth cap that stays as the belt-and-braces backstop.
public enum AXTreeWalker {
    /// Maximum descent depth. Real AX trees are shallow (tens of levels), so 100
    /// is a generous ceiling that still guards pathological depth — where it caps
    /// the walk and sets `truncated` rather than recursing without bound. Kept
    /// this low deliberately: `buildNode` recurses, so the cap also bounds
    /// recursion depth, and 100 frames stay stack-safe on constrained
    /// worker-thread stacks (the swift-testing Task stack, and small-stack
    /// background queues) where a deeper cap can overflow the stack (SIGBUS).
    ///
    /// It is NOT the cycle guard: a cyclic tree capped at 100 does not terminate
    /// correctly, it terminates with 100 levels of duplicated garbage that crowds
    /// the real UI out of the rendered snapshot. `AXCycleGuard` is what handles
    /// cycles; this cap remains for everything else.
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
        var cyclesCut = 0
        let firstPass = walkOnce(
            provider: provider, windowIDsByPath: &windowIDs, truncated: &truncated, cyclesCut: &cyclesCut
        )

        guard isEffectivelyEmpty(firstPass) else {
            return WalkResult(
                nodes: firstPass, windowIDsByPath: windowIDs,
                fallbackFired: false, fallbackHelped: false, truncated: truncated, cyclesCut: cyclesCut
            )
        }

        provider.enableManualAccessibilityFallback()
        // `walkOnce` OVERWRITES the count, so what is reported describes the tree
        // actually returned (the retry's) rather than the discarded first pass.
        let secondPass = walkOnce(
            provider: provider, windowIDsByPath: &windowIDs, truncated: &truncated, cyclesCut: &cyclesCut
        )
        return WalkResult(
            nodes: secondPass,
            windowIDsByPath: windowIDs,
            fallbackFired: true,
            fallbackHelped: !isEffectivelyEmpty(secondPass),
            truncated: truncated,
            cyclesCut: cyclesCut
        )
    }

    private static func walkOnce<Provider: AXTreeProvider>(
        provider: Provider,
        windowIDsByPath: inout [[Int]: CGWindowID],
        truncated: inout Bool,
        cyclesCut: inout Int
    ) -> [AXNode] {
        // Capture each root WINDOW's id once (the menu bar reports nil); descendants
        // inherit it via their path prefix, so only root entries are recorded. The id
        // is keyed by the index of the EMITTED root, so it stays attached to its own
        // window even in the (unreachable in practice) case of a cut root.
        windowIDsByPath.removeAll()
        // One guard for the whole pass: it tracks only the CURRENT path (see
        // `AXCycleGuard`), so it empties itself as each root's descent unwinds and
        // roots cannot cut each other. The cut COUNT accumulates across roots.
        var cycle = AXCycleGuard()
        var nodes: [AXNode] = []
        for element in provider.roots() {
            guard let node = buildNode(
                provider: provider, element: element, depth: 0, truncated: &truncated, cycle: &cycle
            ) else { continue }
            if let id = provider.windowID(of: element) { windowIDsByPath[[nodes.count]] = id }
            nodes.append(node)
        }
        cyclesCut = cycle.cyclesCut
        return nodes
    }

    /// The node for `element`, or nil when descending into it would re-enter an
    /// element already on the current path (a cycle). A nil is only ever produced
    /// for a CHILD: at a root the guard is empty, because every descent unwinds it.
    private static func buildNode<Provider: AXTreeProvider>(
        provider: Provider,
        element: Provider.Element,
        depth: Int,
        truncated: inout Bool,
        cycle: inout AXCycleGuard
    ) -> AXNode? {
        let attributes = provider.attributes(of: element)
        guard depth < maxDepth else {
            truncated = true
            return AXNode(attributes: attributes, children: [])
        }
        // Cycle cut: this element is already on the path we arrived by, so entering
        // it would re-walk a subtree we are currently inside of — forever, or (with
        // the depth cap) into `maxDepth` copies of it. It is dropped here rather
        // than emitted a second time, exactly as `descendableChildren` drops a
        // closed submenu, and the refusal is COUNTED so the renderer can say so out
        // loud instead of the tree quietly losing content.
        let identity = provider.identity(of: element)
        guard cycle.enter(identity) else { return nil }
        defer { cycle.leave(identity) }

        let children = descendableChildren(
            provider: provider, ownerRole: attributes.role, of: element
        ).compactMap {
            buildNode(provider: provider, element: $0, depth: depth + 1, truncated: &truncated, cycle: &cycle)
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

// MARK: - Cycle detection

/// The visited set that stops a depth-first AX walk from re-entering an element
/// it is already inside of. Shared by `AXTreeWalker` and the handle-retaining
/// `LiveElementTree` so both descents cut at EXACTLY the same places and their
/// structural paths stay aligned.
///
/// SCOPE — the current root-to-node PATH, not the whole walk. Two properties
/// decide this:
///
///  * It provably terminates. A depth-first descent cannot loop unless some
///    element repeats on the path from the root to the node being expanded;
///    refusing exactly that makes every path a sequence of DISTINCT elements, so
///    its length is bounded by the number of distinct elements the app exposes
///    (and, independently, by `AXTreeWalker.maxDepth`).
///  * It is the NARROWEST rule that does so. A whole-walk visited set would also
///    terminate, but it would over-cut: an accessibility graph legitimately
///    presents the SAME element under two different parents (in the very app that
///    motivated this fix, a menu bar is reachable both as a root and as a child of
///    the application element). De-duplicating that DAG would silently delete a
///    real, reachable, actionable subtree from the snapshot — the same
///    "the real UI is missing" failure this fix exists to remove, only quieter.
///    The goal is to cut cycles, not to de-duplicate a DAG.
///
/// Cost is one hash insert plus one remove per visited element, so the walk stays
/// O(n); the set holds at most one entry per level of the current path.
struct AXCycleGuard {
    private var onPath: Set<AXElementIdentity> = []
    /// How many descents were refused as cycles (counted across the whole pass).
    private(set) var cyclesCut = 0

    /// Marks `identity` as being on the current path. Returns false when it is
    /// ALREADY there — a cycle — counting the cut; the caller must then neither
    /// emit nor descend into the element, and must NOT call `leave` for it.
    ///
    /// A nil identity means the provider cannot vouch for element identity, so no
    /// claim is made and the descent proceeds under the depth cap alone.
    mutating func enter(_ identity: AXElementIdentity?) -> Bool {
        guard let identity else { return true }
        guard onPath.insert(identity).inserted else {
            cyclesCut += 1
            return false
        }
        return true
    }

    /// Drops `identity` from the current path as its descent unwinds, so a
    /// SIBLING subtree may legitimately contain the same element again.
    mutating func leave(_ identity: AXElementIdentity?) {
        guard let identity else { return }
        onPath.remove(identity)
    }
}
