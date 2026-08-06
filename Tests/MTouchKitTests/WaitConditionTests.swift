import ApplicationServices
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures (literal AXNode trees, zero AX/TCC dependency)

private func textArea(_ value: String) -> AXNode {
    AXNode(role: "AXTextArea", value: value, actionable: true)
}

private func button(_ title: String) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, actionable: true)
}

/// A TextEdit-like window: a titled window containing a text area.
private func document(title: String, body: String) -> AXNode {
    AXNode(role: kAXWindowRole, title: title, children: [textArea(body)])
}

// MARK: - Criteria parsing + role mapping

@Suite struct WaitCriteriaTests {
    @Test func mapsFriendlyRoleWithoutSubstring() {
        let criteria = WaitCriteria(parsing: "textarea")
        #expect(criteria.role == "AXTextArea")
        #expect(criteria.substring == nil)
    }

    @Test func mapsFriendlyRoleWithQuotedSubstring() {
        let criteria = WaitCriteria(parsing: "button \"Save\"")
        #expect(criteria.role == "AXButton")
        #expect(criteria.substring == "Save")
    }

    @Test func acceptsRawAXRoleVerbatim() {
        #expect(WaitCriteria(parsing: "AXTextArea").role == "AXTextArea")
        #expect(WaitCriteria(parsing: "AXWindow").role == "AXWindow")
    }

    @Test func keepsUnknownRoleLiteralSoItTimesOutNotErrors() {
        // A misspelled role is not a parse error; it is used literally and simply
        // never matches (VAL: misspelled role → timeout, never usage error).
        let criteria = WaitCriteria(parsing: "blorp")
        #expect(criteria.role == "blorp")
        #expect(criteria.substring == nil)
    }

    @Test func roleMappingIsCaseInsensitive() {
        #expect(WaitCriteria(parsing: "Button").role == "AXButton")
        #expect(WaitCriteria(parsing: "WINDOW").role == "AXWindow")
    }

    @Test func descriptionEchoesCriteria() {
        #expect(WaitCriteria(parsing: "textarea").description == "AXTextArea")
        #expect(WaitCriteria(parsing: "button \"Save\"").description == "AXButton \"Save\"")
    }
}

// MARK: - Condition evaluator

@Suite struct WaitEvaluatorTests {
    private let tree = [document(title: "Untitled", body: "hello world")]

    @Test func appearsMatchesByRole() {
        #expect(WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: "textarea")), in: tree))
        #expect(!WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: "button")), in: tree))
    }

    @Test func appearsMatchesRoleWithSubstringOverTitleAndValue() {
        let withButton = [
            AXNode(role: kAXWindowRole, title: "Untitled", children: [button("Save"), textArea("hi")]),
        ]
        #expect(WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: "button \"Save\"")), in: withButton))
        #expect(!WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: "button \"NoSuchThing\"")), in: withButton))
        // Substring over VALUE, not just title.
        #expect(WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: "textarea \"hi\"")), in: withButton))
    }

    @Test func misspelledRoleNeverMatches() {
        #expect(!WaitEvaluator.evaluate(.appears(WaitCriteria(parsing: "blorp")), in: tree))
    }

    @Test func disappearsIsTrueWhenNothingMatches() {
        // Real: a role present in the tree does not satisfy disappears...
        #expect(!WaitEvaluator.evaluate(.disappears(WaitCriteria(parsing: "textarea")), in: tree))
        // ...but a role that never matched satisfies it vacuously.
        #expect(WaitEvaluator.evaluate(.disappears(WaitCriteria(parsing: "button")), in: tree))
        #expect(WaitEvaluator.evaluate(.disappears(WaitCriteria(parsing: "nonesuch")), in: tree))
    }

    @Test func textMatchesSubstringOverValue() {
        #expect(WaitEvaluator.evaluate(.text("hello"), in: tree))
        #expect(WaitEvaluator.evaluate(.text("world"), in: tree))
        #expect(!WaitEvaluator.evaluate(.text("goodbye"), in: tree))
    }

    @Test func textMatchesWindowTitle() {
        // A window's own title is content for --text (VAL-WAIT: window titles included).
        #expect(WaitEvaluator.evaluate(.text("Untitled"), in: tree))
    }

    @Test func valueEqualsRequiresExactValueUnscoped() {
        #expect(WaitEvaluator.evaluate(.valueEquals("hello world", of: nil), in: tree))
        // A substring is not an exact value.
        #expect(!WaitEvaluator.evaluate(.valueEquals("hello", of: nil), in: tree))
    }

    @Test func valueEqualsScopingRestrictsToMatchingCriteria() {
        let mixed = [
            AXNode(role: kAXWindowRole, title: "Untitled", children: [
                AXNode(role: kAXTextFieldRole, value: "target"),
                textArea("target"),
            ]),
        ]
        // Scoped to the text area: the text field also holding "target" is ignored,
        // but the text area matches, so it holds.
        #expect(WaitEvaluator.evaluate(.valueEquals("target", of: WaitCriteria(parsing: "textarea")), in: mixed))
        // Scoped to a role NOT holding "target": no match.
        #expect(!WaitEvaluator.evaluate(.valueEquals("target", of: WaitCriteria(parsing: "button")), in: mixed))
    }

    @Test func valueEqualsIsUnicodeNormalizationInsensitive() {
        // Precomposed "café" (NFC) vs decomposed "cafe" + combining acute (NFD):
        // genuinely different Unicode ENCODINGS — the scalar sequences differ...
        let nfc = "café"
        let nfd = "cafe\u{0301}"
        #expect(Array(nfc.unicodeScalars) != Array(nfd.unicodeScalars))

        // ...yet the evaluator NFC-folds both, so a target in either form matches a
        // value stored in the other (VAL-WAIT-013).
        let decomposedTree = [AXNode(role: kAXWindowRole, children: [textArea(nfd)])]
        #expect(WaitEvaluator.evaluate(.valueEquals(nfc, of: nil), in: decomposedTree))

        let composedTree = [AXNode(role: kAXWindowRole, children: [textArea(nfc)])]
        #expect(WaitEvaluator.evaluate(.valueEquals(nfd, of: nil), in: composedTree))

        // And the normalizer itself yields byte-identical NFC output for both forms.
        #expect(WaitEvaluator.normalized(nfc) == WaitEvaluator.normalized(nfd))
        #expect(Array(WaitEvaluator.normalized(nfd).unicodeScalars) == Array(nfc.unicodeScalars))
    }
}

// MARK: - Grammar (exclusivity matrix)

@Suite struct WaitGrammarTests {
    @Test func exactlyOneConditionIsValid() {
        #expect(WaitGrammar.selectionError(
            appears: "textarea", disappears: nil, text: nil, valueEquals: nil, of: nil
        ) == nil)
        #expect(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: "x", valueEquals: nil, of: nil
        ) == nil)
        #expect(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: nil, valueEquals: "v", of: "textarea"
        ) == nil)
    }

    @Test func zeroConditionsIsAnError() {
        #expect(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: nil, valueEquals: nil, of: nil
        ) != nil)
    }

    @Test func multipleConditionsAreExclusive() {
        // Every combination the brief calls out returns a usage error.
        #expect(WaitGrammar.selectionError(
            appears: "a", disappears: "b", text: nil, valueEquals: nil, of: nil
        ) != nil)
        #expect(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: "t", valueEquals: "v", of: nil
        ) != nil)
        #expect(WaitGrammar.selectionError(
            appears: "a", disappears: nil, text: "t", valueEquals: nil, of: nil
        ) != nil)
    }

    @Test func ofRequiresValueEquals() {
        #expect(WaitGrammar.selectionError(
            appears: "textarea", disappears: nil, text: nil, valueEquals: nil, of: "textarea"
        ) != nil)
    }

    @Test func emptyTextIsAnError() {
        #expect(WaitGrammar.selectionError(
            appears: nil, disappears: nil, text: "", valueEquals: nil, of: nil
        ) != nil)
    }

    @Test func makeConditionBuildsTheSelectedCondition() {
        #expect(WaitGrammar.makeCondition(
            appears: "textarea", disappears: nil, text: nil, valueEquals: nil, of: nil
        ) == .appears(WaitCriteria(role: "AXTextArea")))
        #expect(WaitGrammar.makeCondition(
            appears: nil, disappears: nil, text: nil, valueEquals: "v", of: "textarea"
        ) == .valueEquals("v", of: WaitCriteria(role: "AXTextArea")))
    }
}
