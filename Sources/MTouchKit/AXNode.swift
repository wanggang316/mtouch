import ApplicationServices
import CoreGraphics
import Foundation

/// One accessibility node — the load-bearing data structure for the snapshot
/// pipeline. The tree walker builds it; the textualizer, diff engine, and
/// wait-condition evaluator all read it. It is a pure value type: no AX handles
/// escape into it, so it can be constructed in tests without any AX/TCC access.
///
/// `frame` follows the project convention (screen POINTS, TOP-LEFT origin; see
/// `AXSupport.frame(of:)`). `actionable` and `isScrollArea` are DERIVED from the
/// raw attributes at construction time (see `init(attributes:children:)`) rather
/// than read directly, so the derivation lives in one audited place.
public struct AXNode: Equatable, Sendable {
    /// `kAXRoleAttribute`, e.g. "AXButton". Never nil — falls back to
    /// `kAXUnknownRole` when the element cannot report a role.
    public var role: String
    /// `kAXSubroleAttribute`, e.g. "AXCloseButton"; nil when absent.
    public var subrole: String?
    /// `kAXTitleAttribute`; nil when absent.
    public var title: String?
    /// `kAXValueAttribute` rendered to a string (see `AXValueRendering`); nil
    /// when absent or of a type not rendered at this layer.
    public var value: String?
    /// `kAXDescriptionAttribute` — the ACCESSIBILITY LABEL; nil when absent or
    /// empty. A great many macOS controls put their user-visible name here and
    /// expose no title, so this is a first-class label source, not a footnote
    /// (see `SnapshotText.label(for:)`).
    public var description: String?
    /// `kAXIdentifierAttribute` — the developer-set, non-localized identity of a
    /// control; nil when absent or empty. Last-resort label, and the only one a
    /// control with neither title nor description has.
    public var identifier: String?
    /// Element frame; nil when position/size are unreadable.
    public var frame: CGRect?
    /// `kAXEnabledAttribute`; defaults to true when the attribute is absent.
    /// Recorded, never a reason to drop an element: a disabled control is still
    /// `actionable` (an agent may want to observe or await it becoming enabled).
    public var enabled: Bool
    /// Whether an agent could act on this element. Derived from role or a
    /// supported `AXPress` action — INDEPENDENT of `enabled`.
    public var actionable: Bool
    /// Whether this element is a scroll container (role is `AXScrollArea`, or it
    /// exposes a scroll position).
    public var isScrollArea: Bool
    /// Scroll offset for scroll containers, when derivable; nil otherwise.
    public var scrollPosition: CGPoint?
    public var children: [AXNode]

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        identifier: String? = nil,
        frame: CGRect? = nil,
        enabled: Bool = true,
        actionable: Bool = false,
        isScrollArea: Bool = false,
        scrollPosition: CGPoint? = nil,
        children: [AXNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.identifier = identifier
        self.frame = frame
        self.enabled = enabled
        self.actionable = actionable
        self.isScrollArea = isScrollArea
        self.scrollPosition = scrollPosition
        self.children = children
    }

    /// Builds a node from raw provider attributes, DERIVING `actionable` and
    /// `isScrollArea`. This is the single place those derivations happen so the
    /// live and fake paths cannot diverge.
    public init(attributes: AXAttributes, children: [AXNode]) {
        self.init(
            role: attributes.role,
            subrole: attributes.subrole,
            title: attributes.title,
            value: attributes.value,
            description: attributes.description,
            identifier: attributes.identifier,
            frame: attributes.frame,
            enabled: attributes.enabled,
            actionable: AXActionable.isActionable(role: attributes.role, actionNames: attributes.actionNames),
            isScrollArea: attributes.role == kAXScrollAreaRole || attributes.scrollPosition != nil,
            scrollPosition: attributes.scrollPosition,
            children: children
        )
    }

    /// This node followed by every descendant, depth-first. Used by emptiness
    /// checks and by consumers that need a flat view of the tree.
    public var flattened: [AXNode] {
        [self] + children.flatMap(\.flattened)
    }
}

// MARK: - Actionable derivation

/// The "actionable" predicate: whether an agent could act on an element.
/// Extracted into a named type because later features (ref assignment, the
/// diff engine) and the validation contract reference this exact set.
public enum AXActionable {
    /// Roles that are inherently actionable regardless of exposed actions.
    /// The web-content role "AXLink" has no HIServices constant, so it appears
    /// as a string literal; the rest use the SDK constants.
    public static let roles: Set<String> = [
        kAXButtonRole,
        kAXMenuItemRole,
        kAXMenuBarItemRole,
        kAXMenuButtonRole,
        kAXCheckBoxRole,
        kAXRadioButtonRole,
        kAXPopUpButtonRole,
        kAXComboBoxRole,
        kAXTextFieldRole,
        kAXTextAreaRole,
        "AXLink",
        kAXTabGroupRole,
        kAXSliderRole,
        kAXIncrementorRole,
        kAXDisclosureTriangleRole,
    ]

    /// Actionable when the role is inherently actionable OR the element exposes
    /// an `AXPress` action. Deliberately ignores `enabled`: a disabled button is
    /// still actionable (recorded as `enabled: false`, not dropped).
    public static func isActionable(role: String, actionNames: [String]) -> Bool {
        roles.contains(role) || actionNames.contains(kAXPressAction)
    }
}

// MARK: - Label usability

/// Which of a node's identifying strings may stand in for a missing title.
///
/// The only judgement here is about `identifier`, and it is a necessary one:
/// AppKit synthesizes an identifier of the form `_NS:<n>` for views decoded from
/// a nib, so most stock Cocoa applications expose one on nearly every element
/// (measured on the system text editor: 10 of its 11 identifiers). Those strings
/// name nothing — they are nib decoding indices that change between builds — and
/// presenting `"_NS:8"` where a name belongs is WORSE than presenting nothing: an
/// empty label is honest about knowing nothing, while a synthetic one looks like
/// information, costs tokens on every line, and invites an agent to address an
/// element by a string that will not survive the next release.
public enum AXLabel {
    /// The prefix AppKit gives its auto-generated view identifiers.
    static let syntheticIdentifierPrefix = "_NS:"

    /// The node's identifier when it is a real, developer-set name; nil when it
    /// is absent, empty, or synthesized by AppKit.
    ///
    /// Applied by the LABEL slot and by the content predicate — the two places
    /// where a synthetic string would masquerade as meaning. It is deliberately
    /// NOT applied to criteria matching, to JSON, or to REF IDENTITY: those
    /// surfaces carry the attribute verbatim, so a caller who has seen `"_NS:8"`
    /// in JSON can still match on it. The two risks are not symmetric — a label
    /// slot must not show a false name, while a criteria substring is explicit
    /// and never accidental.
    ///
    /// ## Why ref identity uses the RAW identifier (deliberate)
    /// `NodeHint` / `RefEntry` / the diff engine compare the identifier VERBATIM,
    /// filter not applied. The reason is that the two surfaces have different
    /// lifetimes and opposite failure modes:
    ///   - The instability that disqualifies `_NS:<n>` as a NAME is instability
    ///     across BUILDS. A ref's identity is only ever compared between a
    ///     snapshot and a re-walk of the SAME process — a session is pinned to a
    ///     pid and the act layer refuses to run once that process is gone — so a
    ///     nib decoding index cannot drift underneath it the way it drifts
    ///     between releases.
    ///   - Discarding it costs the only thing that tells two same-role siblings
    ///     apart when neither has a title, a subrole, or a description. That is
    ///     not a cosmetic loss: without it a ref carries onto the neighbouring
    ///     element at a shifted index and the wrong control is pressed SILENTLY.
    ///   - The two errors are not equally bad. If `_NS:<n>` ever DOES churn
    ///     in-process, the identity simply fails to match and the ref goes stale
    ///     (exit 3, "Nothing was acted on"), which is loud and recoverable by
    ///     re-snapshotting. A discarded identifier fails the other way: silently,
    ///     onto the wrong element, reported as success.
    public static func usableIdentifier(of node: AXNode) -> String? {
        guard let identifier = node.identifier,
              !identifier.isEmpty,
              !identifier.hasPrefix(syntheticIdentifierPrefix)
        else { return nil }
        return identifier
    }
}

// MARK: - Empty-tree predicate

/// Whether a walked tree is "effectively empty" — the trigger for the
/// AXManualAccessibility fallback. True when NO window subtree exposes any
/// actionable descendant or text content.
///
/// Judged over WINDOW subtrees only: the menu bar is app chrome present even
/// for otherwise-blank apps (e.g. Electron before AXManualAccessibility), so its
/// actionable menu items must not mask an empty window tree. Content is judged
/// over a window's DESCENDANTS, not the window node itself, because a hidden
/// tree still reports a window title.
public func isEffectivelyEmpty(_ roots: [AXNode]) -> Bool {
    let windows = roots.filter { $0.role != kAXMenuBarRole }
    for window in windows {
        for descendant in window.children.flatMap(\.flattened) {
            if descendant.actionable || nodeHasTextContent(descendant) {
                return false
            }
        }
    }
    return true
}

/// Whether a node carries readable content: a non-empty value, a static-text
/// element with a non-empty title, or an ACCESSIBILITY LABEL of its own
/// (`description` / `identifier`). (A window's own title is not text content;
/// this predicate is applied to descendants, never to the window node.)
///
/// The label clause is what keeps a labelled-but-titleless element from being
/// mistaken for an empty one. A container whose only identification is
/// `AXDescription "Keypad"` is NOT the contentless wrapper the noise filter
/// drops, and a window subtree built entirely from such elements is NOT the
/// blank tree that triggers the AXManualAccessibility fallback: in both cases
/// the app did answer, it just answered somewhere other than `title`.
/// `identifier` counts alongside `description` because it is equally an answer —
/// it is the label the renderer will fall back to, so dropping the node would
/// drop an element an agent can see and name. It counts only when it is a real
/// one (see `AXLabel.usableIdentifier`): an AppKit-synthesized `_NS:<n>` says
/// nothing about the element and must not resurrect an otherwise empty wrapper.
func nodeHasTextContent(_ node: AXNode) -> Bool {
    if let value = node.value, !isBlank(value) { return true }
    if node.role == kAXStaticTextRole, let title = node.title, !isBlank(title) { return true }
    if let description = node.description, !isBlank(description) { return true }
    if let identifier = AXLabel.usableIdentifier(of: node), !isBlank(identifier) { return true }
    return false
}

private func isBlank(_ string: String) -> Bool {
    string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
