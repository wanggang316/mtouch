import ApplicationServices
import CoreGraphics

/// Private-but-long-stable HIServices call mapping an AX window element to
/// its CGWindowID — the same id space CGWindowList/window-capture APIs use,
/// which lets `screenshot --window <id>` correlate directly with `windows`.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

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

    /// CGWindowID of a window element via the private `_AXUIElementGetWindow`;
    /// nil when the call fails or reports the null window id (callers then
    /// fall back to an index-based id).
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

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
