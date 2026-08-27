/// Compact, ref-annotated TEXT rendering of a `Snapshot`.
///
/// One node per line: `<indent><role> [subrole] "<label>"[@src] [#ref] [disabled]`.
/// Geometry is intentionally omitted here (it lives in JSON); refs appear only on
/// actionable nodes. Multi-line values are escaped (`\n`, `\t`) so every node
/// stays on a single line.
///
/// `@src` is the LABEL PROVENANCE marker (see `SnapshotText.label(for:)`), present
/// only when the label did not come from the element's title.
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
        let label = label(for: node)
        tokens.append("\"\(label.text)\"" + (label.source.marker ?? ""))
        if let ref { tokens.append("#\(ref)") }
        if !node.enabled { tokens.append("[disabled]") }
        return String(repeating: "  ", count: max(0, indent)) + tokens.joined(separator: " ")
    }

    /// Where a rendered label came from. The text surface is the token-budgeted,
    /// agent-facing view, so it shows exactly ONE label per node — but an agent
    /// that reads `AXButton "Seven"` must not conclude the button's TITLE is
    /// "Seven" (it has none; the string came from `AXIdentifier`), because that
    /// belief drives what it types into a criteria and what it expects from a
    /// diff. The marker states the provenance in one trailing token, and is
    /// ABSENT for the title case so every title-bearing line is byte-identical to
    /// what this renderer has always emitted.
    enum LabelSource {
        /// `kAXTitleAttribute`, or the node's value — the two sources this
        /// surface has always rendered, and the ones it renders unmarked.
        case titleOrValue
        /// `kAXDescriptionAttribute`, the accessibility label.
        case description
        /// `kAXIdentifierAttribute`, the developer-set identity.
        case identifier

        /// The compact suffix appended directly to the closing quote (no space,
        /// so it reads as part of the label slot rather than as another token).
        var marker: String? {
            switch self {
            case .titleOrValue: return nil
            case .description: return "@desc"
            case .identifier: return "@id"
            }
        }
    }

    /// The label slot: the first available of TITLE → VALUE → DESCRIPTION →
    /// IDENTIFIER, escaped so it stays on one line, paired with its provenance.
    ///
    /// Title and value keep their long-standing precedence: a control's value is
    /// its CONTENT (what a text field holds, what a checkbox is set to) and
    /// showing a static accessibility label in its place would hide the very
    /// thing an agent is reading the tree for. Description and identifier are
    /// consulted only when neither exists — which is exactly the case that made
    /// whole applications unusable, where every control rendered as `""` and no
    /// two of them could be told apart. An AppKit-SYNTHESIZED identifier is not a
    /// name and never fills the slot (see `AXLabel.usableIdentifier`).
    static func label(for node: AXNode) -> (text: String, source: LabelSource) {
        if let title = node.title, !title.isEmpty {
            return (escapeInline(title), .titleOrValue)
        }
        if let value = SecureField.renderedValue(of: node), !value.isEmpty {
            return (escapeInline(value), .titleOrValue)
        }
        if let description = node.description, !description.isEmpty {
            return (escapeInline(description), .description)
        }
        if let identifier = AXLabel.usableIdentifier(of: node) {
            return (escapeInline(identifier), .identifier)
        }
        return ("", .titleOrValue)
    }

    static func truncationMarker(omitted: Int) -> String {
        "... output truncated: \(omitted) non-actionable node(s) omitted "
            + "(budget \(maxNodes) nodes; all refs kept)"
    }

    /// The trailing marker for a walk that had to CUT a cycle, in the same
    /// grammar as `truncationMarker`: an agent must be able to tell "this app's
    /// accessibility tree points back at itself, so a subtree is missing" from
    /// "this app exposes nothing". Appended by `SnapshotPipeline` (the cut is a
    /// fact about the WALK, so it is not derivable from the rendered tree).
    static func cycleMarker(cut: Int) -> String { "... " + cycleReport(cut: cut) }

    /// The bare fact the marker states, so the JSON surface — which has no
    /// line-marker slot — can carry the SAME sentence in its `note` field.
    static func cycleReport(cut: Int) -> String {
        "cycle detected: \(cut) element(s) reappeared inside their own subtree and were "
            + "not re-entered (the repeated occurrence and everything under it is omitted)"
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

/// One node that survives noise filtering, paired with its ref, rendered depth,
/// and structural path. Produced by `Snapshot.renderedNodes()`. The `path` lets
/// the diff engine match nodes positionally across two snapshots using the same
/// filtered view the renderers use.
struct RenderedNode {
    let node: AXNode
    let ref: String?
    let depth: Int
    let path: [Int]
}

extension Snapshot {
    /// Pre-order list of nodes that survive `isNoise`, each with its ref (if
    /// actionable), rendered depth, and structural path. Because a noise node has
    /// no actionable descendant, skipping its whole subtree never drops a ref.
    /// The path indexes the ORIGINAL children, so refs stay exact even as
    /// non-actionable siblings are filtered out.
    func renderedNodes() -> [RenderedNode] {
        var out: [RenderedNode] = []
        func walk(_ node: AXNode, depth: Int, path: [Int], mask: SnapshotNoise.NoiseMask) {
            if mask.isNoise { return }
            out.append(RenderedNode(node: node, ref: ref(atPath: path), depth: depth, path: path))
            for (index, child) in node.children.enumerated() {
                walk(child, depth: depth + 1, path: path + [index], mask: mask.children[index])
            }
        }
        // One O(n) noise pass per root; the walk then reads precomputed verdicts.
        let masks = roots.map { SnapshotNoise.mask(for: $0).mask }
        for (index, root) in roots.enumerated() {
            walk(root, depth: 0, path: [index], mask: masks[index])
        }
        return out
    }
}
