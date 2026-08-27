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

    /// Copies an attribute value, mapping every AX error to nil. Lossy BY DESIGN
    /// for the many reads whose absence is unremarkable (no subrole, no title).
    /// Reads whose failure must be reported — anything an "empty" answer would
    /// misrepresent as truth — use `copyAttributeResult` instead.
    public static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        copyAttributeResult(element, attribute).value
    }

    /// Copies an attribute value, PRESERVING the `AXError` on failure: `error` is
    /// nil exactly when the read succeeded, and `value` is nil whenever it failed.
    ///
    /// The distinction is load-bearing: a nil `value` with no error (the app
    /// answered, with nothing) and a nil `value` with `.apiDisabled` (the app's
    /// accessibility interface refused to answer) are opposite facts that
    /// `copyAttribute` flattens into the same nil. Collapsing them let a hard AX
    /// failure masquerade as a truthful "zero windows" answer, which is the worst
    /// possible outcome for an agent. A tuple rather than a `Result` because the
    /// imported `AXError` is not an `Error` and must not be retroactively made one.
    public static func copyAttributeResult(
        _ element: AXUIElement, _ attribute: String
    ) -> (value: CFTypeRef?, error: AXError?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return (nil, status) }
        return (value, nil)
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

/// A HARD accessibility read failure against a specific process: the app element
/// refused the read outright, so nothing at all could be learned about it. This is
/// categorically different from an app that answered with nothing, and it must
/// never be rendered as an empty result — an agent cannot tell a lie from a fact.
///
/// Carries the pid and the raw `AXError` so the diagnostic can name both the
/// process and a human-readable cause, plus the numeric code for anything the
/// mapping does not recognize.
public struct AXReadFailure: Error, Equatable, Sendable {
    public let pid: pid_t
    public let error: AXError

    public init(pid: pid_t, error: AXError) {
        self.pid = pid
        self.error = error
    }

    /// Human-readable cause plus the raw code, e.g.
    /// `the accessibility API is disabled for that process (AXError -25211)`.
    /// The three codes a live target realistically produces are named
    /// individually; everything else degrades to the numeric code rather than a
    /// misleading guess.
    public var cause: String {
        let explanation: String
        switch error {
        case .apiDisabled:
            explanation = "the accessibility API is disabled for that process"
        case .cannotComplete:
            explanation = "the process did not respond in time (it may be hung, busy, or stopped)"
        case .invalidUIElement:
            explanation = "the process is no longer a valid accessibility target (it may have exited)"
        case .notImplemented:
            explanation = "the process does not implement the accessibility API"
        default:
            explanation = "the accessibility read failed"
        }
        return "\(explanation) (AXError \(error.rawValue))"
    }

    /// The pinned stderr diagnostic. `subject` names WHAT could not be read
    /// ("windows", "the accessibility tree") so one wording serves every surface;
    /// the tail is the recovery path an agent can actually follow, because the
    /// usual cause is a second instance of the same bundle id.
    public func diagnostic(reading subject: String, of bundleId: String) -> String {
        "mtouch: could not read \(subject) of '\(bundleId)' (pid \(pid)): \(cause). "
            + "It may be a second instance of the app, or an unresponsive process — "
            + "run 'mtouch apps' and retry with --pid <pid>."
    }
}
