import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

private struct StubPermissions: PermissionProvider {
    var accessibility: Bool
    var accessibilityGranted: Bool { accessibility }
    var screenRecordingGranted: Bool { false }
}

@Suite struct WindowsPipelineTests {
    private let sampleWindows = [
        WindowInfo(id: 1, title: "Alpha", frame: CGRect(x: 0, y: 0, width: 100, height: 50)),
        WindowInfo(id: 2, title: "Beta", frame: CGRect(x: 10, y: 20, width: 200, height: 80)),
    ]

    @Test func missingGrantFailsWithPermissionMissing() {
        let outcome = WindowsPipeline.run(
            bundleId: "com.apple.TextEdit", json: false,
            permissions: StubPermissions(accessibility: false),
            resolvePID: { _ in Issue.record("resolvePID must not run without the grant"); return 1 },
            enumerate: { _ in Issue.record("enumerate must not run without the grant"); return .success([]) }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure"); return
        }
        #expect(code == .permissionMissing)
        #expect(stderr == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func appNotRunningFailsWithRuntimeFailureAndAppMessage() {
        let outcome = WindowsPipeline.run(
            bundleId: "com.example.nope", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in throw AppNotRunningError(bundleId: "com.example.nope") },
            enumerate: { _ in Issue.record("enumerate must not run when resolve fails"); return .success([]) }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == AppNotRunningError(bundleId: "com.example.nope").message)
    }

    @Test func otherResolveErrorFailsWithRuntimeFailure() {
        struct Boom: Error {}
        let outcome = WindowsPipeline.run(
            bundleId: "com.apple.TextEdit", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in throw Boom() },
            enumerate: { _ in Issue.record("enumerate must not run when resolve fails"); return .success([]) }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("could not resolve application 'com.apple.TextEdit'"))
    }

    @Test func jsonEmitsWindowInfoJSONArray() {
        let outcome = WindowsPipeline.run(
            bundleId: "com.apple.TextEdit", json: true,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 42 },
            enumerate: { _ in .success(self.sampleWindows) }
        )
        #expect(outcome == .listed(WindowInfo.jsonArray(sampleWindows)))
    }

    @Test func emptyEnumerateListsNoWindowsMessage() {
        let outcome = WindowsPipeline.run(
            bundleId: "com.apple.TextEdit", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 42 },
            enumerate: { _ in .success([]) }
        )
        #expect(outcome == .listed("no windows for com.apple.TextEdit"))
    }

    @Test func nonEmptyEnumerateJoinsTextLines() {
        let outcome = WindowsPipeline.run(
            bundleId: "com.apple.TextEdit", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 42 },
            enumerate: { _ in .success(self.sampleWindows) }
        )
        #expect(outcome == .listed(sampleWindows.map(\.textLine).joined(separator: "\n")))
    }
}

// MARK: - An AX error is never a listing (the Chrome regression)

@Suite struct WindowsAXFailureTests {
    private func run(_ failure: AXReadFailure, json: Bool = false) -> WindowsOutcome {
        WindowsPipeline.run(
            bundleId: "com.google.Chrome", json: json,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in failure.pid },
            enumerate: { _ in .failure(failure) }
        )
    }

    /// The regression: a refused AX read used to render as "no windows" at exit 0
    /// for an app that visibly HAD one. It must now fail loudly, naming the pid,
    /// the app, and the cause — including the recovery an agent can act on.
    @Test func refusedReadFailsAtExitOneNamingPidAppAndCause() {
        let outcome = run(AXReadFailure(pid: 48594, error: .apiDisabled))

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("com.google.Chrome"))
        #expect(stderr.contains("48594"))
        #expect(stderr.contains("accessibility API is disabled"))
        #expect(stderr.contains("AXError -25211"))
        #expect(stderr.contains("--pid"))
        #expect(stderr.contains("mtouch apps"))
        // Never a listing: a failure must not masquerade as zero windows.
        #expect(!stderr.contains("no windows"))
    }

    /// `--json` must not turn a failure into `[]` either: the failure carries no
    /// stdout at all, so a JSON consumer sees an error, not an empty collection.
    @Test func refusedReadUnderJSONStillFailsAndEmitsNoArray() {
        let outcome = run(AXReadFailure(pid: 48594, error: .apiDisabled), json: true)

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr != "[]")
        if case .listed = outcome { Issue.record("--json AX failure must not produce stdout") }
    }

    /// Each realistic cause reads differently, so an agent can tell a disabled API
    /// from a hung process from a dead one; anything else degrades to the code.
    @Test func causesAreDistinctAndAlwaysCarryTheNumericCode() {
        let disabled = AXReadFailure(pid: 1, error: .apiDisabled).cause
        let hung = AXReadFailure(pid: 1, error: .cannotComplete).cause
        let dead = AXReadFailure(pid: 1, error: .invalidUIElement).cause
        let other = AXReadFailure(pid: 1, error: .attributeUnsupported).cause

        #expect(disabled.contains("accessibility API is disabled"))
        #expect(hung.contains("did not respond in time"))
        #expect(dead.contains("no longer a valid accessibility target"))
        #expect(other.contains("accessibility read failed"))
        #expect(Set([disabled, hung, dead, other]).count == 4)

        #expect(disabled.contains("(AXError \(AXError.apiDisabled.rawValue))"))
        #expect(hung.contains("(AXError \(AXError.cannotComplete.rawValue))"))
        #expect(dead.contains("(AXError \(AXError.invalidUIElement.rawValue))"))
        #expect(other.contains("(AXError \(AXError.attributeUnsupported.rawValue))"))
    }
}

// MARK: - Zero windows stays a success (VAL-SNAP-002)

@Suite struct WindowsZeroWindowContractTests {
    private func run(json: Bool) -> WindowsOutcome {
        WindowsPipeline.run(
            bundleId: "com.apple.TextEdit", json: json,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 42 },
            // The app ANSWERED, with no windows — the opposite of a refused read.
            enumerate: { _ in .success([]) }
        )
    }

    /// A SUCCESSFUL read of an empty window list keeps the pinned contract
    /// unchanged: an explicit note (never blank stdout) at exit 0.
    @Test func successfulEmptyReadStillReportsNoWindowsAtExitZero() {
        #expect(run(json: false) == .listed("no windows for com.apple.TextEdit"))
    }

    /// …and `--json` still emits a jq-parseable empty array, never null.
    @Test func successfulEmptyReadStillEmitsEmptyJSONArray() throws {
        let outcome = run(json: true)
        guard case let .listed(output) = outcome else {
            Issue.record("expected a listing, got \(outcome)"); return
        }
        #expect(output == "[]")
        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [Any]
        #expect(parsed?.isEmpty == true)
    }
}

// MARK: - Targeting failures keep their own exit codes

@Suite struct WindowsTargetingTests {
    private func run(resolvePID: @escaping (String) throws -> pid_t) -> WindowsOutcome {
        WindowsPipeline.run(
            bundleId: "com.google.Chrome", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: resolvePID,
            enumerate: { _ in Issue.record("enumerate must not run when resolve fails"); return .success([]) }
        )
    }

    @Test func ambiguousBundleIdFailsAtExitOneListingTheCandidates() {
        let error = AmbiguousAppError(bundleId: "com.google.Chrome", pids: [48594, 90292])
        let outcome = run(resolvePID: { _ in throw error })

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == error.message)
        #expect(stderr.contains("48594"))
        #expect(stderr.contains("90292"))
    }

    @Test func unknownPidFailsAtExitOne() {
        let outcome = run(resolvePID: { _ in throw PidNotRunningError(pid: 4242) })

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr == PidNotRunningError(pid: 4242).message)
    }

    /// A `--pid` contradicting `--app` is a USAGE error (64), not a runtime one:
    /// the invocation cannot be satisfied as written.
    @Test func pidBundleMismatchFailsAtExitSixtyFour() {
        let error = PidBundleMismatchError(pid: 90292, requested: "com.google.Chrome", actual: "com.apple.Safari")
        let outcome = run(resolvePID: { _ in throw error })

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(code == .usageError)
        #expect(stderr == error.message)
    }
}
