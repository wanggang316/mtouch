import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One physical keystroke: the virtual key code plus the modifier flags that
/// have to accompany it for the layout to produce a particular character.
struct LayoutKeystroke: Equatable, Sendable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

/// Reverse map from character → the keystroke that types it on a keyboard
/// layout.
///
/// Typing by unicode payload alone (`virtualKey: 0` plus
/// `CGEventKeyboardSetUnicodeString`) is invisible to clients that rebuild the
/// character from the virtual key code instead of reading the payload — the
/// out-of-process open/save panel service is one, which is why key equivalents
/// reached it but typed text did not. Carrying a real key code makes those
/// clients see the keystroke; the unicode payload stays on the event so
/// in-process text views are unaffected, and it remains the only route for
/// everything the layout cannot reach (CJK, emoji, newline, tab).
///
/// The map is derived from the host's *active* layout through Text Input
/// Services rather than a hardcoded table, so a non-US layout types its own
/// characters. Enumeration happens once per process and the result is
/// immutable.
struct KeyboardLayout: Sendable {
    private let keystrokes: [Character: LayoutKeystroke]

    init(keystrokes: [Character: LayoutKeystroke]) {
        self.keystrokes = keystrokes
    }

    /// The keystroke that types `character`, or `nil` when the layout cannot
    /// reach it in one stroke and the caller must fall back to a unicode
    /// payload.
    func keystroke(for character: Character) -> LayoutKeystroke? {
        keystrokes[character]
    }

    /// True when no layout could be read at all (no input-services session).
    /// Every character then takes the unicode fallback.
    var isEmpty: Bool {
        keystrokes.isEmpty
    }

    /// The host's active layout, enumerated once per process.
    static let current = KeyboardLayout(unicodeKeyLayoutData: activeUnicodeKeyLayoutData())

    /// Enumerates the whole virtual key code space against the shift/option
    /// combinations, keeping the first keystroke that reaches each character.
    /// Key codes ascend so the main keyboard block wins over the numeric
    /// keypad's duplicate digits and operators, and within one key an
    /// unmodified stroke wins over a modified one.
    init(unicodeKeyLayoutData data: Data?) {
        self.init(keystrokes: data.map(KeyboardLayout.enumerateKeystrokes(in:)) ?? [:])
    }

    // MARK: Enumeration

    /// Virtual key codes are 7 bits wide.
    private static let keyCodeCount: UInt16 = 128

    /// Modifier combinations worth probing, in preference order. Carbon wants
    /// the *high byte* of its modifier mask; `CGEventFlags` is what the posted
    /// event carries.
    private static let modifierCandidates: [(carbon: UInt32, flags: CGEventFlags)] = [
        (0, []),
        (UInt32(shiftKey >> 8), .maskShift),
        (UInt32(optionKey >> 8), .maskAlternate),
        (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
    ]

    private static func enumerateKeystrokes(in layoutData: Data) -> [Character: LayoutKeystroke] {
        var keystrokes: [Character: LayoutKeystroke] = [:]
        let keyboardType = UInt32(LMGetKbdType())
        layoutData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for keyCode in 0..<keyCodeCount {
                for candidate in modifierCandidates {
                    guard let character = translate(
                        layout: layout,
                        keyCode: keyCode,
                        carbonModifiers: candidate.carbon,
                        keyboardType: keyboardType
                    ) else { continue }
                    if keystrokes[character] == nil {
                        keystrokes[character] = LayoutKeystroke(keyCode: keyCode, flags: candidate.flags)
                    }
                }
            }
        }
        return keystrokes
    }

    /// The single character this key + modifier combination produces, or `nil`
    /// for dead keys, multi-character results, and anything that is not typed
    /// text (see `isTypeable`).
    private static func translate(
        layout: UnsafePointer<UCKeyboardLayout>,
        keyCode: UInt16,
        carbonModifiers: UInt32,
        keyboardType: UInt32
    ) -> Character? {
        let capacity = 8
        var deadKeyState: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: capacity)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDown),
            carbonModifiers,
            keyboardType,
            OptionBits(0),
            &deadKeyState,
            capacity,
            &length,
            &buffer
        )
        // A dead key reports no output and a pending state; it needs a second
        // stroke to commit, so it is not a keystroke this map can offer.
        guard status == noErr, length > 0, deadKeyState == 0 else { return nil }
        let text = String(utf16CodeUnits: buffer, count: Int(length))
        guard text.count == 1, let character = text.first, isTypeable(character) else { return nil }
        return character
    }

    /// Whether a translated character is text a user types, as opposed to a key
    /// the layout reports as a control code or a private-use sentinel.
    ///
    /// Excluding the control range is what keeps `\n` and `\t` off the map:
    /// they must keep flowing through as literal characters rather than turning
    /// into Return/Tab keystrokes, which would commit dialogs and shift focus.
    /// The private-use range is how the layout reports arrows and function keys.
    private static func isTypeable(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        return true
    }

    // MARK: Text Input Services

    private static func activeUnicodeKeyLayoutData() -> Data? {
        if let data = unicodeKeyLayoutData(of: TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()) {
            return data
        }
        // An input method can be current without carrying layout data of its
        // own; the ASCII-capable layout behind it is what its keystrokes go
        // through.
        return unicodeKeyLayoutData(of: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    private static func unicodeKeyLayoutData(of source: TISInputSource?) -> Data? {
        guard let source,
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    }
}
