import CoreGraphics

/// Byte-stable JSON rendering of a `Snapshot` (hand-built for fixed key order,
/// per the project pattern in `DoctorReport`/`JSONText`). This is the machine
/// view of the SAME filtered snapshot as the text view: it applies `isNoise` so
/// both surfaces list the same nodes and refs, but it does NOT truncate — JSON
/// carries the complete filtered model, geometry included.
///
/// Per-element key order: `role`, `subrole?`, `title?`, `description?`,
/// `identifier?`, `value?`, `ref?`, `enabled`, `frame?`, `scrollPosition?`,
/// `children`. Values are RAW (real characters); `JSONText.string` handles
/// escaping. Secure-field values are masked here TOO — the real secret never
/// appears.
///
/// `description` and `identifier` sit immediately after `title` because they are
/// the same KIND of fact — the element's identification — and a machine consumer
/// reading them adjacently never has to guess which attribute the text surface
/// collapsed into its single label slot. Unlike that surface, JSON keeps FULL
/// precision: every attribute the element exposes is its own field, and a field
/// is omitted (not emitted empty) when the attribute is absent, so the key order
/// of an element that carries neither is unchanged.
public enum SnapshotJSON {
    public static func render(_ snapshot: Snapshot) -> String {
        // One O(n) noise pass per root; recursion then reads precomputed verdicts.
        let masks = snapshot.roots.map { SnapshotNoise.mask(for: $0).mask }
        let objects = snapshot.roots.enumerated().compactMap { index, root in
            object(for: root, path: [index], snapshot: snapshot, mask: masks[index])
        }
        return "[" + objects.joined(separator: ",") + "]"
    }

    /// Nil when the node is filtered out as noise; otherwise its JSON object,
    /// with noise-filtered children nested under `children`. Walks the AXNode tree
    /// and its `NoiseMask` in lockstep by child index.
    private static func object(
        for node: AXNode, path: [Int], snapshot: Snapshot, mask: SnapshotNoise.NoiseMask
    ) -> String? {
        if mask.isNoise { return nil }

        var fields = nodeFields(for: node, ref: snapshot.ref(atPath: path))
        let children = node.children.enumerated().compactMap { index, child in
            object(for: child, path: path + [index], snapshot: snapshot, mask: mask.children[index])
        }
        fields.append("\"children\":[\(children.joined(separator: ","))]")

        return "{" + fields.joined(separator: ",") + "}"
    }

    /// The per-node JSON field list (`role` … `scrollPosition`) WITHOUT the
    /// `children` array, factored out so the diff renderer emits node objects in
    /// the SAME shape and key order — a single source for the node grammar, the
    /// way `SnapshotText.line` is the single source for the text grammar. `ref`
    /// is the node's carried/assigned ref (nil to omit). Secure values are masked
    /// here TOO (via `SecureField`), so a secret never leaks through any surface.
    static func nodeFields(for node: AXNode, ref: String?) -> [String] {
        var fields: [String] = ["\"role\":\(JSONText.string(node.role))"]
        if let subrole = node.subrole { fields.append("\"subrole\":\(JSONText.string(subrole))") }
        if let title = node.title { fields.append("\"title\":\(JSONText.string(title))") }
        if let description = node.description {
            fields.append("\"description\":\(JSONText.string(description))")
        }
        if let identifier = node.identifier {
            fields.append("\"identifier\":\(JSONText.string(identifier))")
        }
        if let value = SecureField.renderedValue(of: node) {
            fields.append("\"value\":\(JSONText.string(value))")
        }
        if let ref { fields.append("\"ref\":\(JSONText.string(ref))") }
        fields.append("\"enabled\":\(node.enabled)")
        if let frame = node.frame { fields.append("\"frame\":\(rect(frame))") }
        if node.isScrollArea, let scroll = node.scrollPosition {
            fields.append("\"scrollPosition\":\(point(scroll))")
        }
        return fields
    }

    private static func rect(_ frame: CGRect) -> String {
        "{\"x\":\(JSONText.number(frame.origin.x)),"
            + "\"y\":\(JSONText.number(frame.origin.y)),"
            + "\"w\":\(JSONText.number(frame.size.width)),"
            + "\"h\":\(JSONText.number(frame.size.height))}"
    }

    private static func point(_ point: CGPoint) -> String {
        "{\"x\":\(JSONText.number(point.x)),\"y\":\(JSONText.number(point.y))}"
    }
}
