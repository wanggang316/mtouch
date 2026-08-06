/// Compact, marker-prefixed TEXT rendering of a `Diff`.
///
/// Each entry is rendered by the SAME per-node grammar as the snapshot — it
/// delegates to `SnapshotText.line(for:ref:indent:)`, the single source of that
/// grammar — with a one-character marker + space prefixed: `+` added, `-`
/// removed, `~` changed. So stripping the two-character prefix from any diff line
/// yields exactly the element's snapshot line (byte-compatible role/title/value/
/// ref rendering, same escaping, same masking). Nodes are already noise-filtered
/// by the engine, so scrollbar/zero-size churn never appears here.
public enum DiffText {
    /// Emitted when nothing renderable changed, so output is never silent/blank
    /// and never a full tree.
    public static let noChangesMarker = "(no changes)"

    public static func render(_ diff: Diff) -> String {
        guard !diff.isEmpty else { return noChangesMarker }

        // Fixed section order (+ then - then ~), each in the engine's traversal
        // order, so output is deterministic and byte-stable across runs.
        var lines: [String] = []
        lines += diff.added.map { line("+", $0) }
        lines += diff.removed.map { line("-", $0) }
        lines += diff.changed.map { line("~", $0) }
        return lines.joined(separator: "\n")
    }

    /// One diff line: the marker, a space, then the exact snapshot line for the
    /// node (indent included). The prefix is fixed-width (2 chars) so consumers
    /// can recover the snapshot line by dropping the first two characters.
    static func line(_ marker: String, _ entry: Diff.Entry) -> String {
        marker + " " + SnapshotText.line(for: entry.node, ref: entry.ref, indent: entry.depth)
    }
}
