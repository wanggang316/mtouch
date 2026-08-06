import Foundation

/// A coordinate `act` payload the pipeline delivers as a mouse gesture at screen
/// points (top-left origin, matching snapshot `frame`). Kept as a value so the
/// pipeline can enumerate its target points for off-screen validation and switch
/// on it at the delivery seam without re-parsing.
public enum PointerAction: Equatable, Sendable {
    case click(ScreenPoint)
    case rightClick(ScreenPoint)
    case doubleClick(ScreenPoint)
    case drag(from: ScreenPoint, to: ScreenPoint)
    case scroll(at: ScreenPoint, dy: Int)

    /// Every screen point this gesture touches — validated (all must be on-screen)
    /// BEFORE any event is posted. `drag` targets both endpoints.
    public var points: [ScreenPoint] {
        switch self {
        case let .click(point), let .rightClick(point), let .doubleClick(point):
            return [point]
        case let .drag(from, to):
            return [from, to]
        case let .scroll(point, _):
            return [point]
        }
    }

    /// Whether this gesture is expected to OPEN a menu, so the post-action settle
    /// uses the longer menu budget (a just-opened `AXMenu` only becomes walkable
    /// once it reports a real frame). Only a right-click opens a context menu.
    public var opensMenu: Bool {
        if case .rightClick = self { return true }
        return false
    }
}

/// The live coordinate delivery seam the coordinate `act` pipeline calls after it
/// has resolved the target and validated the points. It mirrors
/// `LiveKeyboardDelivery`: bring the target frontmost (bounded) so the gesture
/// lands in it rather than the invoking terminal, then synthesize through
/// `InputSynthesizer`, the single synthesis chokepoint that owns the
/// activate-before-post invariant.
public enum LivePointerDelivery {
    /// Bring `pid` frontmost, wait (bounded) until the switch takes effect, then
    /// synthesize the gesture. Mouse synthesis is not gated by secure input (that
    /// is a keyboard-only concern), so this never refuses.
    public static func deliver(pid: pid_t, action: PointerAction) {
        FrontmostActivation.bringToFront(pid: pid)

        // `InputSynthesizer` also cooperatively activates the target per event. That
        // inner activate is redundant after this forceful, bounded `bringToFront`
        // (the target is already frontmost) but is left in place deliberately: it is
        // cheap and keeps `InputSynthesizer` the single self-contained synthesis
        // chokepoint every caller relies on, rather than splitting the activate
        // invariant across two seams.
        let synthesizer = InputSynthesizer(targetPID: pid)
        switch action {
        case let .click(point):
            synthesizer.click(at: point)
        case let .rightClick(point):
            synthesizer.rightClick(at: point)
        case let .doubleClick(point):
            synthesizer.doubleClick(at: point)
        case let .drag(from, to):
            synthesizer.drag(from: from, to: to)
        case let .scroll(point, dy):
            synthesizer.scroll(at: point, dy: dy)
        }
    }
}
