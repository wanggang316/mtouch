import Foundation
import Testing
@testable import MTouchKit

// MARK: - Shared fixtures

/// A fresh, unique temp directory removed at the end of the closure. The record
/// tests write ONLY here — never a real run bundle, never the screen.
func withRecordTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-record-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        // Restore write permission first: a test may have made a subtree
        // read-only to exercise a refusal, and the tree must still be removable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(name).path
            )
        }
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

// MARK: - Fixtures

private func control(
    pid: pid_t = 4242,
    output: String = "/runs/demo/video/capture.mp4",
    startedAt: Double = 1_700_000_000.5,
    display: UInt32 = 1,
    executable: String = "/usr/local/bin/mtouch"
) -> RecordControl {
    RecordControl(pid: pid, output: output, startedAt: startedAt, display: display, executable: executable)
}

/// A process probe that answers from a table, so every branch of the state
/// machine is reachable without a real process.
private func probe(_ answers: [pid_t: RecordProcessIdentity]) -> (pid_t) -> RecordProcessIdentity {
    { answers[$0] ?? .gone }
}

private let controlPath = "/runs/demo/video/record.json"

// MARK: - The file itself

@Suite struct RecordControlFileTests {
    @Test func everyFactRoundTripsThroughTheJSON() throws {
        let original = control()
        let parsed = try #require(RecordControl.parse(Data(original.jsonText().utf8)))
        #expect(parsed == original)
    }

    @Test func theRenderingIsCompactSortedAndByteStable() {
        let text = control().jsonText()
        #expect(text == "{\"display\":1,\"executable\":\"/usr/local/bin/mtouch\","
            + "\"output\":\"/runs/demo/video/capture.mp4\",\"pid\":4242,"
            + "\"schemaVersion\":1,\"startedAt\":1700000000.5}\n")
        #expect(control().jsonText() == text)
    }

    /// While a recording runs there is no `finishedAt` at all — absence is the
    /// statement "this recording has not finalized", so it must not be written
    /// as a zero or a null that could be mistaken for a time.
    @Test func aRunningRecordingCarriesNoFinishTimeAtAll() throws {
        let running = control()
        #expect(!running.jsonText().contains("finishedAt"))
        #expect(!running.finishedCleanly)
        let parsed = try #require(RecordControl.parse(Data(running.jsonText().utf8)))
        #expect(parsed.finishedAt == nil)
    }

    /// The countersignature the recorder writes on its way out: the ONE fact
    /// that separates a deliberate finish from a killed recorder.
    @Test func aCountersignedRecordingRoundTripsItsFinishTime() throws {
        var finished = control()
        finished.finishedAt = 1_700_000_100.25
        let text = finished.jsonText()
        #expect(text.contains("\"finishedAt\":1700000100.25"))
        let parsed = try #require(RecordControl.parse(Data(text.utf8)))
        #expect(parsed == finished)
        #expect(parsed.finishedCleanly)
    }

    /// A control file that predates the countersignature — or one a killed
    /// recorder never got to update — reads as unfinished, never as finished.
    @Test func aControlFileWithoutTheFieldReadsAsUnfinished() throws {
        let raw = "{\"display\":1,\"executable\":\"/m\",\"output\":\"/x.mp4\","
            + "\"pid\":10,\"schemaVersion\":1,\"startedAt\":5}"
        let parsed = try #require(RecordControl.parse(Data(raw.utf8)))
        #expect(!parsed.finishedCleanly)
    }

    @Test func aPathWithQuotesOrUnicodeSurvivesTheRoundTrip() throws {
        let original = control(output: "/runs/a \"b\"/vidéo/капture.mp4")
        let parsed = try #require(RecordControl.parse(Data(original.jsonText().utf8)))
        #expect(parsed.output == original.output)
    }

    /// A file written by a future mtouch must read as damaged, not be
    /// mis-decoded as a live recording — the same version gate `SessionStore`
    /// applies to sessions.
    @Test func anUnknownSchemaVersionParsesAsNothing() {
        var future = control()
        future.schemaVersion = RecordControl.currentSchemaVersion + 1
        #expect(RecordControl.parse(Data(future.jsonText().utf8)) == nil)
    }

    @Test(arguments: [
        "",
        "not json at all",
        "{}",
        "{\"schemaVersion\":1,\"output\":\"/x.mp4\"}",
        "{\"schemaVersion\":1,\"pid\":10}",
        "{\"schemaVersion\":1,\"pid\":0,\"output\":\"/x.mp4\"}",
        "{\"schemaVersion\":1,\"pid\":-4,\"output\":\"/x.mp4\"}",
        "{\"schemaVersion\":1,\"pid\":10,\"output\":\"\"}",
    ])
    func unusableBytesParseAsNothing(_ raw: String) {
        #expect(RecordControl.parse(Data(raw.utf8)) == nil)
    }

    /// A half-written file must not be readable as a control file at all. The
    /// live writer renames into place so this can never be observed, and the
    /// parser refuses it even if it were.
    @Test func aTruncatedControlFileParsesAsNothing() {
        let full = control().jsonText()
        let truncated = String(full.prefix(full.count / 2))
        #expect(RecordControl.parse(Data(truncated.utf8)) == nil)
    }
}

// MARK: - The state machine

@Suite struct RecordControlStateTests {
    @Test func noControlFileMeansNothingIsRecordingHere() {
        let state = RecordControlStateMachine.state(path: controlPath, data: nil, identity: probe([:]))
        #expect(state == .absent)
        #expect(state.control == nil)
    }

    @Test func aPidStillRunningTheRecorderBinaryIsLive() {
        let live = control()
        let state = RecordControlStateMachine.state(
            path: controlPath,
            data: Data(live.jsonText().utf8),
            identity: probe([4242: .alive(executable: "/usr/local/bin/mtouch")])
        )
        #expect(state == .live(live))
        #expect(state.staleReason == nil)
    }

    @Test func aRecorderWhoseProcessIsGoneIsStaleNotLive() throws {
        let dead = control()
        let state = RecordControlStateMachine.state(
            path: controlPath,
            data: Data(dead.jsonText().utf8),
            identity: probe([:])
        )
        #expect(state.control == dead)
        let reason = try #require(state.staleReason)
        #expect(reason.contains("4242"))
        #expect(reason.contains("no longer running"))
    }

    /// Pids are recycled. A control file whose pid now belongs to some unrelated
    /// program must not read as a live recording — otherwise `record start`
    /// would refuse forever on a machine that merely got unlucky.
    @Test func aRecycledPidRunningSomethingElseIsStale() throws {
        let old = control()
        let state = RecordControlStateMachine.state(
            path: controlPath,
            data: Data(old.jsonText().utf8),
            identity: probe([4242: .alive(executable: "/bin/zsh")])
        )
        #expect(state.control == old)
        let reason = try #require(state.staleReason)
        #expect(reason.contains("/bin/zsh"))
    }

    @Test func aPidOwnedByAnotherUserIsStale() throws {
        let state = RecordControlStateMachine.state(
            path: controlPath,
            data: Data(control().jsonText().utf8),
            identity: probe([4242: .foreign])
        )
        let reason = try #require(state.staleReason)
        #expect(reason.contains("another user"))
    }

    /// If the executable path cannot be read, identity is UNDECIDABLE. Treating
    /// it as live is the safer error: refusing to start beats overwriting a
    /// capture that is still running.
    @Test func anUnreadableExecutablePathLeavesTheRecordingLive() {
        let live = control()
        let state = RecordControlStateMachine.state(
            path: controlPath,
            data: Data(live.jsonText().utf8),
            identity: probe([4242: .alive(executable: nil)])
        )
        #expect(state == .live(live))
    }

    @Test func aControlFileWithoutAnExecutableStillReadsAsLiveWhenItsPidIsUp() {
        let live = control(executable: "")
        let state = RecordControlStateMachine.state(
            path: controlPath,
            data: Data(live.jsonText().utf8),
            identity: probe([4242: .alive(executable: "/usr/local/bin/mtouch")])
        )
        #expect(state == .live(live))
    }

    @Test func unreadableBytesAreDamagedAndNameTheirPath() throws {
        let state = RecordControlStateMachine.state(
            path: controlPath,
            data: Data("{".utf8),
            identity: probe([:])
        )
        #expect(state.control == nil)
        let reason = try #require(state.staleReason)
        #expect(reason.contains("not a readable"))
        guard case let .damaged(path, _) = state else {
            Issue.record("expected a damaged state, got \(state)")
            return
        }
        #expect(path == controlPath)
    }
}

// MARK: - The live probe

@Suite struct LiveProcessProbeTests {
    /// The probe must agree with itself about THIS process, which is by
    /// definition alive and running the test binary.
    @Test func thisProcessIsAliveAndNamesItsOwnBinary() throws {
        let identity = LiveProcessProbe.identity(of: getpid())
        guard case let .alive(executable) = identity else {
            Issue.record("expected this process to be alive, got \(identity)")
            return
        }
        let path = try #require(executable)
        #expect(path.hasPrefix("/"))
        #expect(path == LiveProcessProbe.executablePath(of: getpid()))
    }

    @Test func aPidThatCannotExistIsGone() {
        // 0 and negatives address process GROUPS in kill(2); the probe must not
        // pass them through and accidentally signal the world.
        #expect(LiveProcessProbe.identity(of: 0) == .gone)
        #expect(LiveProcessProbe.identity(of: -1) == .gone)
    }

    @Test func aProcessThatHasExitedIsGone() throws {
        // A short-lived child, reaped, is the one pid we can be certain is dead.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(LiveProcessProbe.identity(of: process.processIdentifier) == .gone)
    }

    @Test func launchdIsAliveButNotOurs() {
        // pid 1 always exists and is root-owned, so it exercises the branch a
        // recycled cross-user pid would take.
        #expect(LiveProcessProbe.identity(of: 1) == .foreign)
    }
}

// MARK: - The store

@Suite struct RecordControlStoreTests {
    @Test func writingThenReadingReturnsTheSameFacts() throws {
        try withRecordTempDir { dir in
            let path = dir.appendingPathComponent("record.json").path
            #expect(RecordControlStore.read(path) == nil)

            let written = control()
            if case let .failure(failure) = RecordControlStore.write(written, to: path) {
                Issue.record("write failed: \(failure.reason)")
            }
            let data = try #require(RecordControlStore.read(path))
            #expect(RecordControl.parse(data) == written)

            RecordControlStore.clear(path)
            #expect(RecordControlStore.read(path) == nil)
        }
    }

    @Test func missingParentDirectoriesAreCreated() throws {
        try withRecordTempDir { dir in
            let path = dir.appendingPathComponent("video/nested/record.json").path
            if case let .failure(failure) = RecordControlStore.write(control(), to: path) {
                Issue.record("write failed: \(failure.reason)")
            }
            #expect(RecordControlStore.read(path) != nil)
        }
    }

    @Test func aDirectoryInTheWayIsAPreciseFailureNotAClobber() throws {
        try withRecordTempDir { dir in
            let path = dir.appendingPathComponent("record.json").path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            guard case let .failure(failure) = RecordControlStore.write(control(), to: path) else {
                Issue.record("expected writing over a directory to fail")
                return
            }
            #expect(failure.reason.contains("directory"))
        }
    }

    @Test func clearingSomethingThatIsNotThereIsHarmless() throws {
        try withRecordTempDir { dir in
            RecordControlStore.clear(dir.appendingPathComponent("nothing.json").path)
        }
    }
}
