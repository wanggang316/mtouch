import Foundation

/// Validates and builds the TARGET MODE of a ref-verb `act` invocation (press /
/// focus / show-menu / set-value), keeping the exclusivity matrix in ONE pure
/// place shared by the CLI (which maps a failure to a usage error, exit 64,
/// BEFORE any AX call) and the MCP surface (which maps it to an invalid-arguments
/// result). Mirrors `ReadGrammar`.
///
/// The verbs target an element two ways, and they are mutually exclusive because
/// each answers "which element" differently: a `<ref>` names ONE element the
/// session already issued, and `--of` names a CRITERIA resolved against a fresh
/// walk of one application — no snapshot, no session, so nothing to go stale.
/// Supplying both would leave the command to pick one, which is exactly the quiet
/// wrong answer this tool refuses.
public enum ActTargetGrammar {
    /// Which element a ref-verb invocation targets. Built only from flags that
    /// already passed `selectionError`.
    public enum Mode: Equatable, Sendable {
        /// `act <verb> <ref>`: one element from the current snapshot session.
        case ref(String)
        /// `act <verb> --of <criteria> --app <bundleId>`: the SINGLE actionable
        /// element matching the criteria in that application.
        case criteria(app: String, criteria: WaitCriteria)
    }

    /// CLI-positional normalization for `set-value`: in `--of` mode there is no
    /// `<ref>`, so the verb's payload is the SOLE positional — which the parser
    /// fills into the ref slot first. Shift it where it belongs so the grammar
    /// judges the invocation the user actually wrote. Verbs that consume no value
    /// (`consumesValue == false`) are left untouched: their sole positional IS a
    /// ref, and pairing it with `--of` must be refused, not reinterpreted.
    public static func normalizedPositionals(
        ref: String?, value: String?, of: String?, consumesValue: Bool
    ) -> (ref: String?, value: String?) {
        guard of != nil, consumesValue, value == nil, let payload = ref else {
            return (ref, value)
        }
        return (nil, payload)
    }

    /// Returns a usage-error message when the target flags are invalid, or nil
    /// when exactly one well-formed mode is selected.
    ///
    /// Rules (all → exit 64): exactly ONE of `<ref>` / `--of`; `--of` requires
    /// `--app`; `--of` must be non-empty; `--wait` requires `--of`; `--interval`
    /// requires `--wait`. (`--app` beside a `<ref>` stays accepted, as it always
    /// was: the ref's session names the application, and the override is recorded
    /// but never consulted.)
    ///
    /// `hasWait` / `hasInterval` report PRESENCE only — the duration values are
    /// parsed by each surface (exit 64 on the CLI, invalid-arguments over MCP)
    /// before they reach here, so this stays a pure shape check.
    public static func selectionError(
        ref: String?, of: String?, app: String?, hasWait: Bool = false, hasInterval: Bool = false
    ) -> String? {
        if let of, of.trimmingCharacters(in: .whitespaces).isEmpty {
            return "--of requires a non-empty criteria, e.g. 'button \"Seven\"' or 'textfield'."
        }
        // The wait rules are checked BEFORE the target rules, so an invocation that
        // clearly means to wait is told what is wrong with the WAIT rather than
        // being sent round a second time by the generic "provide exactly one
        // target" message. With a well-formed `--of` they cannot fire at all.
        if hasWait, of == nil {
            return "--wait is only valid together with --of: a <ref> addresses an element from a "
                + "snapshot that has already been taken, so there is nothing to wait for. Target the "
                + "element with --of <criteria> --app <bundleId> to wait for it to appear, or drop --wait."
        }
        if hasInterval, !hasWait {
            return "--interval is only valid together with --wait: without a wait there is no polling "
                + "to pace. Add --wait <duration>, or drop --interval."
        }
        if ref != nil, of != nil {
            return "<ref> cannot be combined with --of: they are different ways to target an element, "
                + "so pass only one. A <ref> comes from the current snapshot session; --of matches a "
                + "criteria against a fresh walk."
        }
        if ref == nil, of == nil {
            return "provide exactly one target: <ref> from a prior snapshot, or --of <criteria> "
                + "with --app <bundleId> (no snapshot needed)."
        }
        if of != nil, app == nil {
            return "--of requires --app <bundleId>: a criteria is matched inside one application's tree."
        }
        return nil
    }

    /// Build the resolved mode from the flags. Precondition: `selectionError`
    /// returned nil for the same flags.
    public static func makeMode(ref: String?, of: String?, app: String?) -> Mode {
        if let ref { return .ref(ref) }
        guard let of, let app else {
            preconditionFailure("ActTargetGrammar.makeMode requires a validated selection; call selectionError first")
        }
        return .criteria(app: app, criteria: WaitCriteria(parsing: of))
    }
}
