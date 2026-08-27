import CoreGraphics
import Testing
@testable import MTouchKit

// MARK: - Fixtures

/// A layout that does not depend on the host's input source, so the
/// keycode/fallback split can be pinned deterministically: `a`/`A` share one
/// key, `1`/`!` share another, and nothing else is reachable.
private let stubLayout = KeyboardLayout(keystrokes: [
    "a": LayoutKeystroke(keyCode: 10, flags: []),
    "A": LayoutKeystroke(keyCode: 10, flags: .maskShift),
    "1": LayoutKeystroke(keyCode: 20, flags: []),
    "!": LayoutKeystroke(keyCode: 20, flags: .maskShift),
])

private func keyCode(of event: CGEvent) -> CGKeyCode {
    CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
}

/// Reads the UTF-16 payload a keydown/keyup event carries back out.
private func unicodeString(of event: CGEvent) -> String {
    var length = 0
    event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
    guard length > 0 else { return "" }
    var buffer = [UniChar](repeating: 0, count: length)
    event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &buffer)
    return String(utf16CodeUnits: buffer, count: length)
}

private func keyDowns(_ events: [CGEvent]) -> [CGEvent] {
    events.filter { $0.type == .keyDown }
}

// MARK: - Reverse lookup against the host's active layout

@Suite struct KeyboardLayoutLookupTests {
    @Test func ordinaryTypingCharactersResolveToAKeystroke() {
        let layout = KeyboardLayout.current
        // A host with no input-services session yields an empty map by design;
        // every character then takes the unicode fallback, which is exactly the
        // behaviour that shipped before key codes were added.
        guard !layout.isEmpty else {
            #expect(layout.keystroke(for: "a") == nil)
            return
        }
        let unreachable = "abz059./-, ".filter { layout.keystroke(for: $0) == nil }
        #expect(unreachable.isEmpty)
    }

    @Test func shiftedCharactersShareTheKeyOfTheirUnshiftedForm() {
        let layout = KeyboardLayout.current
        let pairs: [(Character, Character)] = [("a", "A"), ("b", "B"), ("z", "Z")]
        // A layout that cannot reach the latin alphabet contributes no pairs;
        // wherever it can, the shift flag is what distinguishes the two.
        for (lower, upper) in pairs {
            guard let unshifted = layout.keystroke(for: lower),
                  let shifted = layout.keystroke(for: upper)
            else { continue }
            #expect(shifted.keyCode == unshifted.keyCode)
            #expect(shifted.flags.contains(.maskShift))
            #expect(!unshifted.flags.contains(.maskShift))
        }
    }

    @Test func charactersOffTheLayoutResolveToNothing() {
        let layout = KeyboardLayout.current
        let reachable = "中文字日本語한글😀🎉".filter { layout.keystroke(for: $0) != nil }
        #expect(reachable.isEmpty)
    }

    @Test func controlAndFunctionKeysStayOffTheLayout() {
        let layout = KeyboardLayout.current
        // Newline and tab must keep flowing through as literal text rather than
        // becoming Return/Tab keystrokes, and the arrow/function keys must not
        // become typeable characters. Keeping them off the map is what pins it.
        #expect(layout.keystroke(for: "\n") == nil)
        #expect(layout.keystroke(for: "\r") == nil)
        #expect(layout.keystroke(for: "\t") == nil)
        #expect(layout.keystroke(for: "\u{1B}") == nil) // escape
        #expect(layout.keystroke(for: "\u{08}") == nil) // backspace
        #expect(layout.keystroke(for: "\u{7F}") == nil) // delete
        #expect(layout.keystroke(for: "\u{F704}") == nil) // F1
        #expect(layout.keystroke(for: "\u{F702}") == nil) // left arrow
    }
}

// MARK: - Typing with real key codes

@Suite struct KeyboardTypingKeycodeTests {
    @Test func mappableCharactersCarryTheirKeycodeAndModifierFlags() {
        let events = KeyboardEvents.typing("aA", source: nil, layout: stubLayout)

        #expect(events.map(\.type) == [.keyDown, .keyUp, .keyDown, .keyUp])
        #expect(events.map(keyCode(of:)) == [10, 10, 10, 10])
        #expect(!events[0].flags.contains(.maskShift))
        #expect(!events[1].flags.contains(.maskShift))
        #expect(events[2].flags.contains(.maskShift))
        #expect(events[3].flags.contains(.maskShift))
    }

    @Test func unmappableCharactersFallBackToKeycodeZeroWithAUnicodePayload() {
        let events = KeyboardEvents.typing("中😀", source: nil, layout: stubLayout)

        #expect(events.map(\.type) == [.keyDown, .keyUp, .keyDown, .keyUp])
        #expect(events.allSatisfy { keyCode(of: $0) == 0 })
        #expect(keyDowns(events).map(unicodeString(of:)) == ["中", "😀"])
    }

    @Test func mixedTextInterleavesKeycodeAndFallbackEventsInOrder() {
        let events = KeyboardEvents.typing("a中1", source: nil, layout: stubLayout)

        #expect(events.count == 6)
        #expect(keyDowns(events).map(keyCode(of:)) == [10, 0, 20])
        #expect(keyDowns(events).map(unicodeString(of:)) == ["a", "中", "1"])
    }

    @Test func everyCharacterKeepsItsUnicodePayloadWhicheverPathItTakes() {
        let text = "aA1!中😀\n\t "
        let events = KeyboardEvents.typing(text, source: nil, layout: stubLayout)

        #expect(events.count == text.count * 2)
        #expect(keyDowns(events).map(unicodeString(of:)).joined() == text)
    }

    @Test func anEmptyLayoutTypesEverythingThroughTheFallback() {
        let events = KeyboardEvents.typing("abc", source: nil, layout: KeyboardLayout(keystrokes: [:]))

        #expect(events.count == 6)
        #expect(events.allSatisfy { keyCode(of: $0) == 0 })
        #expect(keyDowns(events).map(unicodeString(of:)).joined() == "abc")
    }
}
