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
            enumerate: { _ in Issue.record("enumerate must not run without the grant"); return [] }
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
            enumerate: { _ in Issue.record("enumerate must not run when resolve fails"); return [] }
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
            enumerate: { _ in Issue.record("enumerate must not run when resolve fails"); return [] }
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
            enumerate: { _ in self.sampleWindows }
        )
        #expect(outcome == .listed(WindowInfo.jsonArray(sampleWindows)))
    }

    @Test func emptyEnumerateListsNoWindowsMessage() {
        let outcome = WindowsPipeline.run(
            bundleId: "com.apple.TextEdit", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 42 },
            enumerate: { _ in [] }
        )
        #expect(outcome == .listed("no windows for com.apple.TextEdit"))
    }

    @Test func nonEmptyEnumerateJoinsTextLines() {
        let outcome = WindowsPipeline.run(
            bundleId: "com.apple.TextEdit", json: false,
            permissions: StubPermissions(accessibility: true),
            resolvePID: { _ in 42 },
            enumerate: { _ in self.sampleWindows }
        )
        #expect(outcome == .listed(sampleWindows.map(\.textLine).joined(separator: "\n")))
    }
}
