import ApplicationServices
import CoreGraphics
import Foundation

/// Raw, un-derived attributes of one element, as read from a tree provider.
/// The walker converts this into an `AXNode`, deriving `actionable` /
/// `isScrollArea` from `actionNames` / `role` / `scrollPosition`.
public struct AXAttributes: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var frame: CGRect?
    public var enabled: Bool
    /// Names from `AXUIElementCopyActionNames`, e.g. ["AXPress"].
    public var actionNames: [String]
    public var scrollPosition: CGPoint?

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        frame: CGRect? = nil,
        enabled: Bool = true,
        actionNames: [String] = [],
        scrollPosition: CGPoint? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.frame = frame
        self.enabled = enabled
        self.actionNames = actionNames
        self.scrollPosition = scrollPosition
    }
}

/// The seam that lets the walker run against a live AX tree in production and a
/// literal `AXNode` tree in tests, with ZERO AX/TCC dependency in the test path.
///
/// `roots()` returns the top-level nodes to walk (all app windows plus the menu
/// bar). The pid is bound into the concrete provider (see `LiveTreeProvider`)
/// rather than passed per call — the equivalent of the sketched
/// `rootWindows(pid:)` seam. `roots()` is re-invoked after the fallback, so a
/// provider may return a different tree on the second pass.
public protocol AXTreeProvider {
    associatedtype Element

    /// Top-level elements: every app window plus the menu bar, each a root.
    func roots() -> [Element]
    func children(of element: Element) -> [Element]
    func attributes(of element: Element) -> AXAttributes

    /// Enable the AXManualAccessibility hidden-tree fallback. The walker calls
    /// this AT MOST ONCE, only after a first pass came back effectively empty,
    /// then re-walks. Implementations must tolerate the attribute being
    /// unsupported (no crash) — a no-op simply leaves the retry empty.
    func enableManualAccessibilityFallback()

    /// The stable, unique CGWindowID of a TOP-LEVEL root element when it is a
    /// window, else nil (the menu bar, or a non-live provider). Consulted ONCE per
    /// root by the walker so the persisted snapshot can stamp each ref with its
    /// owning-window identity — the discriminator that tells two identically-titled
    /// windows apart when relocating a ref (VAL-ACT-011). Defaulted to nil so
    /// non-live/test providers need not implement it; their refs simply carry no
    /// window id and relocate by ancestor/position alone.
    func windowID(of element: Element) -> CGWindowID?

    /// The IDENTITY of `element` for cycle detection, or nil when this provider
    /// cannot vouch for identity (a value-typed fixture tree has none). The walker
    /// refuses to descend into an element whose identity is already on the current
    /// root-to-node path; a provider that reports nil is guarded by the depth cap
    /// alone, exactly as before this seam existed.
    func identity(of element: Element) -> AXElementIdentity?
}

public extension AXTreeProvider {
    /// Default: no window id. Non-live providers (and roots that are not windows)
    /// contribute none, leaving `RefEntry.ownerWindowID` nil for those refs.
    func windowID(of element: Element) -> CGWindowID? { nil }

    /// Default: no identity. A provider over value-typed fixture nodes cannot
    /// express a cycle in the first place, so reporting nil is honest rather than
    /// inventing an identity out of role/title (which repeat legitimately).
    func identity(of element: Element) -> AXElementIdentity? { nil }
}

public extension AXTreeProvider where Element == AXUIElement {
    /// Every provider over LIVE AX handles gets CoreFoundation identity for free,
    /// so `LiveTreeProvider` and any handle-based double are cycle-guarded by the
    /// same rule.
    func identity(of element: AXUIElement) -> AXElementIdentity? { AXElementIdentity(element) }
}

/// The identity of ONE accessibility element, as CoreFoundation defines it.
///
/// `AXUIElement` is a CF type whose Swift references are NOT pointer-unique: two
/// separately obtained handles for the SAME element are distinct objects (`===`
/// false) yet `CFEqual` true and share a `CFHash`. Cycle detection is a question
/// of identity — "have I already entered THIS element?" — so the visited set is
/// keyed by exactly that CF notion, never by role/title (which repeat all over a
/// legitimate tree and would cut real content).
public struct AXElementIdentity: Hashable {
    private let object: CFTypeRef

    public init(_ object: CFTypeRef) { self.object = object }

    public static func == (lhs: AXElementIdentity, rhs: AXElementIdentity) -> Bool {
        CFEqual(lhs.object, rhs.object)
    }

    /// `CFHash` is the hash that agrees with `CFEqual`; Swift's default
    /// object hashing (pointer-based) would NOT, and equal elements would land in
    /// different buckets.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(object))
    }
}

/// Renders raw AX attribute values that arrive as `CFTypeRef` into the
/// primitive forms `AXNode` stores. Pure and free of AX/TCC access, so its
/// behavior is unit-testable with hand-built CoreFoundation values.
public enum AXValueRendering {
    /// Renders `kAXValueAttribute` to a string. Strings pass through; booleans
    /// become "true"/"false"; numbers use the shared compact numeric format.
    /// Richer types (attributed strings, geometry, arrays) are left to the
    /// textualizer and render as nil here.
    public static func string(from value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            return (value as! CFString) as String
        }
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean)) ? "true" : "false"
        }
        if typeID == CFNumberGetTypeID() {
            return JSONText.number((value as! NSNumber).doubleValue)
        }
        return nil
    }

    /// Decodes a boolean attribute (e.g. `kAXEnabledAttribute`). Returns nil for
    /// unreadable / non-boolean values so callers can apply their own default.
    public static func bool(from value: CFTypeRef?) -> Bool? {
        guard let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}

/// Wraps a running application's AX tree behind `AXTreeProvider`. Read-only
/// except for the fallback, which sets an app-scoped AX attribute (NOT a TCC
/// change). A messaging timeout is applied to the app element so a hung target
/// degrades individual reads to defaults instead of wedging the walk.
public struct LiveTreeProvider: AXTreeProvider {
    public typealias Element = AXUIElement

    private let appElement: AXUIElement

    public init(pid: pid_t) {
        appElement = AXUIElementCreateApplication(pid)
        AXSupport.setMessagingTimeout(appElement)
    }

    public func roots() -> [AXUIElement] {
        var roots: [AXUIElement] = []
        if let raw = AXSupport.copyAttribute(appElement, kAXWindowsAttribute),
           let windows = raw as? [AXUIElement] {
            roots.append(contentsOf: windows)
        }
        if let raw = AXSupport.copyAttribute(appElement, kAXMenuBarAttribute),
           CFGetTypeID(raw) == AXUIElementGetTypeID() {
            roots.append(raw as! AXUIElement)
        }
        return roots
    }

    public func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = AXSupport.copyAttribute(element, kAXChildrenAttribute),
              let children = raw as? [AXUIElement] else { return [] }
        return children
    }

    public func attributes(of element: AXUIElement) -> AXAttributes {
        AXAttributes(
            role: (AXSupport.copyAttribute(element, kAXRoleAttribute) as? String) ?? kAXUnknownRole,
            subrole: AXSupport.copyAttribute(element, kAXSubroleAttribute) as? String,
            title: AXSupport.copyAttribute(element, kAXTitleAttribute) as? String,
            value: AXValueRendering.string(from: AXSupport.copyAttribute(element, kAXValueAttribute)),
            frame: AXSupport.frame(of: element),
            enabled: AXValueRendering.bool(from: AXSupport.copyAttribute(element, kAXEnabledAttribute)) ?? true,
            actionNames: Self.actionNames(of: element),
            scrollPosition: nil
        )
    }

    public func enableManualAccessibilityFallback() {
        // App-scoped AX attribute that asks Electron/Chromium apps to build
        // their accessibility tree. Result is intentionally ignored: some apps
        // report `kAXErrorAttributeUnsupported`, in which case the retry simply
        // stays empty (fallback fired, did not help).
        _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// A window root's CGWindowID via the private `_AXUIElementGetWindow` wrapper;
    /// nil for the menu-bar root (not a window). This is the live source of the
    /// owning-window identity the snapshot stamps onto each ref.
    public func windowID(of element: AXUIElement) -> CGWindowID? {
        AXSupport.windowID(of: element)
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }
}
