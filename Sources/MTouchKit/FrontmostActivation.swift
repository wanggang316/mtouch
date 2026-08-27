import AppKit
import ApplicationServices
import Foundation

/// Brings a target app frontmost and waits (bounded) for the switch to take
/// effect BEFORE any CGEvent is posted. CGEvents land in whichever app is
/// frontmost AT POST TIME, so posting immediately after an asynchronous
/// activation could leak input into the invoking terminal (VAL-ACT-019). Shared
/// by the keyboard AND coordinate delivery seams so both fight frontmost
/// contention identically rather than forking the logic.
///
/// Public because it is also the DEFAULT activation seam of the menu-path verb,
/// which must name it in a default argument: only the frontmost application's
/// menu bar is actually drawn, so a menu walk activates first.
public enum FrontmostActivation {
    /// Bring `pid` frontmost, then settle. Two mechanisms are asserted together
    /// because either alone is unreliable when the CALLER'S app is itself
    /// frontmost (the common case — an agent invokes mtouch from its terminal):
    ///   - the AX `kAXFrontmostAttribute` write, honored under the Accessibility
    ///     grant we already require even from a background process; and
    ///   - `activate(options: .activateIgnoringOtherApps)`, the FORCEFUL activation
    ///     (deprecated but not removed) that steals focus from a foreground app,
    ///     which the cooperative no-argument `activate()` will not do.
    ///
    /// The wait is a plain wall-clock settle — deliberately NOT a run-loop pump.
    /// Pumping THIS process's run loop dispatches workspace notifications that let
    /// an aggressively-foreground caller re-assert itself in the gap before the
    /// first event is posted; a bare sleep gives the activation time to land at the
    /// window server without opening that re-grab window.
    public static func bringToFront(pid: pid_t, settle: TimeInterval = 0.2) {
        let appElement = AXUIElementCreateApplication(pid)
        let running = NSRunningApplication(processIdentifier: pid)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        forcefullyActivate(running)
        Thread.sleep(forTimeInterval: settle)
    }

    /// Forceful activation via the `.activateIgnoringOtherApps` option. It is
    /// deprecated on macOS 14, but its no-argument replacement is COOPERATIVE and
    /// will not pull focus from a foreground caller — which is exactly the scenario
    /// input delivery must handle — so the forceful variant is retained.
    @available(macOS, deprecated: 14.0)
    private static func forcefullyActivate(_ app: NSRunningApplication?) {
        app?.activate(options: [.activateIgnoringOtherApps])
    }
}
