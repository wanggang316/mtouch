import AppKit
import Foundation

/// The system clipboard behind ONE seam, so read/write/clear are unit-testable
/// without touching the real pasteboard (which is shared global state a test run
/// must never clobber).
///
/// `changeCount` is part of the seam because it is the only way an agent can tell
/// that SOMETHING ELSE wrote to the clipboard between two of its own steps: the
/// counter increments on every write by any process, so a step that captured it
/// during `get` can detect interference before trusting a later paste.
public protocol PasteboardAccess {
    /// Monotonic counter incremented by every write from any process.
    var changeCount: Int { get }
    /// Current text content, nil when the clipboard holds no text representation.
    func string() -> String?
    /// Raw type identifiers currently present, e.g. `public.utf8-plain-text`.
    func types() -> [String]
    /// Replace the contents with `value` as text. Returns whether the WRITE was
    /// accepted — the caller still reads back to confirm it actually took.
    func setString(_ value: String) -> Bool
    /// Remove all contents.
    func clear()
}

/// Live access to the general pasteboard.
public struct LivePasteboard: PasteboardAccess {
    public init() {}

    private var board: NSPasteboard { .general }

    public var changeCount: Int { board.changeCount }

    public func string() -> String? { board.string(forType: .string) }

    public func types() -> [String] { (board.types ?? []).map(\.rawValue) }

    public func setString(_ value: String) -> Bool {
        // A write must own the pasteboard first; without `clearContents()` the
        // declared types of the previous owner linger and the write is refused.
        board.clearContents()
        return board.setString(value, forType: .string)
    }

    public func clear() {
        board.clearContents()
    }
}

/// The observable outcome of a `clipboard` invocation, kept SEPARATE from the side
/// effects so the exit-code mapping is unit-testable. `.rendered(nil)` means
/// SUCCESS WITH NO OUTPUT (a write is confirmed by exit 0, not by chatter), which
/// is distinct from `.rendered("")` — a clipboard that genuinely holds the empty
/// string.
public enum ClipboardOutcome: Equatable, Sendable {
    case rendered(String?)
    case failed(stderr: String, code: MTouchExitCode)
}

/// Composes the three `clipboard` verbs.
///
/// The load-bearing rule is on the WRITE path: a pasteboard write can be refused
/// or silently dropped (another process owning the board, a sandbox denial), and a
/// paste that follows a "successful" write would then paste the PREVIOUS content —
/// a wrong action that looks exactly like a right one. So every write is read back
/// and verified, and a mismatch is a failure (exit 1). No diagnostic ever echoes
/// the payload: a clipboard is a common carrier for credentials.
///
/// Text only in this pass; image and file-URL contents are reported by TYPE on
/// `get` (so an agent is told what is there rather than shown an empty answer) but
/// cannot yet be read or written. Extending to those types is future work.
public enum ClipboardPipeline {
    /// Read the clipboard's text.
    ///
    /// Three distinguishable states, because collapsing them would let an agent
    /// mistake "there is an image on the clipboard" for "the clipboard is empty":
    ///   - text present  -> the text, exit 0;
    ///   - nothing at all -> no output, exit 0 (empty IS a truthful answer);
    ///   - non-text content only -> exit 1 naming the types that ARE there.
    public static func get(
        json: Bool,
        pasteboard: PasteboardAccess = LivePasteboard()
    ) -> ClipboardOutcome {
        let changeCount = pasteboard.changeCount
        let types = pasteboard.types()
        guard let text = pasteboard.string() else {
            guard types.isEmpty else {
                return .failed(stderr: nonTextDiagnostic(types: types), code: .runtimeFailure)
            }
            return .rendered(json ? getJSON(text: nil, changeCount: changeCount, types: types) : nil)
        }
        return .rendered(json ? getJSON(text: text, changeCount: changeCount, types: types) : text)
    }

    /// Write text to the clipboard, then READ IT BACK and confirm it round-trips.
    public static func set(
        text: String,
        json: Bool,
        pasteboard: PasteboardAccess = LivePasteboard()
    ) -> ClipboardOutcome {
        guard pasteboard.setString(text) else {
            return .failed(stderr: writeRefusedDiagnostic(), code: .runtimeFailure)
        }
        let readBack = pasteboard.string()
        guard readBack == text else {
            return .failed(
                stderr: roundTripDiagnostic(wrote: text, readBack: readBack),
                code: .runtimeFailure
            )
        }
        guard json else { return .rendered(nil) }
        return .rendered("{\"changeCount\":\(pasteboard.changeCount),\"bytes\":\(text.utf8.count)}")
    }

    /// Empty the clipboard, then confirm nothing text-like survived.
    public static func clear(
        json: Bool,
        pasteboard: PasteboardAccess = LivePasteboard()
    ) -> ClipboardOutcome {
        pasteboard.clear()
        if let remaining = pasteboard.string(), !remaining.isEmpty {
            return .failed(stderr: clearRefusedDiagnostic(), code: .runtimeFailure)
        }
        guard json else { return .rendered(nil) }
        return .rendered("{\"changeCount\":\(pasteboard.changeCount)}")
    }

    // MARK: - Rendering

    /// `{"text":<string|null>,"changeCount":N,"types":[…]}` — a STABLE shape: every
    /// key is always present, so `jq` never has to branch on absence, and
    /// `changeCount` lets a later step detect an external write.
    static func getJSON(text: String?, changeCount: Int, types: [String]) -> String {
        let textField = text.map(JSONText.string) ?? "null"
        let typeList = types.map(JSONText.string).joined(separator: ",")
        return "{\"text\":\(textField),\"changeCount\":\(changeCount),\"types\":[\(typeList)]}"
    }

    // MARK: - Diagnostics (never echo the payload)

    static func nonTextDiagnostic(types: [String]) -> String {
        "mtouch: the clipboard holds no text; it currently carries \(types.joined(separator: ", ")). "
            + "Only text is supported in this version."
    }

    static func writeRefusedDiagnostic() -> String {
        "mtouch: the clipboard refused the write. Another application may own the pasteboard; "
            + "retry, or check with 'mtouch clipboard get'."
    }

    /// Reports the SIZE of both sides, never their content: the payload may be a
    /// secret, and the byte counts are what actually diagnose a truncated write.
    static func roundTripDiagnostic(wrote: String, readBack: String?) -> String {
        let actual = readBack.map { "\($0.utf8.count) byte(s)" } ?? "nothing"
        return "mtouch: the clipboard did not round-trip: wrote \(wrote.utf8.count) byte(s) but read back "
            + "\(actual). The write did not take, so nothing should be pasted from it."
    }

    static func clearRefusedDiagnostic() -> String {
        "mtouch: the clipboard still holds text after being cleared. Another application may own "
            + "the pasteboard and have rewritten it."
    }
}
