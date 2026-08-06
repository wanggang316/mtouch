import Testing
@testable import MTouchKit

@Suite struct MTouchExitCodeTests {
    @Test func taxonomyMatchesContract() {
        #expect(MTouchExitCode.success.rawValue == 0)
        #expect(MTouchExitCode.runtimeFailure.rawValue == 1)
        #expect(MTouchExitCode.permissionMissing.rawValue == 2)
        #expect(MTouchExitCode.refError.rawValue == 3)
        #expect(MTouchExitCode.waitTimeout.rawValue == 4)
        #expect(MTouchExitCode.secureInput.rawValue == 5)
        #expect(MTouchExitCode.usageError.rawValue == 64)
    }

    @Test func taxonomyHasNoDuplicateRawValues() {
        let rawValues = MTouchExitCode.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }
}

@Suite struct ScreenPointTests {
    @Test func parsesIntegerPair() {
        #expect(ScreenPoint(parsing: "120,64") == ScreenPoint(x: 120, y: 64))
    }

    @Test func parsesDecimalsAndNegatives() {
        #expect(ScreenPoint(parsing: "10.5,-3.25") == ScreenPoint(x: 10.5, y: -3.25))
    }

    @Test func parsesWhitespaceAroundComponents() {
        #expect(ScreenPoint(parsing: " 10 , 20 ") == ScreenPoint(x: 10, y: 20))
    }

    @Test(arguments: ["", "10", "10,", ",20", "a,b", "1,2,3", "10;20"])
    func rejectsMalformedInput(_ input: String) {
        #expect(ScreenPoint(parsing: input) == nil)
    }

    @Test(arguments: ["inf,3", "nan,0", "3,inf", "0,nan", "-inf,1"])
    func rejectsNonFiniteComponents(_ input: String) {
        // A non-finite coordinate is never a real click target.
        #expect(ScreenPoint(parsing: input) == nil)
    }
}

@Suite struct WaitDurationTests {
    @Test func parsesBareSecondsForBackCompat() {
        #expect(WaitDuration(parsing: "5") == WaitDuration(seconds: 5))
        #expect(WaitDuration(parsing: "2.5") == WaitDuration(seconds: 2.5))
        #expect(WaitDuration(parsing: "0") == WaitDuration(seconds: 0))
    }

    @Test func parsesSecondsSuffix() {
        #expect(WaitDuration(parsing: "5s") == WaitDuration(seconds: 5))
        #expect(WaitDuration(parsing: "2s") == WaitDuration(seconds: 2))
        #expect(WaitDuration(parsing: "0.5s") == WaitDuration(seconds: 0.5))
    }

    @Test func parsesMillisecondsSuffix() {
        #expect(WaitDuration(parsing: "500ms") == WaitDuration(seconds: 0.5))
        #expect(WaitDuration(parsing: "100ms") == WaitDuration(seconds: 0.1))
        #expect(WaitDuration(parsing: "0ms") == WaitDuration(seconds: 0))
    }

    @Test func toleratesWhitespaceAndCase() {
        #expect(WaitDuration(parsing: " 5S ") == WaitDuration(seconds: 5))
        #expect(WaitDuration(parsing: "250MS") == WaitDuration(seconds: 0.25))
    }

    @Test(arguments: ["", "-1", "-1s", "abc", "5sx", "s", "ms", "5 s", "1.2.3"])
    func rejectsMalformedInput(_ input: String) {
        #expect(WaitDuration(parsing: input) == nil)
    }

    @Test(arguments: ["inf", "nan", "infinity", "infs", "infms", "-inf"])
    func rejectsNonFiniteValues(_ input: String) {
        // A non-finite timeout must be a usage error (exit 64), never an unbounded
        // poll: `Double("inf")` is `>= 0` but not finite, so the finite guard is
        // what rejects it.
        #expect(WaitDuration(parsing: input) == nil)
    }
}
