import AppKit
import ApplicationServices
import CoreGraphics

/// Raised when `--app <bundleId>` names an application with no running
/// process. Paired with exit 1 (`MTouchExitCode.runtimeFailure`).
public struct AppNotRunningError: MTouchDiagnosticError, Equatable, Sendable {
    public let bundleId: String

    public init(bundleId: String) {
        self.bundleId = bundleId
    }

    /// Actionable stderr message: names the bundle id, states it is not
    /// running, and points at `mtouch apps`.
    public var message: String {
        "mtouch: application '\(bundleId)' is not running. Run 'mtouch apps' to list running applications."
    }

    public var exitCode: MTouchExitCode { .runtimeFailure }
}

/// Raised when `--app <bundleId>` matches MORE THAN ONE running process and no
/// explicit `--pid` was supplied. Paired with exit 1
/// (`MTouchExitCode.runtimeFailure`).
public struct AmbiguousAppError: MTouchDiagnosticError, Equatable, Sendable {
    public let bundleId: String
    /// Every matching pid, ascending — the candidates the caller must choose from.
    public let pids: [pid_t]

    public init(bundleId: String, pids: [pid_t]) {
        self.bundleId = bundleId
        self.pids = pids
    }

    /// Names the count and EVERY candidate pid, so the recovery (`--pid <pid>`)
    /// can be performed straight from the message without a second command.
    public var message: String {
        let candidates = pids.map(String.init).joined(separator: ", ")
        return "mtouch: '\(bundleId)' matches \(pids.count) running processes (\(candidates)). "
            + "Pass --pid <pid> to choose one; 'mtouch apps' lists them."
    }

    public var exitCode: MTouchExitCode { .runtimeFailure }
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
    ///
    /// AMBIGUITY IS REFUSED, NOT GUESSED. A bundle id can name several live
    /// processes (a browser plus an automation profile launched with its own
    /// `--user-data-dir`, an app relaunched before the old instance exited). Taking
    /// the first match silently bound to whichever process the system happened to
    /// list first — and for an agent-facing tool, silently driving the WRONG
    /// process is the worst possible outcome: it is indistinguishable from success.
    /// An explicit, recoverable refusal naming every candidate beats a plausible
    /// wrong answer, so >1 match throws and the caller re-issues with `--pid`.
    public static func resolvePID(
        bundleId: String,
        in apps: [(bundleId: String?, pid: pid_t)]
    ) throws -> pid_t {
        let matches = apps
            .filter { $0.bundleId?.caseInsensitiveCompare(bundleId) == .orderedSame }
            .map(\.pid)
            .sorted()
        switch matches.count {
        case 0: throw AppNotRunningError(bundleId: bundleId)
        case 1: return matches[0]
        default: throw AmbiguousAppError(bundleId: bundleId, pids: matches)
        }
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
    /// hung target cannot wedge mtouch.
    ///
    /// Returns a `Result` rather than a bare array because the two nil-ish answers
    /// mean OPPOSITE things: `.success([])` is the app truthfully reporting zero
    /// windows, while `.failure` is the app's accessibility interface refusing the
    /// read (a disabled API, a hung process, a dead process). Flattening the latter
    /// into an empty array printed "no windows" at exit 0 for an app that visibly
    /// had one. Per-WINDOW reads (title, frame) stay lossy on purpose: a window that
    /// answers the list read but not its own title is still a real window, so it is
    /// listed with an empty title / zero frame rather than failing the whole listing.
    public static func windows(ofPID pid: pid_t) -> Result<[WindowInfo], AXReadFailure> {
        let appElement = AXUIElementCreateApplication(pid)
        AXSupport.setMessagingTimeout(appElement)
        let read = AXSupport.copyAttributeResult(appElement, kAXWindowsAttribute)
        if let error = read.error {
            return .failure(AXReadFailure(pid: pid, error: error))
        }
        // A successful read with no array (or an absent value) IS zero windows.
        guard let elements = read.value as? [AXUIElement] else { return .success([]) }
        return .success(elements.enumerated().map { index, window in
            WindowInfo(
                id: AXSupport.windowID(of: window) ?? CGWindowID(index),
                title: (AXSupport.copyAttribute(window, kAXTitleAttribute) as? String) ?? "",
                frame: AXSupport.frame(of: window) ?? .zero
            )
        })
    }

    /// Why an app element produced NOTHING, asked directly of the process: nil when
    /// the app answered (so "nothing" is the truth), a failure when the read itself
    /// was refused. Used to explain an empty accessibility tree, where the walker's
    /// per-element reads have already been flattened to defaults and the reason is
    /// otherwise unrecoverable.
    public static func readFailure(ofPID pid: pid_t) -> AXReadFailure? {
        let appElement = AXUIElementCreateApplication(pid)
        AXSupport.setMessagingTimeout(appElement)
        guard let error = AXSupport.copyAttributeResult(appElement, kAXWindowsAttribute).error else {
            return nil
        }
        return AXReadFailure(pid: pid, error: error)
    }
}
