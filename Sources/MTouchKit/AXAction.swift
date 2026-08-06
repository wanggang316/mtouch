import ApplicationServices

/// The four ref-based `act` verbs, as a value the act pipeline switches on. The
/// `set-value` payload is carried alongside (not baked in) so a missing value is
/// caught as a usage error before any AX access.
public enum ActVerb: Equatable, Sendable {
    case press
    case focus
    case showMenu
    case setValue
}

/// An HONEST failure to perform an AX action on a located element — a control
/// that cannot be pressed, a non-focusable element, a value that is not settable.
/// The act layer maps it to exit 1 (`runtimeFailure`) and NEVER fabricates a
/// success/diff in its place. The message names the offending action, never any
/// typed value (a `set-value` payload may be a secret).
public struct AXActionFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Thin wrappers that perform ONE AX action on an already-located element and
/// report an honest success/failure. Kept separate from the re-location and
/// pipeline layers so each verb's AX contract lives in one auditable place.
///
/// The wrappers do NOT re-locate, walk, or diff — the caller has already resolved
/// the live element and is responsible for the surrounding pipeline. They are the
/// single seam through which every element-targeted `act` verb touches AX, so the
/// "no fabricated success" rule (a button has no settable value; a static label
/// cannot be focused) is enforced in exactly one spot.
public enum AXAction {
    /// Perform `verb` on `element`. `value` is required for `.setValue` (the
    /// caller guarantees it is present via an earlier usage check) and ignored by
    /// the others.
    public static func perform(_ element: AXUIElement, _ verb: ActVerb, value: String?) -> Result<Void, AXActionFailure> {
        switch verb {
        case .press:
            return performAction(element, kAXPressAction as String, verb: "press")
        case .showMenu:
            return showMenu(element)
        case .focus:
            return focus(element)
        case .setValue:
            return setValue(element, value: value)
        }
    }

    // MARK: - press / show-menu

    /// Fire a named AX action; a non-`.success` result is an honest failure (a
    /// disabled or unsupported control), never a fabricated no-op.
    static func performAction(_ element: AXUIElement, _ action: String, verb: String) -> Result<Void, AXActionFailure> {
        let error = AXUIElementPerformAction(element, action as CFString)
        guard error == .success else {
            return .failure(AXActionFailure(
                "cannot \(verb) the referenced element (\(describe(error))). "
                    + "It may be disabled or may not support this action."
            ))
        }
        return .success(())
    }

    /// Open a menu on `element`. A control that owns a contextual menu exposes
    /// `AXShowMenu`; a menu OWNER (a menu-bar item) instead opens its menu via
    /// `AXPress`. Prefer `AXShowMenu`, fall back to `AXPress`, and fail honestly
    /// when the element supports neither.
    static func showMenu(_ element: AXUIElement) -> Result<Void, AXActionFailure> {
        let actions = supportedActions(element)
        if actions.contains(kAXShowMenuAction as String) {
            return performAction(element, kAXShowMenuAction as String, verb: "show-menu")
        }
        if actions.contains(kAXPressAction as String) {
            return performAction(element, kAXPressAction as String, verb: "show-menu")
        }
        return .failure(AXActionFailure(
            "cannot show a menu for the referenced element: it exposes neither AXShowMenu nor AXPress."
        ))
    }

    // MARK: - focus

    /// Give keyboard focus to `element` by setting `AXFocused` true. A
    /// non-focusable element (a static label, a plain button) rejects the set;
    /// that is surfaced as an honest failure rather than a fabricated success.
    static func focus(_ element: AXUIElement) -> Result<Void, AXActionFailure> {
        let error = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard error == .success else {
            return .failure(AXActionFailure(
                "cannot focus the referenced element (\(describe(error))): it does not accept keyboard focus."
            ))
        }
        return .success(())
    }

    // MARK: - set-value

    /// Set `AXValue` on `element`. An element whose value is not settable (a
    /// button, a static label) is rejected BEFORE the write, so no diff is ever
    /// fabricated for an element that cannot hold a value.
    static func setValue(_ element: AXUIElement, value: String?) -> Result<Void, AXActionFailure> {
        guard let value else {
            return .failure(AXActionFailure("set-value requires a value."))
        }
        var settable: DarwinBoolean = false
        let settableError = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settableError == .success, settable.boolValue else {
            return .failure(AXActionFailure(
                "the referenced element has no settable value; set-value is not supported for it."
            ))
        }
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        guard error == .success else {
            return .failure(AXActionFailure("cannot set the referenced element's value (\(describe(error)))."))
        }
        return .success(())
    }

    // MARK: - Internals

    /// Names from `AXUIElementCopyActionNames`, or an empty list when the element
    /// exposes none / the read fails.
    static func supportedActions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }

    /// Compact, non-sensitive rendering of an `AXError` for diagnostics.
    static func describe(_ error: AXError) -> String {
        "AX error \(error.rawValue)"
    }
}
