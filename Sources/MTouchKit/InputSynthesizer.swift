import CoreGraphics

/// The single CGEvent synthesis entry point. Every keyboard and mouse action a
/// later `act` verb performs goes through here so the security and ordering
/// invariants live in ONE place no caller can bypass:
///
///   1. keyboard actions refuse when secure input is active (zero events, no
///      payload in the diagnostic — see `SecureInputActive`);
///   2. the target app is activated BEFORE any event is posted, so events land
///      in the app under test rather than the invoking terminal;
///   3. events are built by the pure `KeyboardEvents` / `MouseEvents` factories
///      and delivered through the injected `EventPoster`.
///
/// `Activator`, `SecureInputState`, and `EventPoster` are injected so unit
/// tests verify ordering and refusal without delivering real events.
public struct InputSynthesizer {
    private let targetPID: pid_t
    private let activator: Activator
    private let secureInput: SecureInputState
    private let poster: EventPoster
    private let source: CGEventSource?

    public init(
        targetPID: pid_t,
        activator: Activator = FrontmostActivator(),
        secureInput: SecureInputState = LiveSecureInputState(),
        poster: EventPoster = CGEventPoster(),
        source: CGEventSource? = CGEventSource(stateID: .combinedSessionState)
    ) {
        self.targetPID = targetPID
        self.activator = activator
        self.secureInput = secureInput
        self.poster = poster
        self.source = source
    }

    // MARK: Keyboard

    /// Type literal text. Refuses (throwing `SecureInputActive`, zero events)
    /// when secure input is active.
    public func type(_ text: String) throws {
        try refuseIfSecureInputActive()
        activateTarget()
        deliver(KeyboardEvents.typing(text, source: source))
    }

    /// Send a resolved key combination. Refuses (throwing `SecureInputActive`,
    /// zero events) when secure input is active.
    public func key(_ combo: KeyCombo) throws {
        try refuseIfSecureInputActive()
        activateTarget()
        deliver(KeyboardEvents.combo(combo, source: source))
    }

    // MARK: Mouse

    public func move(to point: ScreenPoint) {
        activateTarget()
        deliver(MouseEvents.move(to: point.cgPoint, source: source))
    }

    public func click(at point: ScreenPoint) {
        activateTarget()
        deliver(MouseEvents.click(at: point.cgPoint, button: .left, source: source))
    }

    public func rightClick(at point: ScreenPoint) {
        activateTarget()
        deliver(MouseEvents.click(at: point.cgPoint, button: .right, source: source))
    }

    public func doubleClick(at point: ScreenPoint) {
        activateTarget()
        deliver(MouseEvents.doubleClick(at: point.cgPoint, source: source))
    }

    public func drag(from start: ScreenPoint, to end: ScreenPoint) {
        activateTarget()
        deliver(MouseEvents.drag(from: start.cgPoint, to: end.cgPoint, source: source))
    }

    public func scroll(at point: ScreenPoint, dy: Int) {
        activateTarget()
        deliver(MouseEvents.scroll(at: point.cgPoint, dy: dy, source: source))
    }

    // MARK: Composition

    private func refuseIfSecureInputActive() throws {
        if secureInput.isSecureInputActive {
            throw SecureInputActive()
        }
    }

    private func activateTarget() {
        activator.activate(pid: targetPID)
    }

    private func deliver(_ events: [CGEvent]) {
        for event in events {
            poster.post(event)
        }
    }
}

extension ScreenPoint {
    /// Screen point as a `CGPoint` (identical top-left-origin coordinate space).
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
