/// Validates and builds the `wait` condition from its raw flags, keeping the
/// pinned exclusivity matrix in ONE pure place shared by the CLI (which maps a
/// failure to a usage error, exit 64, BEFORE any AX call) and its unit tests.
public enum WaitGrammar {
    /// Returns a usage-error message when the condition-flag combination is
    /// invalid, or nil when exactly one well-formed condition is selected.
    ///
    /// Rules (all → exit 64): exactly ONE of `--appears` / `--disappears` /
    /// `--text` / `--value-equals`; `--of` only with `--value-equals`; `--text`
    /// must be non-empty.
    public static func selectionError(
        appears: String?,
        disappears: String?,
        text: String?,
        valueEquals: String?,
        of: String?
    ) -> String? {
        let selected = [appears, disappears, text, valueEquals].compactMap { $0 }.count
        if selected == 0 {
            return "provide exactly one condition: --appears, --disappears, --text, or --value-equals."
        }
        if selected > 1 {
            return "provide only one condition; --appears, --disappears, --text, and "
                + "--value-equals are mutually exclusive."
        }
        if of != nil, valueEquals == nil {
            return "--of is only valid together with --value-equals."
        }
        if let text, text.isEmpty {
            return "--text requires a non-empty string."
        }
        return nil
    }

    /// Build the resolved condition from the flags. Precondition:
    /// `selectionError` returned nil for the same flags.
    public static func makeCondition(
        appears: String?,
        disappears: String?,
        text: String?,
        valueEquals: String?,
        of: String?
    ) -> WaitCondition {
        if let appears { return .appears(WaitCriteria(parsing: appears)) }
        if let disappears { return .disappears(WaitCriteria(parsing: disappears)) }
        if let text { return .text(text) }
        if let valueEquals {
            return .valueEquals(valueEquals, of: of.map { WaitCriteria(parsing: $0) })
        }
        preconditionFailure("WaitGrammar.makeCondition requires a validated condition; call selectionError first")
    }
}
