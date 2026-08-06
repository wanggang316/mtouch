import CoreGraphics

/// Pure builders for mouse `CGEvent`s. Points are screen points with TOP-LEFT
/// origin — the same convention as AX frames and snapshots — so coordinates
/// derived from `snapshot` land where expected. No posting or activation here;
/// `InputSynthesizer` composes those around these builders.
enum MouseEvents {
    static func move(to point: CGPoint, source: CGEventSource?) -> [CGEvent] {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return [] }
        return [event]
    }

    static func click(at point: CGPoint, button: CGMouseButton, source: CGEventSource?) -> [CGEvent] {
        clickPair(at: point, button: button, clickState: 1, source: source)
    }

    /// A double click is two click pairs at the same point; the second carries a
    /// click state of 2 so the target recognizes it as a double click rather
    /// than two independent clicks.
    static func doubleClick(at point: CGPoint, source: CGEventSource?) -> [CGEvent] {
        clickPair(at: point, button: .left, clickState: 1, source: source)
            + clickPair(at: point, button: .left, clickState: 2, source: source)
    }

    static func drag(from start: CGPoint, to end: CGPoint, source: CGEventSource?) -> [CGEvent] {
        var events: [CGEvent] = []
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) {
            events.append(down)
        }
        if let dragged = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: end, mouseButton: .left) {
            events.append(dragged)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
            events.append(up)
        }
        return events
    }

    /// Scroll by `dy` lines at `point`. Pinned sign: POSITIVE `dy` scrolls
    /// CONTENT UP (native wheel semantics), so `dy` maps straight to `wheel1`.
    static func scroll(at point: CGPoint, dy: Int, source: CGEventSource?) -> [CGEvent] {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 1,
            wheel1: Int32(clamping: dy),
            wheel2: 0,
            wheel3: 0
        ) else { return [] }
        event.location = point
        return [event]
    }

    private static func clickPair(
        at point: CGPoint,
        button: CGMouseButton,
        clickState: Int64,
        source: CGEventSource?
    ) -> [CGEvent] {
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        var events: [CGEvent] = []
        if let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button) {
            down.setIntegerValueField(.mouseEventClickState, value: clickState)
            events.append(down)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button) {
            up.setIntegerValueField(.mouseEventClickState, value: clickState)
            events.append(up)
        }
        return events
    }
}
