import Foundation

/// Validates and builds the ADDRESSING MODE of a `read` invocation, keeping the
/// exclusivity matrix in ONE pure place shared by the CLI (which maps a failure to
/// a usage error, exit 64, BEFORE any AX call) and the MCP surface (which maps it
/// to an invalid-arguments result). Mirrors `WaitGrammar`.
///
/// `read` addresses text three ways, and they are mutually exclusive because each
/// answers "which text" differently: a `<ref>` names ONE element the session
/// already issued, `--of` names a CRITERIA to match inside one application, and a
/// bare `--app` names the whole application. Supplying two would leave the command
/// to pick one, which is exactly the quiet wrong answer this tool refuses.
public enum ReadGrammar {
    /// Which text a `read` invocation addresses. Built only from flags that already
    /// passed `selectionError`.
    public enum Mode: Equatable, Sendable {
        /// `read <ref>`: the subtree of one element from the current session.
        case ref(String)
        /// `read --app <bundleId> --of <criteria>`: every element matching the
        /// criteria, in document order.
        case criteria(app: String, criteria: WaitCriteria)
        /// `read --app <bundleId>`: every window of the application.
        case wholeApp(app: String)
    }

    /// Returns a usage-error message when the addressing flags are invalid, or nil
    /// when exactly one well-formed mode is selected.
    ///
    /// Rules (all → exit 64): at most ONE of `<ref>` / `--of` / bare `--app`;
    /// `--of` and bare-app mode both require `--app`; `--of` must be non-empty.
    /// (`--pid` without `--app` is refused one layer up, by the shared app-option
    /// group and its MCP counterpart, so it reads identically for every command.)
    public static func selectionError(ref: String?, of: String?, app: String?) -> String? {
        if let of, of.trimmingCharacters(in: .whitespaces).isEmpty {
            return "--of requires a non-empty criteria, e.g. 'group \"answer\"' or 'textarea'."
        }
        if ref != nil {
            // A ref carries its own application (the session recorded it), so an
            // app-scoped flag alongside it is not a narrowing — it is a second,
            // contradictory answer to "which text".
            var conflicting: [String] = []
            if of != nil { conflicting.append("--of") }
            if app != nil { conflicting.append("--app") }
            guard conflicting.isEmpty else {
                return "<ref> cannot be combined with \(conflicting.joined(separator: " and ")): they are "
                    + "different ways to address a read, so pass only one. A <ref> already names its "
                    + "application (the snapshot session recorded it)."
            }
            return nil
        }
        if app == nil {
            if of != nil {
                return "--of requires --app <bundleId>: a criteria is matched inside one application's tree."
            }
            return "provide exactly one addressing mode: <ref> from a prior snapshot, "
                + "'--app <bundleId> --of <criteria>', or '--app <bundleId>' for the whole application."
        }
        return nil
    }

    /// Build the resolved mode from the flags. Precondition: `selectionError`
    /// returned nil for the same flags.
    public static func makeMode(ref: String?, of: String?, app: String?) -> Mode {
        if let ref { return .ref(ref) }
        guard let app else {
            preconditionFailure("ReadGrammar.makeMode requires a validated selection; call selectionError first")
        }
        if let of { return .criteria(app: app, criteria: WaitCriteria(parsing: of)) }
        return .wholeApp(app: app)
    }
}
