import CoreGraphics

/// Delivers a synthesized `CGEvent`. The single seam between event
/// construction and the real window server: unit tests inject a recording
/// fake so ordering and payloads can be asserted WITHOUT posting real events
/// (which would move the cursor and land keystrokes in live apps).
public protocol EventPoster {
    func post(_ event: CGEvent)
}

/// Live delivery to the HID event tap — the tap synthetic input is expected to
/// enter, so events reach the frontmost application normally.
public struct CGEventPoster: EventPoster {
    public init() {}

    public func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }
}
