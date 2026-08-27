/// Byte-stable JSON rendering of a `Diff`: a stable object with three node
/// arrays, `{"added":[…],"removed":[…],"changed":[…]}`.
///
/// Each element is a node object in the SAME per-node shape as the snapshot JSON
/// — it reuses `SnapshotJSON.nodeFields`, the single source of that grammar, so
/// key order, geometry, and secure-value masking match exactly. The diff is
/// node-granular, so each object carries an empty `children` array (every
/// descendant that also changed is its own entry). A no-change diff renders the
/// same object with three EMPTY arrays — explicit, never blank, never a tree.
public enum DiffJSON {
    /// Render `diff`. `settled: false` adds a trailing `"settled":false` — present
    /// only when it is false, exactly like the trajectory's `verified` and
    /// `deliveryConfirmed`, so a settled diff stays byte-identical to what this
    /// always emitted and its ABSENCE keeps meaning "the ordinary contract held".
    public static func render(_ diff: Diff, settled: Bool = true) -> String {
        let added = diff.added.map(object(_:)).joined(separator: ",")
        let removed = diff.removed.map(object(_:)).joined(separator: ",")
        let changed = diff.changed.map(object(_:)).joined(separator: ",")
        let unsettled = settled ? "" : ",\"settled\":false"
        return "{\"added\":[\(added)],\"removed\":[\(removed)],\"changed\":[\(changed)]\(unsettled)}"
    }

    /// One diff node object, reusing the snapshot's per-node field grammar and
    /// closing with an empty `children` array (node-granular; nested changes are
    /// separate entries). Secure values are masked by `nodeFields`.
    private static func object(_ entry: Diff.Entry) -> String {
        "{" + SnapshotJSON.nodeFields(for: entry.node, ref: entry.ref).joined(separator: ",") + ",\"children\":[]}"
    }
}
