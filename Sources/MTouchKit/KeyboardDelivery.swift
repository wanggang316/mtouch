import AppKit
import ApplicationServices
import Foundation

/// A keyboard `act` payload the pipeline delivers to the target app's focused
/// element: either literal text (typed unicode-verbatim) or a resolved key
/// combination. Kept as a value so the pipeline can switch on it for the
/// empty-`type` no-op and the delivery seam, without re-parsing.
public enum KeyboardAction: Sendable {
    case type(String)
    case key(KeyCombo)
}

/// The live keyboard delivery seam the keyboard `act` pipeline calls after it has
/// resolved the target and taken the pre-action snapshot.
///
/// It exists to add ONE thing `InputSynthesizer` deliberately does not: a bounded
/// wait for the target to actually become frontmost before any event is posted.
/// CGEvents are delivered to whichever app is frontmost AT POST TIME, so posting
/// immediately after an asynchronous activation could leak keystrokes into the
/// invoking terminal (VAL-ACT-019). Delivery itself still flows through
/// `InputSynthesizer`, the single synthesis chokepoint that owns the
/// secure-input refusal and activate-before-post invariants.
public enum LiveKeyboardDelivery {
    /// Bring `pid` frontmost, wait (bounded) until the switch takes effect, then
    /// synthesize the keystrokes. Rethrows `SecureInputActive` (mapped to exit 5
    /// by the caller) with zero events delivered.
    public static func deliver(pid: pid_t, action: KeyboardAction) throws {
        // Refuse up front when secure input is active, BEFORE stealing focus:
        // activating the target would pull focus away from the secure-input
        // consumer (a focused password field), and no keystrokes must be sent.
        let secureInput = LiveSecureInputState()
        guard !secureInput.isSecureInputActive else { throw SecureInputActive() }

        activateAndWaitFrontmost(pid: pid)

        let synthesizer = InputSynthesizer(targetPID: pid, secureInput: secureInput)
        switch action {
        case let .type(text):
            try synthesizer.type(text)
        case let .key(combo):
            try synthesizer.key(combo)
        }
    }

    /// Bring `pid` frontmost so a subsequent CGEvent lands in the target rather
    /// than the invoking terminal (VAL-ACT-019), then hand off to the poster.
    ///
    /// Two mechanisms are asserted together because either alone is unreliable when
    /// the CALLER'S app is itself frontmost (the common case — an agent invokes
    /// mtouch from its terminal):
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
    private static func activateAndWaitFrontmost(pid: pid_t, settle: TimeInterval = 0.2) {
        let appElement = AXUIElementCreateApplication(pid)
        let running = NSRunningApplication(processIdentifier: pid)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        forcefullyActivate(running)
        Thread.sleep(forTimeInterval: settle)
    }

    /// Forceful activation via the `.activateIgnoringOtherApps` option. It is
    /// deprecated on macOS 14, but its no-argument replacement is COOPERATIVE and
    /// will not pull focus from a foreground caller — which is exactly the scenario
    /// keyboard delivery must handle — so the forceful variant is retained.
    @available(macOS, deprecated: 14.0)
    private static func forcefullyActivate(_ app: NSRunningApplication?) {
        app?.activate(options: [.activateIgnoringOtherApps])
    }
}
