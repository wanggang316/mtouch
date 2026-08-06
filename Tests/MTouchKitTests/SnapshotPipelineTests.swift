import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Stubs & fixtures (zero AX/TCC dependency)

private struct StubPermissionProvider: PermissionProvider {
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool = false
}

/// A minimal populated tree: a window with one actionable text area (⇒ ref e1).
private func sampleWalk(fallbackFired: Bool = false, fallbackHelped: Bool = false) -> WalkResult {
    let window = AXNode(
        role: kAXWindowRole, title: "Untitled",
        frame: CGRect(x: 0, y: 0, width: 400, height: 300),
        children: [AXNode(role: kAXTextAreaRole, value: "hello",
                          frame: CGRect(x: 0, y: 0, width: 380, height: 260), actionable: true)]
    )
    return WalkResult(nodes: [window], fallbackFired: fallbackFired,
                      fallbackHelped: fallbackHelped, truncated: false)
}

/// A fresh, unique temp directory removed at the end of the closure. Tests write
/// ONLY here — never the real `~/.mtouch/session.json`.
private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

/// Runs the pipeline with safe non-live defaults, overriding only what a test
/// cares about. Live AX/session collaborators are never touched.
private func runPipeline(
    bundleId: String = "com.apple.TextEdit",
    json: Bool = false,
    environment: [String: String],
    granted: Bool = true,
    resolvePID: @escaping (String) throws -> pid_t = { _ in 4242 },
    walk: @escaping (pid_t) -> WalkResult? = { _ in sampleWalk() },
    persist: @escaping (Snapshot, String, pid_t, String) throws -> Void = { _, _, _, _ in }
) -> SnapshotOutcome {
    SnapshotPipeline.run(
        bundleId: bundleId,
        json: json,
        environment: environment,
        permissions: StubPermissionProvider(accessibilityGranted: granted),
        resolvePID: resolvePID,
        walk: walk,
        persist: persist
    )
}

// MARK: - Preflight (VAL-ENV-006)

@Suite struct SnapshotPreflightTests {
    @Test func notGrantedFailsFastWithExitTwoAndNoStdout() {
        // The load-bearing assertion for VAL-ENV-006: without the grant the
        // outcome is a stderr-only failure at exit 2 — even under --json, stdout
        // is empty because `.failed` carries no rendered output.
        let outcome = runPipeline(json: true, environment: [:], granted: false)

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a failure outcome, got \(outcome)")
            return
        }
        #expect(code == .permissionMissing)
        #expect(stderr.contains("Accessibility permission is not granted"))
        #expect(stderr.contains("mtouch doctor"))
        // Never a hybrid: a failure is not `.rendered`, so nothing hits stdout.
        if case .rendered = outcome { Issue.record("--json error must not produce stdout") }
    }

    @Test func notGrantedShortCircuitsBeforeTouchingAX() {
        // Preflight is first: resolve/walk/persist must not run when ungranted.
        var touched = false
        _ = runPipeline(
            environment: [:],
            granted: false,
            resolvePID: { _ in touched = true; return 1 },
            walk: { _ in touched = true; return sampleWalk() },
            persist: { _, _, _, _ in touched = true }
        )
        #expect(touched == false)
    }
}

// MARK: - Resolution (VAL-SNAP-007)

@Suite struct SnapshotResolutionTests {
    @Test func unknownBundleIdFailsWithActionableExitOne() {
        let outcome = runPipeline(
            bundleId: "com.example.nope",
            environment: [:],
            resolvePID: { bundle in throw AppNotRunningError(bundleId: bundle) }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a failure outcome, got \(outcome)")
            return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("com.example.nope"))
        #expect(stderr.contains("mtouch apps"))   // actionable next step
    }
}

// MARK: - Bounded timeout (VAL-SNAP-008)

@Suite struct SnapshotTimeoutTests {
    @Test func hungWalkYieldsBoundedTimeoutDiagnosticAtExitOne() {
        // The bounded walk returning nil models a hung/SIGSTOPped target.
        let outcome = runPipeline(environment: [:], walk: { _ in nil })
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a failure outcome, got \(outcome)")
            return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("timed out"))
        #expect(stderr.contains("com.apple.TextEdit"))
    }
}

// MARK: - Persist failure (session unwritable)

@Suite struct SnapshotPersistFailureTests {
    @Test func unwritableSessionFailsAtExitOneNamingThePath() {
        let path = "/definitely/not/writable/session.json"
        let outcome = runPipeline(
            environment: [MTouchEnvironment.sessionKey: path],
            persist: { _, _, _, _ in throw SessionStoreError.notWritable(path: path, reason: "denied") }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a failure outcome, got \(outcome)")
            return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains(path))   // the diagnostic names the path
    }
}

// MARK: - Success (VAL-SNAP-003 / -005 / -014)

@Suite struct SnapshotSuccessTests {
    @Test func textOutputCarriesRefAnnotatedTreeAndPersistsTheSession() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            // Default persist = real SessionStore.save (via the pipeline default).
            let outcome = SnapshotPipeline.run(
                bundleId: "com.apple.TextEdit",
                json: false,
                environment: [MTouchEnvironment.sessionKey: path],
                permissions: StubPermissionProvider(accessibilityGranted: true),
                resolvePID: { _ in 4242 },
                walk: { _ in sampleWalk() }
            )

            guard case let .rendered(text) = outcome else {
                Issue.record("expected a rendered outcome, got \(outcome)")
                return
            }
            #expect(text.contains(kAXTextAreaRole))   // the text-area anchor
            #expect(text.contains("#e1"))              // ref-annotated

            // The session was persisted and resolves the ref.
            let session = try #require(SessionStore.load(from: path))
            #expect(session.app == "com.apple.TextEdit")
            #expect(session.pid == 4242)
            #expect(session.refs["e1"] != nil)
        }
    }

    @Test func jsonOutputHasStableTopLevelNodesKeyAndParses() throws {
        let outcome = runPipeline(json: true, environment: [:])
        guard case let .rendered(json) = outcome else {
            Issue.record("expected a rendered outcome, got \(outcome)")
            return
        }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let unwrapped = try #require(object)
        #expect(unwrapped["nodes"] != nil)
        #expect(unwrapped["note"] == nil)   // no fallback ⇒ no note
        #expect((unwrapped["nodes"] as? [Any])?.isEmpty == false)
    }
}

// MARK: - Fallback note (VAL-SNAP-010)

@Suite struct SnapshotFallbackNoteTests {
    @Test func textPrependsANoteLineWhenFallbackFired() {
        let outcome = runPipeline(environment: [:], walk: { _ in
            sampleWalk(fallbackFired: true, fallbackHelped: true)
        })
        guard case let .rendered(text) = outcome else {
            Issue.record("expected a rendered outcome, got \(outcome)")
            return
        }
        #expect(text.hasPrefix("note: "))
        #expect(text.contains("AXManualAccessibility"))
    }

    @Test func jsonCarriesANoteFieldWhenFallbackFiredWithoutHelp() throws {
        let outcome = runPipeline(json: true, environment: [:], walk: { _ in
            sampleWalk(fallbackFired: true, fallbackHelped: false)
        })
        guard case let .rendered(json) = outcome else {
            Issue.record("expected a rendered outcome, got \(outcome)")
            return
        }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let unwrapped = try #require(object)
        let note = try #require(unwrapped["note"] as? String)
        #expect(note.contains("incomplete"))
    }

    @Test func noNoteFieldWhenFallbackDidNotFire() {
        #expect(SnapshotPipeline.fallbackNote(sampleWalk()) == nil)
    }
}

// MARK: - Bounded walk primitive

@Suite struct BoundedWalkTests {
    @Test func returnsValueWhenWorkCompletesWithinDeadline() {
        #expect(BoundedWalk.run(deadline: 2) { 42 } == 42)
    }

    @Test func returnsNilWhenWorkExceedsDeadline() {
        // Short deadline, slow work ⇒ nil (the hung-target signal). The abandoned
        // work sleeps out on its own queue; the test does not wait for it.
        let result: Int? = BoundedWalk.run(deadline: 0.15) {
            Thread.sleep(forTimeInterval: 1.0)
            return 7
        }
        #expect(result == nil)
    }
}
