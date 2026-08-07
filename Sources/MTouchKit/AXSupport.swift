import ApplicationServices
import CoreGraphics
import Darwin

/// Private-but-long-stable HIServices call mapping an AX window element to its
/// CGWindowID — the same id space CGWindowList/window-capture APIs use, which
/// lets `screenshot --window <id>` correlate directly with `windows`.
private typealias AXUIElementGetWindowFn =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// SOFT-bound at runtime via `dlsym` rather than a link-time `@_silgen_name`.
/// A hard link would abort the ENTIRE mtouch binary at launch with a dyld
/// missing-symbol error if a future macOS drops/renames this private symbol;
/// resolving lazily degrades that to a nil window id (callers then fall back to
/// an index-based id) instead of a launch failure. Resolve once at first use,
/// trying the raw asm spelling then the underscore-stripped C spelling, and
/// cache whichever the dynamic linker returns (nil if neither resolves).
private let axUIElementGetWindow: AXUIElementGetWindowFn? = {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    for name in ["_AXUIElementGetWindow", "AXUIElementGetWindow"] {
        if let sym = dlsym(rtldDefault, name) {
            return unsafeBitCast(sym, to: AXUIElementGetWindowFn.self)
        }
    }
    return nil
}()

/// Thin synchronous wrappers over the AX C API, shared by window enumeration
/// and (later) the snapshot feature. All calls are read-only.
public enum AXSupport {
    /// Default messaging timeout applied to app elements so a hung target
    /// process cannot wedge mtouch: individual AX reads fail with
    /// `.cannotComplete` after this many seconds instead of blocking forever.
    public static let defaultMessagingTimeout: Float = 3.0

    public static func setMessagingTimeout(
        _ element: AXUIElement,
        seconds: Float = defaultMessagingTimeout
    ) {
        _ = AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// Copies an attribute value, mapping every AX error to nil.
    public static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// CGWindowID of a window element via the private `_AXUIElementGetWindow`,
    /// SOFT-bound at runtime (see `axUIElementGetWindow`); nil when the symbol
    /// is unavailable on this OS, the call fails, or it reports the null window
    /// id — callers then fall back to an index-based id.
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axUIElementGetWindow else { return nil }
        var windowID: CGWindowID = 0
        guard fn(element, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    /// Test-only visibility into whether the runtime-resolved window symbol is
    /// live. HIServices is loaded during `swift test` on macOS, so this MUST be
    /// true there — the regression guard that the dlsym name is correct.
    static var windowResolverIsBound: Bool { axUIElementGetWindow != nil }

    public static func decodePoint(_ value: CFTypeRef?) -> CGPoint? {
        guard let axValue = castAXValue(value, expecting: .cgPoint) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    public static func decodeSize(_ value: CFTypeRef?) -> CGSize? {
        guard let axValue = castAXValue(value, expecting: .cgSize) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Window frame in screen POINTS with TOP-LEFT origin: AX reports global
    /// screen coordinates where y grows downward from the top-left corner of
    /// the main display. Coordinate actions and screenshots must use this
    /// same convention so frames, clicks, and captures agree.
    public static func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = decodePoint(copyAttribute(window, kAXPositionAttribute)),
              let size = decodeSize(copyAttribute(window, kAXSizeAttribute))
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func castAXValue(_ value: CFTypeRef?, expecting type: AXValueType) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        return axValue
    }
}
