/// Compact, ref-annotated TEXT rendering of a `Snapshot`.
///
/// One node per line: `<indent><role> [subrole] "<title-or-value>" [#ref] [disabled]`.
/// Geometry is intentionally omitted here (it lives in JSON); refs appear only on
/// actionable nodes. Multi-line values are escaped (`\n`, `\t`) so every node
/// stays on a single line.
///
/// `line(for:ref:indent:)` renders ONE node and is deliberately kept public and
/// self-contained so the diff engine can emit added/removed/changed lines in
/// exactly this grammar (prefixing them with its own markers).
public enum SnapshotText {
    /// Emitted when the filtered tree has nothing to render, so output is never
    /// silent/blank (VAL-SNAP-009).
    public static let emptyTreeMarker = "(empty accessibility tree)"

    /// Output budget in rendered lines. Oversized trees truncate LOUDLY
    /// (VAL-SNAP-012) instead of flooding. Actionable (ref-bearing) nodes are
    /// always emitted, even past the budget; only non-actionable nodes are
    /// dropped to fit, and the truncation marker reports how many.
    public static let maxNodes = 1000

    // MARK: Entry point

    public static func render(_ snapshot: Snapshot) -> String {
        let rendered = snapshot.renderedNodes()

        var lines: [String] = []
        var emitted = 0
        var omitted = 0
        for item in rendered {
            let isActionable = item.ref != nil
            if isActionable || emitted < maxNodes {
                lines.append(line(for: item.node, ref: item.ref, indent: item.depth))
                emitted += 1
            } else {
                // Never drop a ref-bearing node to fit; only skip inert nodes.
                omitted += 1
            }
        }

        guard !lines.isEmpty else { return emptyTreeMarker }
        if omitted > 0 { lines.append(truncationMarker(omitted: omitted)) }
        return lines.joined(separator: "\n")
    }

    // MARK: Per-node line (reused by the diff engine)

    /// Renders one node to its single snapshot-text line, with no children.
    /// `ref` is the node's assigned ref (nil for non-actionable nodes); `indent`
    /// is the rendered nesting depth.
    public static func line(for node: AXNode, ref: String?, indent: Int) -> String {
        var tokens: [String] = [node.role]
        if let subrole = node.subrole { tokens.append("[\(subrole)]") }
        tokens.append("\"\(displayString(for: node))\"")
        if let ref { tokens.append("#\(ref)") }
        if !node.enabled { tokens.append("[disabled]") }
        return String(repeating: "  ", count: max(0, indent)) + tokens.joined(separator: " ")
    }

    /// The `<title-or-value>` slot: a human label when available, else the
    /// (masked-if-secure) value. Escaped so it stays on one line.
    static func displayString(for node: AXNode) -> String {
        if let title = node.title, !title.isEmpty {
            return escapeInline(title)
        }
        if let value = SecureField.renderedValue(of: node) {
            return escapeInline(value)
        }
        return ""
    }

    static func truncationMarker(omitted: Int) -> String {
        "... output truncated: \(omitted) non-actionable node(s) omitted "
            + "(budget \(maxNodes) nodes; all refs kept)"
    }

    /// Escapes the characters that would otherwise break the one-line invariant:
    /// backslash (so the escaping is reversible), newline, carriage return, tab.
    static func escapeInline(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

// MARK: - Filtered traversal shared by renderers

/// One node that survives noise filtering, paired with its ref and rendered
/// depth. Produced by `Snapshot.renderedNodes()`.
struct RenderedNode {
    let node: AXNode
    let ref: String?
    let depth: Int
}

extension Snapshot {
    /// Pre-order list of nodes that survive `isNoise`, each with its ref (if
    /// actionable) and rendered depth. Because a noise node has no actionable
    /// descendant, skipping its whole subtree never drops a ref. The path used
    /// for ref lookup indexes the ORIGINAL children, so refs stay exact even as
    /// non-actionable siblings are filtered out.
    func renderedNodes() -> [RenderedNode] {
        var out: [RenderedNode] = []
        func walk(_ node: AXNode, depth: Int, path: [Int]) {
            if isNoise(node) { return }
            out.append(RenderedNode(node: node, ref: ref(atPath: path), depth: depth))
            for (index, child) in node.children.enumerated() {
                walk(child, depth: depth + 1, path: path + [index])
            }
        }
        for (index, root) in roots.enumerated() {
            walk(root, depth: 0, path: [index])
        }
        return out
    }
}
