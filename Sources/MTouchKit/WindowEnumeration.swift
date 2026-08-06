import AppKit
import ApplicationServices
import CoreGraphics

/// Raised when `--app <bundleId>` names an application with no running
/// process. Paired with exit 1 (`MTouchExitCode.runtimeFailure`).
public struct AppNotRunningError: Error, Equatable, Sendable {
    public let bundleId: String

    public init(bundleId: String) {
        self.bundleId = bundleId
    }

    /// Actionable stderr message: names the bundle id, states it is not
    /// running, and points at `mtouch apps`.
    public var message: String {
        "mtouch: application '\(bundleId)' is not running. Run 'mtouch apps' to list running applications."
    }
}

/// One top-level window of a running application.
///
/// `id` space: the real CGWindowID obtained via the private
/// `_AXUIElementGetWindow` — the same id space CGWindowList/window-capture
/// APIs use, so `screenshot --window <id>` correlates directly. Only when
/// that call fails for a window (rare) does the id fall back to the window's
/// zero-based index in the AX windows array; fallback ids are deterministic
/// per listing but not stable across window reordering.
///
/// `frame` is in screen POINTS with TOP-LEFT origin (the AX convention:
/// global coordinates, y grows downward from the top-left of the main
/// display). See `AXSupport.frame(of:)`.
public struct WindowInfo: Equatable, Sendable {
    public let id: CGWindowID
    /// Empty when the window exposes no readable AX title.
    public let title: String
    public let frame: CGRect

    public init(id: CGWindowID, title: String, frame: CGRect) {
        self.id = id
        self.title = title
        self.frame = frame
    }

    /// Tab-separated text row: id, title, "x,y", "wxh".
    public var textLine: String {
        let position = "\(JSONText.number(frame.origin.x)),\(JSONText.number(frame.origin.y))"
        let size = "\(JSONText.number(frame.width))x\(JSONText.number(frame.height))"
        return "\(id)\t\(title)\t\(position)\t\(size)"
    }

    /// Stable jq-parseable shape:
    /// `{"id":..,"title":..,"frame":{"x":..,"y":..,"w":..,"h":..}}`.
    public var jsonObject: String {
        let frameJSON = "{\"x\":\(JSONText.number(frame.origin.x)),\"y\":\(JSONText.number(frame.origin.y)),"
            + "\"w\":\(JSONText.number(frame.width)),\"h\":\(JSONText.number(frame.height))}"
        return "{\"id\":\(id),\"title\":\(JSONText.string(title)),\"frame\":\(frameJSON)}"
    }

    public static func jsonArray(_ windows: [WindowInfo]) -> String {
        "[" + windows.map(\.jsonObject).joined(separator: ",") + "]"
    }
}

public enum AXWindowEnumerator {
    /// Pure, case-insensitive bundle-id resolution over an app snapshot
    /// (bundle identifiers compare case-insensitively per LaunchServices).
    /// Entries without a bundle id are skipped.
    public static func resolvePID(
        bundleId: String,
        in apps: [(bundleId: String?, pid: pid_t)]
    ) throws -> pid_t {
        for app in apps {
            if let candidate = app.bundleId,
               candidate.caseInsensitiveCompare(bundleId) == .orderedSame {
                return app.pid
            }
        }
        throw AppNotRunningError(bundleId: bundleId)
    }

    /// Live resolution against NSWorkspace (not TCC-gated).
    public static func resolveRunningPID(bundleId: String) throws -> pid_t {
        try resolvePID(
            bundleId: bundleId,
            in: NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.processIdentifier) }
        )
    }

    /// Live AX window listing. Requires the Accessibility grant — callers
    /// preflight first. A messaging timeout is set on the app element so a
    /// hung target cannot wedge mtouch; timed-out reads degrade to defaults
    /// (empty list / empty title / zero frame) instead of blocking.
    public static func windows(ofPID pid: pid_t) -> [WindowInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        AXSupport.setMessagingTimeout(appElement)
        guard let raw = AXSupport.copyAttribute(appElement, kAXWindowsAttribute),
              let elements = raw as? [AXUIElement]
        else { return [] }
        return elements.enumerated().map { index, window in
            WindowInfo(
                id: AXSupport.windowID(of: window) ?? CGWindowID(index),
                title: (AXSupport.copyAttribute(window, kAXTitleAttribute) as? String) ?? "",
                frame: AXSupport.frame(of: window) ?? .zero
            )
        }
    }
}
