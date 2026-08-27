import Foundation
import Testing
@testable import MTouchKit

// MARK: - Ambiguous bundle ids (refuse, never guess)

@Suite struct AmbiguousAppResolutionTests {
    /// The live regression: two processes share `com.google.Chrome` (a daily
    /// browser plus an automation profile). Binding to the first match silently
    /// drove the wrong one, so resolution must REFUSE and name both candidates.
    @Test func twoMatchesRefuseAndNameEveryCandidatePid() throws {
        let thrown = #expect(throws: AmbiguousAppError.self) {
            try AXWindowEnumerator.resolvePID(
                bundleId: "com.google.Chrome",
                in: [
                    (bundleId: "com.google.Chrome", pid: 90292),
                    (bundleId: "com.apple.Finder", pid: 100),
                    (bundleId: "com.google.Chrome", pid: 48594),
                ]
            )
        }
        let error = try #require(thrown)

        #expect(error.pids == [48594, 90292])   // ascending, deterministic
        #expect(error.exitCode == .runtimeFailure)
        let message = error.message
        #expect(message.contains("com.google.Chrome"))
        #expect(message.contains("matches 2 running processes"))
        #expect(message.contains("48594"))
        #expect(message.contains("90292"))
        #expect(message.contains("--pid"))
        #expect(message.contains("mtouch apps"))
    }

    @Test func exactlyOneMatchStillResolves() throws {
        let pid = try AXWindowEnumerator.resolvePID(
            bundleId: "com.apple.TextEdit",
            in: [(bundleId: "com.apple.Finder", pid: 100), (bundleId: "com.apple.TextEdit", pid: 200)]
        )
        #expect(pid == 200)
    }

    @Test func zeroMatchesKeepsAppNotRunning() {
        #expect(throws: AppNotRunningError(bundleId: "com.example.nope")) {
            try AXWindowEnumerator.resolvePID(
                bundleId: "com.example.nope",
                in: [(bundleId: "com.apple.Finder", pid: 100)]
            )
        }
    }
}

// MARK: - Explicit --pid override

@Suite struct PIDOverrideTests {
    @Test func matchingIdentityResolvesToThePid() throws {
        let pid = try AppTarget.validate(
            pid: 48594, bundleId: "com.google.Chrome",
            identity: ProcessIdentity(bundleId: "com.google.Chrome")
        )
        #expect(pid == 48594)
    }

    @Test func bundleIdComparisonIsCaseInsensitive() throws {
        let pid = try AppTarget.validate(
            pid: 7, bundleId: "COM.GOOGLE.CHROME",
            identity: ProcessIdentity(bundleId: "com.google.Chrome")
        )
        #expect(pid == 7)
    }

    /// A pid whose process is gone is a runtime failure (exit 1), naming the pid.
    @Test func unknownPidFailsAtExitOneNamingThePid() throws {
        let thrown = #expect(throws: PidNotRunningError.self) {
            try AppTarget.validate(pid: 4242, bundleId: "com.google.Chrome", identity: nil)
        }
        let error = try #require(thrown)
        #expect(error.exitCode == .runtimeFailure)
        #expect(error.message.contains("4242"))
        #expect(error.message.contains("mtouch apps"))
    }

    /// A running pid that belongs to a DIFFERENT app means the invocation
    /// contradicts itself: a usage error (exit 64) naming both values.
    @Test func bundleIdMismatchFailsAtExitSixtyFourNamingBothValues() throws {
        let thrown = #expect(throws: PidBundleMismatchError.self) {
            try AppTarget.validate(
                pid: 90292, bundleId: "com.google.Chrome",
                identity: ProcessIdentity(bundleId: "com.apple.Safari")
            )
        }
        let error = try #require(thrown)
        #expect(error.exitCode == .usageError)
        #expect(error.message.contains("90292"))
        #expect(error.message.contains("com.apple.Safari"))    // what the pid actually is
        #expect(error.message.contains("com.google.Chrome"))   // what --app asked for
    }

    /// A running process without a bundle id can never satisfy `--app`.
    @Test func processWithoutBundleIdIsAMismatch() throws {
        let thrown = #expect(throws: PidBundleMismatchError.self) {
            try AppTarget.validate(
                pid: 55, bundleId: "com.google.Chrome",
                identity: ProcessIdentity(bundleId: nil)
            )
        }
        let error = try #require(thrown)
        #expect(error.exitCode == .usageError)
        #expect(error.message.contains("no bundle identifier"))
        #expect(error.message.contains("com.google.Chrome"))
    }

    /// The seam the pipelines take: an override short-circuits bundle-id
    /// resolution entirely, so an ambiguous bundle id is never consulted.
    @Test func resolverWithOverrideNeverConsultsBundleIdResolution() {
        let resolve = AppTarget.resolver(pid: 2_147_483_647)   // no such process
        #expect(throws: PidNotRunningError(pid: 2_147_483_647)) {
            _ = try resolve("com.google.Chrome")
        }
    }
}

// MARK: - Diagnostic-error taxonomy

@Suite struct DiagnosticErrorExitCodeTests {
    /// Every resolution failure travels the pipelines' single `resolvePID` seam, so
    /// each must carry its OWN exit code rather than being flattened to one.
    @Test func resolutionFailuresCarryDistinctExitCodes() {
        let errors: [any MTouchDiagnosticError] = [
            AppNotRunningError(bundleId: "com.example.nope"),
            AmbiguousAppError(bundleId: "com.google.Chrome", pids: [1, 2]),
            PidNotRunningError(pid: 3),
            PidBundleMismatchError(pid: 4, requested: "a", actual: "b"),
        ]
        #expect(errors.map(\.exitCode) == [.runtimeFailure, .runtimeFailure, .runtimeFailure, .usageError])
        // Every message is an actionable `mtouch: ` stderr line.
        for error in errors {
            #expect(error.message.hasPrefix("mtouch: "))
        }
    }
}
