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

/// Whether a node carries readable text: a non-empty value, or a static-text
/// element with a non-empty title. (A window's own title is not text content;
/// this predicate is applied to descendants, never to the window node.)
func nodeHasTextContent(_ node: AXNode) -> Bool {
    if let value = node.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return true
    }
    if node.role == kAXStaticTextRole,
       let title = node.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return true
    }
    return false
}
