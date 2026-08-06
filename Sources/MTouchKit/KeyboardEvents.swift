import CoreGraphics

/// Pure builders for keyboard `CGEvent`s. No posting, no activation, no
/// secure-input check — `InputSynthesizer` composes those around these. Kept
/// separate so the event shape can be asserted directly.
enum KeyboardEvents {
    /// Unicode-safe typing: one keydown/keyup pair per grapheme, each carrying
    /// that grapheme's UTF-16 via `CGEventKeyboardSetUnicodeString`. This routes
    /// text by codepoint instead of keymap lookup, so CJK and emoji type
    /// correctly, and newline/tab flow through as the literal `\n` / `\t`
    /// characters rather than being interpreted as key names.
    static func typing(_ text: String, source: CGEventSource?) -> [CGEvent] {
        var events: [CGEvent] = []
        for character in text {
            let utf16 = Array(String(character).utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                setUnicodeString(utf16, on: down)
                events.append(down)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                setUnicodeString(utf16, on: up)
                events.append(up)
            }
        }
        return events
    }

    /// Keydown/keyup for a resolved combo, carrying its modifier flags.
    static func combo(_ combo: KeyCombo, source: CGEventSource?) -> [CGEvent] {
        var events: [CGEvent] = []
        if let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true) {
            down.flags = combo.flags
            events.append(down)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false) {
            up.flags = combo.flags
            events.append(up)
        }
        return events
    }

    private static func setUnicodeString(_ utf16: [UniChar], on event: CGEvent) {
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    }
}
