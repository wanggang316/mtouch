import Carbon.HIToolbox

/// Non-prompting check for macOS "secure input" (`EnableSecureEventInput`),
/// the mode password fields turn on to stop other processes observing or
/// injecting keystrokes. While it is active, synthesized keyboard events are
/// silently dropped by the window server, so `type`/`key` MUST refuse rather
/// than pretend to succeed. Wrapped behind a protocol so unit tests simulate
/// an active/inactive state without touching real secure input.
public protocol SecureInputState {
    var isSecureInputActive: Bool { get }
}

/// Live check via Carbon's `IsSecureEventInputEnabled()`. Read-only; never
/// enables or disables secure input.
public struct LiveSecureInputState: SecureInputState {
    public init() {}

    public var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }
}

/// Thrown by the synthesis entry points when secure input is active. It carries
/// NO reference to the text or combo that was going to be sent: the payload can
/// be a password, and the refusal diagnostic reaches stderr, so leaking it here
/// would defeat the very protection secure input provides. Callers pair it with
/// exit code 5 (`.secureInput`).
public struct SecureInputActive: Error, Equatable, Sendable {
    public init() {}

    /// Stderr diagnostic. Deliberately payload-free.
    public var diagnostic: String {
        "mtouch: secure input is active; refusing to synthesize keystrokes. "
            + "A password field or similar secure-input consumer is focused; "
            + "no keystrokes were delivered."
    }

    /// Exit code the CLI maps this refusal to.
    public var exitCode: MTouchExitCode { .secureInput }
}
