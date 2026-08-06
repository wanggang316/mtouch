import CoreGraphics

/// Byte-stable JSON rendering of a `Snapshot` (hand-built for fixed key order,
/// per the project pattern in `DoctorReport`/`JSONText`). This is the machine
/// view of the SAME filtered snapshot as the text view: it applies `isNoise` so
/// both surfaces list the same nodes and refs, but it does NOT truncate — JSON
/// carries the complete filtered model, geometry included.
///
/// Per-element key order: `role`, `subrole?`, `title?`, `value?`, `ref?`,
/// `enabled`, `frame?`, `scrollPosition?`, `children`. Values are RAW (real
/// characters); `JSONText.string` handles escaping. Secure-field values are
/// masked here TOO — the real secret never appears.
public enum SnapshotJSON {
    public static func render(_ snapshot: Snapshot) -> String {
        let objects = snapshot.roots.enumerated().compactMap { index, root in
            object(for: root, path: [index], snapshot: snapshot)
        }
        return "[" + objects.joined(separator: ",") + "]"
    }

    /// Nil when the node is filtered out as noise; otherwise its JSON object,
    /// with noise-filtered children nested under `children`.
    private static func object(for node: AXNode, path: [Int], snapshot: Snapshot) -> String? {
        if isNoise(node) { return nil }

        var fields: [String] = ["\"role\":\(JSONText.string(node.role))"]
        if let subrole = node.subrole { fields.append("\"subrole\":\(JSONText.string(subrole))") }
        if let title = node.title { fields.append("\"title\":\(JSONText.string(title))") }
        if let value = SecureField.renderedValue(of: node) {
            fields.append("\"value\":\(JSONText.string(value))")
        }
        if let ref = snapshot.ref(atPath: path) { fields.append("\"ref\":\(JSONText.string(ref))") }
        fields.append("\"enabled\":\(node.enabled)")
        if let frame = node.frame { fields.append("\"frame\":\(rect(frame))") }
        if node.isScrollArea, let scroll = node.scrollPosition {
            fields.append("\"scrollPosition\":\(point(scroll))")
        }

        let children = node.children.enumerated().compactMap { index, child in
            object(for: child, path: path + [index], snapshot: snapshot)
        }
        fields.append("\"children\":[\(children.joined(separator: ","))]")

        return "{" + fields.joined(separator: ",") + "}"
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
