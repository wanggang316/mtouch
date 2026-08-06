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
}

@Suite struct WaitDurationTests {
    @Test func parsesPlainSeconds() {
        #expect(WaitDuration(parsing: "5") == WaitDuration(seconds: 5))
        #expect(WaitDuration(parsing: "2.5") == WaitDuration(seconds: 2.5))
    }

    @Test(arguments: ["", "-1", "abc", "5s"])
    func rejectsMalformedInput(_ input: String) {
        #expect(WaitDuration(parsing: input) == nil)
    }
}
