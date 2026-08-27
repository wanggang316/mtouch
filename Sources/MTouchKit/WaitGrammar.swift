import Foundation

/// Validates and builds the `wait` condition from its raw flags, keeping the
/// pinned exclusivity matrix in ONE pure place shared by the CLI (which maps a
/// failure to a usage error, exit 64, BEFORE any AX call) and its unit tests.
public enum WaitGrammar {
    /// How long `--stable` requires the digest to stay unchanged when
    /// `--stable-for` is omitted. Half a second is long enough to outlast the
    /// frame-to-frame churn of a streaming/animating UI, and short enough that a
    /// genuinely settled UI is not made to sit and wait.
    public static let defaultStableWindow: TimeInterval = 0.5

    /// Returns a usage-error message when the condition-flag combination is
    /// invalid, or nil when exactly one well-formed condition is selected.
    ///
    /// Rules (all → exit 64): exactly ONE of `--appears` / `--disappears` /
    /// `--text` / `--value-equals` / `--stable`; `--of` only with `--value-equals`
    /// or `--stable`; `--text` must be non-empty; `--stable-for` only with
    /// `--stable`; the EFFECTIVE quiet window never LONGER than `--timeout`.
    ///
    /// That last rule is checked against the effective window — the explicit
    /// `--stable-for` or, when omitted, `defaultStableWindow` — so that
    /// `--stable --timeout 200ms` is refused up front rather than being accepted
    /// and then timing out with mathematical certainty.
    ///
    /// The duration parameters default to nil so callers that only validate the
    /// classic flag matrix are unaffected; the CLI and MCP surfaces pass them.
    public static func selectionError(
        appears: String?,
        disappears: String?,
        text: String?,
        valueEquals: String?,
        of: String?,
        stable: Bool = false,
        stableFor: TimeInterval? = nil,
        timeout: TimeInterval? = nil
    ) -> String? {
        let selected = [appears, disappears, text, valueEquals].compactMap { $0 }.count + (stable ? 1 : 0)
        if selected == 0 {
            return "provide exactly one condition: --appears, --disappears, --text, --value-equals, or --stable."
        }
        if selected > 1 {
            return "provide only one condition; --appears, --disappears, --text, "
                + "--value-equals, and --stable are mutually exclusive."
        }
        if of != nil, valueEquals == nil, !stable {
            return "--of is only valid together with --value-equals or --stable."
        }
        if let text, text.isEmpty {
            return "--text requires a non-empty string."
        }
        if stableFor != nil, !stable {
            return "--stable-for is only valid together with --stable."
        }
        if stable, let timeout {
            let window = stableFor ?? defaultStableWindow
            if window > timeout {
                let named = stableFor == nil ? "the default --stable-for" : "--stable-for"
                return "\(named) (\(WaitPipeline.formatDuration(window))) cannot be longer than "
                    + "--timeout (\(WaitPipeline.formatDuration(timeout))): the quiet window would never "
                    + "fit inside the wait budget."
            }
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
        of: String?,
        stable: Bool = false,
        stableFor: TimeInterval? = nil
    ) -> WaitCondition {
        if let appears { return .appears(WaitCriteria(parsing: appears)) }
        if let disappears { return .disappears(WaitCriteria(parsing: disappears)) }
        if let text { return .text(text) }
        if let valueEquals {
            return .valueEquals(valueEquals, of: of.map { WaitCriteria(parsing: $0) })
        }
        if stable {
            return .stable(
                of: of.map { WaitCriteria(parsing: $0) },
                window: stableFor ?? defaultStableWindow
            )
        }
        preconditionFailure("WaitGrammar.makeCondition requires a validated condition; call selectionError first")
    }
}
