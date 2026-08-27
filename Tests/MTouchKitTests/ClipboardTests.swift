import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

/// A pasteboard stand-in: the real one is shared global state a test run must
/// never clobber. It models the two ways a real write goes wrong — a REFUSED
/// write, and a write that reports success but does not take.
private final class FakePasteboard: PasteboardAccess {
    private(set) var text: String?
    private(set) var changeCount = 0
    var declaredTypes: [String] = []
    /// Whether `setString` reports acceptance.
    var acceptsWrites = true
    /// When set, the value the board actually ends up holding after a write,
    /// regardless of what was written (a silently dropped or mangled write).
    var writesLandAs: String??
    /// Whether `clear` really empties the board.
    var clearWorks = true

    init(text: String? = nil, types: [String] = []) {
        self.text = text
        self.declaredTypes = types
    }

    func string() -> String? { text }

    func types() -> [String] { declaredTypes }

    func setString(_ value: String) -> Bool {
        guard acceptsWrites else { return false }
        changeCount += 1
        if let landed = writesLandAs {
            text = landed
        } else {
            text = value
            declaredTypes = ["public.utf8-plain-text"]
        }
        return true
    }

    func clear() {
        changeCount += 1
        guard clearWorks else { return }
        text = nil
        declaredTypes = []
    }
}

private func failure(_ outcome: ClipboardOutcome) -> (stderr: String, code: MTouchExitCode)? {
    guard case let .failed(stderr, code) = outcome else { return nil }
    return (stderr, code)
}

/// The rendered stdout of a successful outcome — `.some(nil)` for a SILENT
/// success — or nil when the outcome was a failure.
private func rendered(_ outcome: ClipboardOutcome) -> String?? {
    guard case let .rendered(output) = outcome else { return nil }
    return output
}

// MARK: - get

@Suite struct ClipboardGetTests {
    @Test func printsTheClipboardText() {
        let board = FakePasteboard(text: "hello", types: ["public.utf8-plain-text"])
        #expect(rendered(ClipboardPipeline.get(json: false, pasteboard: board)) == .some("hello"))
    }

    @Test func anEmptyClipboardPrintsNothingAndSucceeds() {
        // Empty is a truthful answer, so it is exit 0 with no output — not an error.
        let outcome = ClipboardPipeline.get(json: false, pasteboard: FakePasteboard())
        #expect(rendered(outcome) == .some(.none))
    }

    @Test func anEmptyStringIsDistinctFromAnEmptyClipboard() {
        let board = FakePasteboard(text: "", types: ["public.utf8-plain-text"])
        #expect(rendered(ClipboardPipeline.get(json: false, pasteboard: board)) == .some(""))
    }

    @Test func nonTextContentIsNamedRatherThanShownAsEmpty() {
        // An image on the clipboard must never look like an empty clipboard: an
        // agent would "confirm" the clipboard was clear and paste nothing.
        let board = FakePasteboard(text: nil, types: ["public.tiff", "public.png"])
        let result = failure(ClipboardPipeline.get(json: false, pasteboard: board))
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("public.tiff") == true)
        #expect(result?.stderr.contains("no text") == true)
    }

    @Test func jsonReportsTextChangeCountAndTypes() throws {
        let board = FakePasteboard(text: "hi", types: ["public.utf8-plain-text"])
        _ = board.setString("hi")                       // bump the change counter
        let output = try #require(rendered(ClipboardPipeline.get(json: true, pasteboard: board)))
        #expect(output == "{\"text\":\"hi\",\"changeCount\":1,\"types\":[\"public.utf8-plain-text\"]}")
    }

    @Test func jsonKeepsAStableShapeForAnEmptyClipboard() throws {
        let output = try #require(rendered(ClipboardPipeline.get(json: true, pasteboard: FakePasteboard())))
        #expect(output == "{\"text\":null,\"changeCount\":0,\"types\":[]}")
    }

    @Test func jsonEscapesTextSoItSurvivesAJSONRoundTrip() throws {
        let board = FakePasteboard(text: "line\n\"quoted\" 元宝", types: [])
        let output = try #require(rendered(ClipboardPipeline.get(json: true, pasteboard: board)))
        let data = try #require(output?.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["text"] as? String == "line\n\"quoted\" 元宝")
    }
}

// MARK: - set

@Suite struct ClipboardSetTests {
    @Test func writesTheTextAndSucceedsSilently() throws {
        let board = FakePasteboard()
        let outcome = ClipboardPipeline.set(text: "hello", json: false, pasteboard: board)
        let output = try #require(rendered(outcome))
        #expect(output == nil)                          // exit 0 is the signal
        #expect(board.string() == "hello")
    }

    @Test func aRefusedWriteIsExitOne() {
        let board = FakePasteboard()
        board.acceptsWrites = false
        let result = failure(ClipboardPipeline.set(text: "hello", json: false, pasteboard: board))
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("refused") == true)
    }

    @Test func aWriteThatDoesNotRoundTripIsExitOne() {
        // The load-bearing case: the write reported success but the board holds
        // something else, so a following paste would paste the WRONG text.
        let board = FakePasteboard(text: "previous")
        board.writesLandAs = .some("previous")
        let result = failure(ClipboardPipeline.set(text: "hello", json: false, pasteboard: board))
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("did not round-trip") == true)
    }

    @Test func aDroppedWriteIsExitOne() {
        let board = FakePasteboard()
        board.writesLandAs = .some(nil)
        let result = failure(ClipboardPipeline.set(text: "hello", json: false, pasteboard: board))
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("read back nothing") == true)
    }

    @Test func theMismatchDiagnosticNeverEchoesThePayload() {
        // A clipboard is a common carrier for credentials: the diagnostic reports
        // SIZES, never content.
        let board = FakePasteboard()
        board.writesLandAs = .some("truncated")
        let result = failure(ClipboardPipeline.set(text: "sup3r-s3cret", json: false, pasteboard: board))
        #expect(result?.stderr.contains("sup3r-s3cret") == false)
        #expect(result?.stderr.contains("truncated") == false)
        #expect(result?.stderr.contains("12 byte(s)") == true)
    }

    @Test func unicodeRoundTripsByBytesNotCharacters() throws {
        let board = FakePasteboard()
        let outcome = ClipboardPipeline.set(text: "元宝", json: true, pasteboard: board)
        let output = try #require(rendered(outcome))
        #expect(output == "{\"changeCount\":1,\"bytes\":6}")
    }

    @Test func jsonReportsTheChangeCountSoExternalWritesAreDetectable() throws {
        let board = FakePasteboard()
        _ = board.setString("first")
        let output = try #require(rendered(ClipboardPipeline.set(text: "second", json: true, pasteboard: board)))
        #expect(output == "{\"changeCount\":2,\"bytes\":6}")
    }
}

// MARK: - clear

@Suite struct ClipboardClearTests {
    @Test func emptiesTheClipboard() throws {
        let board = FakePasteboard(text: "hello", types: ["public.utf8-plain-text"])
        let output = try #require(rendered(ClipboardPipeline.clear(json: false, pasteboard: board)))
        #expect(output == nil)
        #expect(board.string() == nil)
    }

    @Test func aClearThatDidNotTakeIsExitOne() {
        let board = FakePasteboard(text: "hello")
        board.clearWorks = false
        let result = failure(ClipboardPipeline.clear(json: false, pasteboard: board))
        #expect(result?.code == .runtimeFailure)
        #expect(result?.stderr.contains("still holds text") == true)
    }

    @Test func jsonReportsTheChangeCount() throws {
        let board = FakePasteboard(text: "hello")
        let output = try #require(rendered(ClipboardPipeline.clear(json: true, pasteboard: board)))
        #expect(output == "{\"changeCount\":1}")
    }
}
