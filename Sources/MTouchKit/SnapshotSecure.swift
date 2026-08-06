import ApplicationServices

/// Secure-field masking policy (the named function the validation contract,
/// VAL-SNAP-017, points at). A node is secure when its role OR subrole is
/// `AXSecureTextField`. The field line itself still renders (role + title), but
/// its value is ALWAYS replaced by `mask` — enforced identically for text and
/// JSON (and, later, diffs) so a secret cannot leak through any surface.
public enum SecureField {
    /// Shown in place of a secret. The real value never reaches any output.
    public static let mask = "••••"

    /// The role/subrole that marks a field as holding a secret.
    static let secureIdentifier = kAXSecureTextFieldSubrole

    public static func isSecure(_ node: AXNode) -> Bool {
        node.role == secureIdentifier || node.subrole == secureIdentifier
    }

    /// The value string to render for a node, masking secrets. Returns nil when
    /// the node has no value at all (so callers omit the slot). For a secure
    /// node with any value, returns `mask` — never the underlying secret.
    public static func renderedValue(of node: AXNode) -> String? {
        guard let value = node.value else { return nil }
        return isSecure(node) ? mask : value
    }
}
