/// The post-action difference between two accessibility snapshots: what was
/// ADDED, REMOVED, or CHANGED between a PRE snapshot (the session's current
/// state) and a POST tree (freshly walked after an action). Unchanged elements
/// are NOT emitted — a diff is the agent-facing "what your action did".
///
/// The diff is NODE-GRANULAR, mirroring the per-line text grammar: every added,
/// removed, or changed node is an independent `Entry` (an added subtree appears
/// as one entry per node, each on its own `+` line), so text and JSON render the
/// exact same set of nodes. Only nodes that survive `isNoise` participate —
/// scrollbar/zero-size churn never shows up as a change.
public struct Diff: Equatable, Sendable {
    /// One node that appears in the diff, carrying the ref and rendered depth the
    /// renderers need. For ADDED/CHANGED, `node` is the POST state; for REMOVED,
    /// it is the PRE state. `previous` holds the PRE state of a CHANGED node (nil
    /// otherwise) so a consumer can describe the before/after.
    public struct Entry: Equatable, Sendable {
        /// The state to render: POST node for added/changed, the vanished PRE node
        /// for removed.
        public let node: AXNode
        /// The PRE state of a CHANGED node; nil for added/removed.
        public let previous: AXNode?
        /// The node's ref: carried (changed), fresh & continuing (added), or the
        /// now-stale PRE ref (removed). Nil for non-actionable nodes.
        public let ref: String?
        /// Rendered nesting depth, matching the snapshot renderer's indentation.
        public let depth: Int
        /// Structural index path from the roots — the positional match key.
        public let path: [Int]

        public init(node: AXNode, previous: AXNode?, ref: String?, depth: Int, path: [Int]) {
            self.node = node
            self.previous = previous
            self.ref = ref
            self.depth = depth
            self.path = path
        }
    }

    /// Nodes present in POST with no PRE match, in POST pre-order.
    public let added: [Entry]
    /// Nodes present in PRE with no POST match, in PRE pre-order.
    public let removed: [Entry]
    /// Nodes matched across both but whose rendered attributes differ, in POST
    /// pre-order. Each KEEPS its PRE ref.
    public let changed: [Entry]
    /// PRE refs that no longer resolve after the action (their elements were
    /// removed or replaced). The updated session omits them, so a later
    /// `resolve` returns `.stale`; this list records them explicitly.
    public let staleRefs: [String]

    public init(added: [Entry], removed: [Entry], changed: [Entry], staleRefs: [String]) {
        self.added = added
        self.removed = removed
        self.changed = changed
        self.staleRefs = staleRefs
    }

    /// True when nothing renderable changed. When true, the renderers emit an
    /// explicit "no changes" marker — never blank output, never a full tree.
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
}

/// The full output of `DiffEngine.diff(pre:post:)`: the computed `diff` for
/// display AND the `newSnapshot` (POST tree with carried-over + fresh refs) the
/// act layer persists as the session's new current state. Designed so the act
/// layer is just: `diff(pre:post:)` → render `diff` + persist `newSnapshot`.
public struct DiffResult: Equatable, Sendable {
    public let diff: Diff
    public let newSnapshot: Snapshot

    public init(diff: Diff, newSnapshot: Snapshot) {
        self.diff = diff
        self.newSnapshot = newSnapshot
    }
}

// MARK: - Convenience entry points

/// Render a diff to compact, marker-prefixed text (free-function form matching
/// `renderText(_:)`'s style for snapshots). `settled: false` prefixes the
/// "this reading did not settle" marker (see `SettleBudget`).
public func renderDiffText(_ diff: Diff, settled: Bool = true) -> String {
    DiffText.render(diff, settled: settled)
}

/// Render a diff to byte-stable JSON (added/removed/changed node arrays).
/// `settled: false` adds the `"settled":false` field.
public func renderDiffJSON(_ diff: Diff, settled: Bool = true) -> String {
    DiffJSON.render(diff, settled: settled)
}
