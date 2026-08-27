import Foundation

/// A wait CRITERIA: an accessibility role, optionally narrowed by a quoted
/// substring matched over an element's title, value, description, and
/// identifier — every string that identifies it, so a control labelled only by
/// `AXDescription`/`AXIdentifier` is addressable by the very name the snapshot
/// printed for it.
///
/// The grammar is `<role> ["<substring>"]`, e.g. `textarea` or `button "Save"`.
/// Friendly role names map to AX roles (`textarea` → `AXTextArea`); a raw AX
/// role (`AXButton`) passes through unchanged; anything else is used LITERALLY.
/// A misspelled/non-matching role is therefore NOT a usage error — it simply
/// never matches, so the wait times out (exit 4) rather than failing to parse.
public struct WaitCriteria: Equatable, Sendable {
    /// Resolved AX role matched literally against `AXNode.role`.
    public let role: String
    /// Optional substring required within an element's title, value,
    /// description, or identifier; nil means role alone is enough.
    public let substring: String?

    public init(role: String, substring: String? = nil) {
        self.role = role
        self.substring = substring
    }

    /// Parses `<role> ["<substring>"]`. Tolerant by design (see the type doc): an
    /// unknown role is kept verbatim, never rejected. The first `"..."` pair is
    /// taken as the substring; the text before it is the role.
    public init(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.firstIndex(of: "\""),
           let close = trimmed[trimmed.index(after: open)...].firstIndex(of: "\"") {
            let rolePart = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            self.role = WaitCriteria.resolveRole(rolePart)
            self.substring = String(trimmed[trimmed.index(after: open)..<close])
        } else {
            self.role = WaitCriteria.resolveRole(trimmed)
            self.substring = nil
        }
    }

    /// Human-readable form for diagnostics, echoing the criteria as given.
    public var description: String {
        if let substring { return "\(role) \"\(substring)\"" }
        return role
    }

    /// Friendly role name → AX role. Covers the roles an agent is likely to name;
    /// the raw AX role is always also accepted (see `resolveRole`). Keys are
    /// lowercased for a case-insensitive lookup.
    static let friendlyRoles: [String: String] = [
        "textarea": "AXTextArea",
        "textfield": "AXTextField",
        "button": "AXButton",
        "window": "AXWindow",
        "sheet": "AXSheet",
        "menu": "AXMenu",
        "menuitem": "AXMenuItem",
        "menubar": "AXMenuBar",
        "menubaritem": "AXMenuBarItem",
        "checkbox": "AXCheckBox",
        "radiobutton": "AXRadioButton",
        "popupbutton": "AXPopUpButton",
        "combobox": "AXComboBox",
        "statictext": "AXStaticText",
        "group": "AXGroup",
        "image": "AXImage",
        "link": "AXLink",
        "slider": "AXSlider",
        "toolbar": "AXToolbar",
        "scrollarea": "AXScrollArea",
        "tabgroup": "AXTabGroup",
        "list": "AXList",
        "row": "AXRow",
        "cell": "AXCell",
        "table": "AXTable",
        "outline": "AXOutline",
    ]

    /// Resolve a role token: a raw `AX…` role passes through; a known friendly
    /// name maps to its AX role; anything else is returned verbatim (matched
    /// literally, so a typo simply never matches).
    static func resolveRole(_ token: String) -> String {
        if token.hasPrefix("AX") { return token }
        return friendlyRoles[token.lowercased()] ?? token
    }
}

/// The single condition a `wait` invocation polls for. Exactly one is selected
/// from the pinned condition flags (see `WaitGrammar`).
public enum WaitCondition: Equatable, Sendable {
    /// Succeed once ≥1 element matches the criteria.
    case appears(WaitCriteria)
    /// Succeed once NO element matches the criteria (vacuously true if none ever
    /// matched).
    case disappears(WaitCriteria)
    /// Succeed once the substring appears in ANY element's title or value
    /// (window titles included).
    case text(String)
    /// Succeed once an element's value EQUALS the string (unicode-normalization
    /// insensitive). `of` restricts the search to elements matching a criteria.
    case valueEquals(String, of: WaitCriteria?)
    /// Succeed once the watched subtree has STOPPED CHANGING: its digest has been
    /// continuously unchanged for `window`. `of` scopes the digest to the elements
    /// matching a criteria (nil ⇒ the whole tree).
    ///
    /// Unlike its siblings this is NOT decidable from a single tree — quiescence is
    /// a property of a sequence of observations over time — so `WaitPipeline` routes
    /// it through `QuiescenceTracker` instead of `WaitEvaluator`.
    case stable(of: WaitCriteria?, window: TimeInterval)

    /// Human-readable phrasing for the timeout diagnostic.
    public var description: String {
        switch self {
        case let .appears(criteria):
            return "an element matching \(criteria.description) to appear"
        case let .disappears(criteria):
            return "an element matching \(criteria.description) to disappear"
        case let .text(string):
            return "the text \"\(string)\" to appear"
        case let .valueEquals(string, criteria):
            if let criteria {
                return "an element matching \(criteria.description) whose value equals \"\(string)\""
            }
            return "an element whose value equals \"\(string)\""
        case let .stable(criteria, window):
            let scope = criteria.map { "elements matching \($0.description)" } ?? "the accessibility tree"
            return "\(scope) to stop changing for \(WaitPipeline.formatDuration(window))"
        }
    }
}

/// Pure predicate layer: evaluates a `WaitCondition` against a walked tree with
/// NO AX/TCC access, so every condition is unit-testable with literal `AXNode`
/// fixtures.
public enum WaitEvaluator {
    /// Whether `condition` can be decided from ONE walked tree. Every condition can
    /// except `.stable`, whose subject is the sequence of trees over time; the
    /// pipeline routes that one to `QuiescenceTracker` instead. Exposed so the
    /// routing decision is a named, testable rule rather than a `switch` buried in
    /// the pipeline.
    public static func isStateless(_ condition: WaitCondition) -> Bool {
        if case .stable = condition { return false }
        return true
    }

    /// Whether `condition` holds over the given root nodes (windows + menu bar).
    ///
    /// `.stable` always answers FALSE here: a single tree is never evidence that a
    /// UI has stopped changing. The pipeline never asks (see `isStateless`), and
    /// "not met" is the safe answer for any caller that does — it keeps waiting
    /// rather than declaring an unobserved sequence settled.
    public static func evaluate(_ condition: WaitCondition, in roots: [AXNode]) -> Bool {
        let all = roots.flatMap(\.flattened)
        switch condition {
        case let .appears(criteria):
            return all.contains { matches($0, criteria) }
        case let .disappears(criteria):
            return !all.contains { matches($0, criteria) }
        case let .text(string):
            return all.contains { textContains($0, string) }
        case let .valueEquals(string, criteria):
            let target = normalized(string)
            return all.contains { node in
                if let criteria, !matches(node, criteria) { return false }
                guard let value = node.value else { return false }
                return normalized(value) == target
            }
        case .stable:
            return false
        }
    }

    /// Whether a node satisfies a criteria: role matched literally, and — when a
    /// substring is given — that substring present in any of the node's
    /// IDENTIFYING strings (see `criteriaContains`).
    static func matches(_ node: AXNode, _ criteria: WaitCriteria) -> Bool {
        guard node.role == criteria.role else { return false }
        guard let substring = criteria.substring else { return true }
        return criteriaContains(node, substring)
    }

    /// Whether the substring appears in ANY string that identifies the node:
    /// title, value, description (the accessibility label), or identifier (the
    /// developer-set identity).
    ///
    /// Wider than `textContains` on purpose. A criteria's job is to ADDRESS an
    /// element, and the substring an agent has to work with is whatever the
    /// snapshot showed it — which, for the many controls that expose no title, is
    /// the description or the identifier. Searching only title+value would make
    /// `button "Seven"` un-writable for exactly the elements that most need
    /// addressing by name.
    static func criteriaContains(_ node: AXNode, _ substring: String) -> Bool {
        if textContains(node, substring) { return true }
        if let description = node.description, description.contains(substring) { return true }
        if let identifier = node.identifier, identifier.contains(substring) { return true }
        return false
    }

    /// Whether the substring appears in a node's title or value — the strings a
    /// user can actually SEE. Deliberately narrower than `criteriaContains`: this
    /// backs `--text` ("wait until this text is visible"), and an identifier is a
    /// developer string that is never displayed, so matching it here would report
    /// text as visible that no one can read.
    static func textContains(_ node: AXNode, _ substring: String) -> Bool {
        if let title = node.title, title.contains(substring) { return true }
        if let value = node.value, value.contains(substring) { return true }
        return false
    }

    /// NFC-fold so canonically equivalent strings (e.g. precomposed "é" vs the
    /// decomposed "e" + combining accent) compare equal for `--value-equals`.
    static func normalized(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping
    }
}
