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

        // Bring the target frontmost (bounded) BEFORE synthesizing, so the
        // keystrokes land in it and not the invoking terminal (VAL-ACT-019).
        FrontmostActivation.bringToFront(pid: pid)

        // `InputSynthesizer` also cooperatively activates the target per event. That
        // inner activate is redundant after this forceful, bounded `bringToFront`
        // (the target is already frontmost) but is left in place deliberately: it is
        // cheap and keeps `InputSynthesizer` the single self-contained synthesis
        // chokepoint every caller relies on, rather than splitting the activate
        // invariant across two seams.
        let synthesizer = InputSynthesizer(targetPID: pid, secureInput: secureInput)
        switch action {
        case let .type(text):
            try synthesizer.type(text)
        case let .key(combo):
            try synthesizer.key(combo)
        }
    }
}
