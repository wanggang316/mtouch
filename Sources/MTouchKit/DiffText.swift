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

    /// Emitted ABOVE the diff when the post-action settle expired before the UI
    /// stopped changing (see `SettleBudget`). It leads, rather than trails, so an
    /// agent reading the first line of the output cannot act on a provisional diff
    /// without knowing it is one — and, like `noChangesMarker`, it is parenthesized
    /// and prefix-free, so it can never be mistaken for a `+`/`-`/`~` diff line.
    public static let unsettledMarker =
        "(unsettled) the interface was still changing when the settle budget expired, so this diff may be "
            + "partial or may describe a state the application has already moved past — "
            + "run 'mtouch snapshot' to read the current state"

    /// Render `diff`. `settled: false` prefixes the honesty marker; the diff body
    /// itself is byte-identical either way, so a consumer that already parses diffs
    /// keeps parsing them.
    public static func render(_ diff: Diff, settled: Bool = true) -> String {
        let body = renderBody(diff)
        return settled ? body : unsettledMarker + "\n" + body
    }

    private static func renderBody(_ diff: Diff) -> String {
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
