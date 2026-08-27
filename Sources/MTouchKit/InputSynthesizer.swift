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
///      and delivered through the injected `EventPoster`;
///   4. every posted burst is FLUSHED — the call does not return until the window
///      server reports having processed the events, or a bounded deadline expires
///      (see `InputDeliveryFlush`). Posting is asynchronous, so without this a
///      caller that returns and exits races its own input and loses.
///
/// Every action reports back what the flush established, so a caller that cannot
/// confirm delivery is never free to report a clean success.
///
/// `Activator`, `SecureInputState`, `EventPoster`, and the flush's counter/clock
/// are injected so unit tests verify ordering, refusal, and timing without
/// delivering real events.
public struct InputSynthesizer {
    private let targetPID: pid_t
    private let activator: Activator
    private let secureInput: SecureInputState
    private let poster: EventPoster
    private let source: CGEventSource?
    private let flush: InputDeliveryFlush

    public init(
        targetPID: pid_t,
        activator: Activator = FrontmostActivator(),
        secureInput: SecureInputState = LiveSecureInputState(),
        poster: EventPoster = CGEventPoster(),
        source: CGEventSource? = CGEventSource(stateID: .combinedSessionState),
        flush: InputDeliveryFlush = InputDeliveryFlush()
    ) {
        self.targetPID = targetPID
        self.activator = activator
        self.secureInput = secureInput
        self.poster = poster
        self.source = source
        self.flush = flush
    }

    // MARK: Keyboard

    /// Type literal text. Refuses (throwing `SecureInputActive`, zero events)
    /// when secure input is active.
    @discardableResult
    public func type(_ text: String) throws -> DeliveryConfirmation {
        try refuseIfSecureInputActive()
        activateTarget()
        return deliver(KeyboardEvents.typing(text, source: source))
    }

    /// Send a resolved key combination. Refuses (throwing `SecureInputActive`,
    /// zero events) when secure input is active.
    @discardableResult
    public func key(_ combo: KeyCombo) throws -> DeliveryConfirmation {
        try refuseIfSecureInputActive()
        activateTarget()
        return deliver(KeyboardEvents.combo(combo, source: source))
    }

    // MARK: Mouse

    @discardableResult
    public func move(to point: ScreenPoint) -> DeliveryConfirmation {
        activateTarget()
        return deliver(MouseEvents.move(to: point.cgPoint, source: source))
    }

    @discardableResult
    public func click(at point: ScreenPoint) -> DeliveryConfirmation {
        activateTarget()
        return deliver(MouseEvents.click(at: point.cgPoint, button: .left, source: source))
    }

    @discardableResult
    public func rightClick(at point: ScreenPoint) -> DeliveryConfirmation {
        activateTarget()
        return deliver(MouseEvents.click(at: point.cgPoint, button: .right, source: source))
    }

    @discardableResult
    public func doubleClick(at point: ScreenPoint) -> DeliveryConfirmation {
        activateTarget()
        return deliver(MouseEvents.doubleClick(at: point.cgPoint, source: source))
    }

    @discardableResult
    public func drag(from start: ScreenPoint, to end: ScreenPoint) -> DeliveryConfirmation {
        activateTarget()
        return deliver(MouseEvents.drag(from: start.cgPoint, to: end.cgPoint, source: source))
    }

    @discardableResult
    public func scroll(at point: ScreenPoint, dy: Int) -> DeliveryConfirmation {
        activateTarget()
        return deliver(MouseEvents.scroll(at: point.cgPoint, dy: dy, source: source))
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

    /// Post the burst and wait for it to land. The flush owns the posting so the
    /// counter baseline is always read before the first event goes out.
    private func deliver(_ events: [CGEvent]) -> DeliveryConfirmation {
        flush.post(events, through: poster.post)
    }
}

extension ScreenPoint {
    /// Screen point as a `CGPoint` (identical top-left-origin coordinate space).
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
