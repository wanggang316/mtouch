import Carbon.HIToolbox
import CoreGraphics

/// A parsed keyboard shortcut: exactly one non-modifier key plus zero or more
/// modifier flags, resolved to the `CGKeyCode` + `CGEventFlags` a keyboard
/// `CGEvent` needs. Parsing is the ONLY place key/modifier names are
/// interpreted; the synthesizer just emits the resolved codes.
public struct KeyCombo: Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags

    public init(keyCode: CGKeyCode, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.flags = flags
    }

    /// Parses the pinned `cmd+shift+a` grammar (case-insensitive, `+`-separated,
    /// surrounding whitespace tolerated). Tokens resolve to modifiers or the
    /// single key; anything else — or zero/multiple keys — is a typed parse
    /// error the CLI maps to exit 64.
    public init(parsing string: String) throws {
        let tokens = string
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        guard !tokens.isEmpty, !tokens.contains("") else {
            throw KeyComboParseError(input: string, reason: .malformed)
        }

        var flags: CGEventFlags = []
        var resolvedKey: CGKeyCode?
        for token in tokens {
            if let modifier = KeyCombo.modifierFlags[token] {
                flags.insert(modifier)
            } else if let code = KeyCombo.keyCodes[token] {
                guard resolvedKey == nil else {
                    throw KeyComboParseError(input: string, reason: .multipleKeys)
                }
                resolvedKey = code
            } else {
                throw KeyComboParseError(input: string, reason: .unknownToken(token))
            }
        }

        guard let key = resolvedKey else {
            throw KeyComboParseError(input: string, reason: .noKey)
        }

        self.init(keyCode: key, flags: flags)
    }

    /// Modifier vocabulary → event flag, with the pinned synonyms.
    static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "ctrl": .maskControl, "control": .maskControl,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "fn": .maskSecondaryFn,
    ]

    /// Named-key vocabulary → virtual key code (from Carbon's `kVK_*`), with the
    /// pinned synonyms. Letters, digits, editing/navigation keys, arrows, and
    /// function keys f1..f20.
    static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [:]

        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ]
        let digits: [(String, Int)] = [
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
            ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ]
        let named: [(String, Int)] = [
            ("return", kVK_Return), ("enter", kVK_Return),
            ("tab", kVK_Tab), ("space", kVK_Space),
            ("escape", kVK_Escape), ("esc", kVK_Escape),
            ("delete", kVK_Delete), ("backspace", kVK_Delete),
            ("left", kVK_LeftArrow), ("right", kVK_RightArrow),
            ("up", kVK_UpArrow), ("down", kVK_DownArrow),
            ("home", kVK_Home), ("end", kVK_End),
            ("pageup", kVK_PageUp), ("pagedown", kVK_PageDown),
        ]
        let functionKeys: [(String, Int)] = [
            ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4),
            ("f5", kVK_F5), ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8),
            ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
            ("f13", kVK_F13), ("f14", kVK_F14), ("f15", kVK_F15), ("f16", kVK_F16),
            ("f17", kVK_F17), ("f18", kVK_F18), ("f19", kVK_F19), ("f20", kVK_F20),
        ]

        for (name, code) in letters + digits + named + functionKeys {
            map[name] = CGKeyCode(code)
        }
        return map
    }()
}

/// Typed failure from `KeyCombo(parsing:)`. The CLI maps it to exit 64
/// (usage). The message names the offending token but never any typed content
/// (a combo is key names, not free text).
public struct KeyComboParseError: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case malformed
        case unknownToken(String)
        case multipleKeys
        case noKey
    }

    public let input: String
    public let reason: Reason

    public init(input: String, reason: Reason) {
        self.input = input
        self.reason = reason
    }

    public var message: String {
        let detail: String
        switch reason {
        case .malformed:
            detail = "not a valid key combination"
        case .unknownToken(let token):
            detail = "unknown modifier or key '\(token)'"
        case .multipleKeys:
            detail = "more than one non-modifier key"
        case .noKey:
            detail = "no non-modifier key"
        }
        return "mtouch: invalid key combination '\(input)': \(detail)."
    }

    /// Exit code the CLI maps this parse failure to.
    public var exitCode: MTouchExitCode { .usageError }
}
