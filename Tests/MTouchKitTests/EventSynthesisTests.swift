import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Recording seams

/// Shared timeline for the two side-effecting seams so tests can assert that
/// activation precedes every posted event (not just that both happened).
private final class SynthesisRecorder {
    enum Step: Equatable {
        case activated(pid_t)
        case posted
    }

    private(set) var steps: [Step] = []
    private(set) var posted: [CGEvent] = []

    func recordActivation(_ pid: pid_t) {
        steps.append(.activated(pid))
    }

    func recordPost(_ event: CGEvent) {
        steps.append(.posted)
        posted.append(event)
    }

    /// Stands in for the window server's per-type delivery counter: an event is
    /// "delivered" the moment this fake poster has recorded it.
    func delivered(_ type: CGEventType) -> UInt32 {
        UInt32(posted.filter { $0.type == type }.count)
    }
}

private struct RecordingActivator: Activator {
    let recorder: SynthesisRecorder
    func activate(pid: pid_t) { recorder.recordActivation(pid) }
}

private struct RecordingPoster: EventPoster {
    let recorder: SynthesisRecorder
    func post(_ event: CGEvent) { recorder.recordPost(event) }
}

private struct StubSecureInput: SecureInputState {
    let active: Bool
    var isSecureInputActive: Bool { active }
}

/// The delivery counter the flush polls, answered from what the recording poster
/// has seen. It makes delivery INSTANT, so these synthesis tests exercise the real
/// post-then-flush path while touching neither the window server nor the clock.
private struct RecordedDeliveryCounter: EventDeliveryCounter {
    let recorder: SynthesisRecorder
    func count(of type: CGEventType) -> UInt32 { recorder.delivered(type) }
}

private let testPID: pid_t = 4242

private func makeSynthesizer(
    secureInputActive: Bool = false,
    pid: pid_t = testPID
) -> (InputSynthesizer, SynthesisRecorder) {
    let recorder = SynthesisRecorder()
    let synthesizer = InputSynthesizer(
        targetPID: pid,
        activator: RecordingActivator(recorder: recorder),
        secureInput: StubSecureInput(active: secureInputActive),
        poster: RecordingPoster(recorder: recorder),
        source: nil,
        flush: InputDeliveryFlush(
            counter: RecordedDeliveryCounter(recorder: recorder),
            now: { 0 },
            sleep: { _ in Issue.record("an already-delivered burst must confirm without waiting") }
        )
    )
    return (synthesizer, recorder)
}

/// Reads the UTF-16 payload a keydown/keyup event carries back out, so unicode
/// typing can be asserted from the recorded events.
private func unicodeString(of event: CGEvent) -> String {
    var length = 0
    event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
    guard length > 0 else { return "" }
    var buffer = [UniChar](repeating: 0, count: length)
    event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &buffer)
    return String(utf16CodeUnits: buffer, count: length)
}

// MARK: - Secure input refusal (VAL-ACT-014)

@Suite struct SecureInputRefusalTests {
    @Test func typeRefusesAndDeliversZeroEvents() {
        let (synthesizer, recorder) = makeSynthesizer(secureInputActive: true)
        #expect(throws: SecureInputActive.self) {
            try synthesizer.type("some text")
        }
        #expect(recorder.posted.isEmpty)
        #expect(recorder.steps.isEmpty) // not even activation on refusal
    }

    @Test func keyRefusesAndDeliversZeroEvents() throws {
        let (synthesizer, recorder) = makeSynthesizer(secureInputActive: true)
        let combo = try KeyCombo(parsing: "cmd+a")
        #expect(throws: SecureInputActive.self) {
            try synthesizer.key(combo)
        }
        #expect(recorder.posted.isEmpty)
        #expect(recorder.steps.isEmpty)
    }

    @Test func refusalDiagnosticNeverLeaksTheTypedPayload() {
        let secret = "TOPSECRET-correct-horse-battery-staple-9931"
        let (synthesizer, recorder) = makeSynthesizer(secureInputActive: true)
        do {
            try synthesizer.type(secret)
            Issue.record("expected secure input to block typing")
        } catch let error as SecureInputActive {
            #expect(!error.diagnostic.isEmpty)
            #expect(!error.diagnostic.contains(secret))
            #expect(!"\(error)".contains(secret))
            #expect(error.exitCode == .secureInput)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(recorder.posted.isEmpty)
    }

    @Test func synthesisProceedsWhenSecureInputInactive() throws {
        let (synthesizer, recorder) = makeSynthesizer(secureInputActive: false)
        try synthesizer.type("ok")
        #expect(!recorder.posted.isEmpty)
    }
}

// MARK: - Key combo parsing

@Suite struct KeyComboParsingTests {
    @Test func parsesModifiersAndKey() throws {
        let combo = try KeyCombo(parsing: "cmd+shift+a")
        let expectedA = try #require(KeyCombo.keyCodes["a"])
        #expect(combo.keyCode == expectedA)
        #expect(combo.flags == [.maskCommand, .maskShift])
    }

    @Test func isCaseInsensitiveAndWhitespaceTolerant() throws {
        let combo = try KeyCombo(parsing: "  CMD + Shift + A ")
        let expectedA = try #require(KeyCombo.keyCodes["a"])
        #expect(combo.keyCode == expectedA)
        #expect(combo.flags == [.maskCommand, .maskShift])
    }

    @Test func acceptsModifierSynonyms() throws {
        let optionEsc = try KeyCombo(parsing: "option+esc")
        let optEscape = try KeyCombo(parsing: "opt+escape")
        let altEscape = try KeyCombo(parsing: "alt+escape")
        #expect(optionEsc == optEscape)
        #expect(optEscape == altEscape)
        let expectedEscape = try #require(KeyCombo.keyCodes["escape"])
        #expect(optionEsc.keyCode == expectedEscape)
        #expect(optionEsc.flags == .maskAlternate)
    }

    @Test func acceptsBareKeyWithoutModifiers() throws {
        let combo = try KeyCombo(parsing: "RETURN")
        let expectedReturn = try #require(KeyCombo.keyCodes["return"])
        #expect(combo.keyCode == expectedReturn)
        #expect(combo.flags.isEmpty)
    }

    @Test func mapsFunctionAndNavigationKeys() throws {
        let fn = try KeyCombo(parsing: "fn+f1")
        let expectedF1 = try #require(KeyCombo.keyCodes["f1"])
        #expect(fn.keyCode == expectedF1)
        #expect(fn.flags == .maskSecondaryFn)

        let nav = try KeyCombo(parsing: "ctrl+pagedown")
        let expectedPageDown = try #require(KeyCombo.keyCodes["pagedown"])
        #expect(nav.keyCode == expectedPageDown)
        #expect(nav.flags == .maskControl)
    }

    @Test func returnAndEnterAreSynonyms() throws {
        #expect(try KeyCombo(parsing: "return") == KeyCombo(parsing: "enter"))
        #expect(try KeyCombo(parsing: "delete") == KeyCombo(parsing: "backspace"))
    }

    @Test(arguments: [
        "",
        "cmd",
        "cmd+shift",
        "a+b",
        "cmd+foo",
        "hyper+a",
        "cmd+",
        "+a",
    ])
    func rejectsUnknownOrMalformedCombos(_ input: String) {
        #expect(throws: KeyComboParseError.self) {
            try KeyCombo(parsing: input)
        }
    }

    @Test func reportsUnknownTokenAsUsageError() {
        do {
            _ = try KeyCombo(parsing: "cmd+nope")
            Issue.record("expected parse failure")
        } catch let error as KeyComboParseError {
            #expect(error.reason == .unknownToken("nope"))
            #expect(error.exitCode == .usageError)
            #expect(error.message.contains("nope"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func reportsMissingAndMultipleKeys() {
        #expect(throws: KeyComboParseError(input: "cmd", reason: .noKey)) {
            try KeyCombo(parsing: "cmd")
        }
        #expect(throws: KeyComboParseError(input: "a+b", reason: .multipleKeys)) {
            try KeyCombo(parsing: "a+b")
        }
    }
}

// MARK: - Keyboard synthesis

@Suite struct KeyboardSynthesisTests {
    @Test func unicodeTypingReconstructsInputAcrossScriptsAndLiterals() throws {
        let text = "aA1é😀中\n\t "
        let (synthesizer, recorder) = makeSynthesizer()
        try synthesizer.type(text)

        // One keydown/keyup pair per grapheme.
        let graphemeCount = text.count
        #expect(recorder.posted.count == graphemeCount * 2)
        #expect(recorder.posted.filter { $0.type == .keyDown }.count == graphemeCount)
        #expect(recorder.posted.filter { $0.type == .keyUp }.count == graphemeCount)

        let reconstructed = recorder.posted
            .filter { $0.type == .keyDown }
            .map(unicodeString(of:))
            .joined()
        #expect(reconstructed == text)
    }

    @Test func comboEmitsKeycodeAndModifierFlags() throws {
        let (synthesizer, recorder) = makeSynthesizer()
        try synthesizer.key(KeyCombo(parsing: "cmd+shift+a"))

        #expect(recorder.posted.count == 2)
        let down = recorder.posted[0]
        let up = recorder.posted[1]
        #expect(down.type == .keyDown)
        #expect(up.type == .keyUp)

        let expectedKey = try #require(KeyCombo.keyCodes["a"])
        #expect(CGKeyCode(down.getIntegerValueField(.keyboardEventKeycode)) == expectedKey)
        #expect(down.flags.contains(.maskCommand))
        #expect(down.flags.contains(.maskShift))
    }
}

// MARK: - Mouse synthesis

@Suite struct MouseSynthesisTests {
    @Test func clickPostsDownThenUpAtPoint() {
        let (synthesizer, recorder) = makeSynthesizer()
        synthesizer.click(at: ScreenPoint(x: 100, y: 250))

        #expect(recorder.posted.count == 2)
        #expect(recorder.posted[0].type == .leftMouseDown)
        #expect(recorder.posted[1].type == .leftMouseUp)
        #expect(recorder.posted[0].location == CGPoint(x: 100, y: 250))
        #expect(recorder.posted[1].location == CGPoint(x: 100, y: 250))
    }

    @Test func rightClickUsesRightButtonEvents() {
        let (synthesizer, recorder) = makeSynthesizer()
        synthesizer.rightClick(at: ScreenPoint(x: 5, y: 6))
        #expect(recorder.posted.map(\.type) == [.rightMouseDown, .rightMouseUp])
    }

    @Test func doubleClickPostsTwoPairsAndRaisesClickState() {
        let (synthesizer, recorder) = makeSynthesizer()
        synthesizer.doubleClick(at: ScreenPoint(x: 10, y: 10))

        #expect(recorder.posted.count == 4)
        #expect(recorder.posted[0].getIntegerValueField(.mouseEventClickState) == 1)
        #expect(recorder.posted[3].getIntegerValueField(.mouseEventClickState) == 2)
    }

    @Test func dragMovesFromStartToEnd() {
        let (synthesizer, recorder) = makeSynthesizer()
        synthesizer.drag(from: ScreenPoint(x: 0, y: 0), to: ScreenPoint(x: 40, y: 80))

        #expect(recorder.posted.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        #expect(recorder.posted[0].location == CGPoint(x: 0, y: 0))
        #expect(recorder.posted[2].location == CGPoint(x: 40, y: 80))
    }
}

// MARK: - Scroll sign mapping

@Suite struct ScrollSynthesisTests {
    @Test func positiveDyScrollsContentUp() {
        let (synthesizer, recorder) = makeSynthesizer()
        synthesizer.scroll(at: ScreenPoint(x: 10, y: 20), dy: 3)

        #expect(recorder.posted.count == 1)
        let event = recorder.posted[0]
        #expect(event.type == .scrollWheel)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3)
        #expect(event.location == CGPoint(x: 10, y: 20))
    }

    @Test func negativeDyScrollsContentDown() {
        let (synthesizer, recorder) = makeSynthesizer()
        synthesizer.scroll(at: ScreenPoint(x: 0, y: 0), dy: -5)
        #expect(recorder.posted[0].getIntegerValueField(.scrollWheelEventDeltaAxis1) == -5)
    }
}

// MARK: - Activation ordering

@Suite struct ActivationOrderingTests {
    @Test func typeActivatesTargetBeforeAnyEvent() throws {
        let (synthesizer, recorder) = makeSynthesizer(pid: 777)
        try synthesizer.type("hi")

        #expect(recorder.steps.first == .activated(777))
        let activationSteps = recorder.steps.filter { $0 == .activated(777) }
        #expect(activationSteps.count == 1)
        // Every posted event comes after the single activation.
        let firstPostIndex = recorder.steps.firstIndex(of: .posted)
        let activationIndex = recorder.steps.firstIndex(of: .activated(777))
        #expect(activationIndex! < firstPostIndex!)
    }

    @Test func clickActivatesTargetBeforeAnyEvent() {
        let (synthesizer, recorder) = makeSynthesizer(pid: 777)
        synthesizer.click(at: ScreenPoint(x: 1, y: 1))
        #expect(recorder.steps.first == .activated(777))
        #expect(recorder.steps.filter { $0 == .posted }.count == 2)
    }
}
