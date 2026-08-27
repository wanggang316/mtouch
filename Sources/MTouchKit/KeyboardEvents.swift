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
    ///
    /// When `layout` can reach the grapheme in one stroke, the pair *also*
    /// carries that real virtual key code and its modifier flags. Clients that
    /// rebuild the character from the key code rather than reading the unicode
    /// payload — the out-of-process open/save panel service among them — ignore
    /// payload-only events, and a key code is the only thing they will accept.
    /// The payload stays on the event either way, so nothing that already read
    /// it changes behaviour, and anything off the layout keeps the `virtualKey:
    /// 0` fallback unchanged.
    static func typing(
        _ text: String,
        source: CGEventSource?,
        layout: KeyboardLayout = .current
    ) -> [CGEvent] {
        var events: [CGEvent] = []
        for character in text {
            let utf16 = Array(String(character).utf16)
            let keystroke = layout.keystroke(for: character)
            let keyCode = keystroke?.keyCode ?? 0
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                    continue
                }
                // Only the key code path sets flags, and it always sets them:
                // an inherited modifier held elsewhere would otherwise turn a
                // typed character into a shortcut.
                if let keystroke {
                    event.flags = keystroke.flags
                }
                setUnicodeString(utf16, on: event)
                events.append(event)
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
