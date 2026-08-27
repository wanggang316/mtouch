import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

private let recorderBinary = "/usr/local/bin/mtouch"
private let movie = "/runs/demo/video/capture.mp4"

private let paths = RecordPaths(
    directory: "/runs/demo/video",
    control: "/runs/demo/video/record.json",
    log: "/runs/demo/video/record.log",
    movie: movie
)

private func control(
    pid: pid_t = 4242,
    output: String = movie,
    finishedAt: Double? = nil
) -> RecordControl {
    RecordControl(
        pid: pid, output: output, startedAt: 1_700_000_000,
        display: 1, executable: recorderBinary, finishedAt: finishedAt
    )
}

/// A recording the recorder countersigned on its way out.
private func finishedControl(pid: pid_t = 4242, output: String = movie) -> RecordControl {
    control(pid: pid, output: output, finishedAt: 1_700_000_100)
}

private let goodFacts = RecordMovieFacts(byteCount: 2_500_000, durationSeconds: 42.5, videoTrackCount: 1)

/// A `RecordHost` whose every answer is scripted. A class, not a struct, so a
/// test can inspect what the pipeline DID without any mutating call inside an
/// `#expect`.
private final class StubHost: RecordHost {
    var controlData: Data?
    var identities: [pid_t: RecordProcessIdentity] = [:]
    var directoryResult: Result<Void, RecordFailure> = .success(())
    var launchResult: Result<pid_t, RecordFailure> = .success(9001)
    /// Nil means "answer with a handshake naming whichever pid was launched".
    var handshakeResult: RecordHandshake?
    var verdict: RecordArtifactVerdict = .verified(goodFacts)
    var terminateResult = true
    var exitResult = true
    /// Models the recorder countersigning the control file before it exits. Set
    /// false to model one that was killed mid-recording.
    var countersignsOnExit = true
    var log: String?

    private(set) var launched: [RecordLaunch] = []
    private(set) var terminated: [pid_t] = []
    private(set) var cleared: [String] = []
    private(set) var verified: [String] = []
    private(set) var createdDirectories: [String] = []

    init(state: RecordControlState = .absent) {
        switch state {
        case .absent:
            controlData = nil
        case let .live(live):
            controlData = Data(live.jsonText().utf8)
            identities[live.pid] = .alive(executable: live.executable)
        case let .stale(dead, _):
            controlData = Data(dead.jsonText().utf8)
            identities[dead.pid] = .gone
        case .damaged:
            controlData = Data("{ not json".utf8)
        }
    }

    func readControl(_ path: String) -> Data? { controlData }
    func clearControl(_ path: String) { cleared.append(path); controlData = nil }
    func identity(of pid: pid_t) -> RecordProcessIdentity { identities[pid] ?? .gone }

    func createDirectory(_ path: String) -> Result<Void, RecordFailure> {
        createdDirectories.append(path)
        return directoryResult
    }

    func launch(_ launch: RecordLaunch) -> Result<pid_t, RecordFailure> {
        launched.append(launch)
        return launchResult
    }

    func awaitHandshake(pid: pid_t, controlPath: String) -> RecordHandshake {
        handshakeResult ?? .live(control(pid: pid))
    }

    func terminate(pid: pid_t) -> Bool {
        terminated.append(pid)
        return terminateResult
    }

    func awaitExit(pid: pid_t) -> Bool {
        if exitResult, countersignsOnExit, let data = controlData, var parsed = RecordControl.parse(data) {
            parsed.finishedAt = 1_700_000_100
            controlData = Data(parsed.jsonText().utf8)
        }
        return exitResult
    }

    func verify(movie: String) -> RecordArtifactVerdict {
        verified.append(movie)
        return verdict
    }

    func logTail(_ path: String) -> String? { log }
}

private func launch(maxDuration: RecordDuration = .default, display: UInt32? = nil) -> RecordLaunch {
    RecordLaunch(paths: paths, display: display, maxDuration: maxDuration)
}

private func stdout(_ outcome: RecordOutcome) -> String? {
    if case let .reported(text, _) = outcome { return text }
    return nil
}

private func notes(_ outcome: RecordOutcome) -> [String] {
    if case let .reported(_, notes) = outcome { return notes }
    return []
}

private func stderr(_ outcome: RecordOutcome) -> String? {
    if case let .failed(text, _) = outcome { return text }
    return nil
}

// MARK: - start

@Suite struct RecordStartTests {
    /// "start succeeded" must mean recording is HAPPENING. The stdout line comes
    /// from the control file the recorder published, not from the launch.
    @Test func startReportsTheRecordingTheHandshakeConfirmed() throws {
        let host = StubHost()
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        let line = try #require(stdout(outcome))
        #expect(line == "recording \(movie) (pid 9001, display 1, max 10m)")
        #expect(notes(outcome).isEmpty)
        #expect(host.createdDirectories == [paths.directory])
        #expect(host.launched.count == 1)
        #expect(host.terminated.isEmpty)
    }

    @Test func theCeilingIsCarriedIntoTheLaunchAndTheReport() throws {
        let host = StubHost()
        let outcome = RecordPipeline.start(launch: launch(maxDuration: RecordDuration(seconds: 90)), host: host)
        let line = try #require(stdout(outcome))
        #expect(line.hasSuffix("max 1m30s)"))
        #expect(host.launched.first?.maxDuration.seconds == 90)
    }

    /// One recording per directory. A second start must refuse and NAME the live
    /// one, not quietly clobber a capture in progress.
    @Test func aSecondStartIsRefusedAndNamesTheLiveRecording() throws {
        let host = StubHost(state: .live(control()))
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("already in progress"))
        #expect(message.contains(movie))
        #expect(message.contains("4242"))
        #expect(message.contains("record stop"))
        #expect(outcome == .failed(stderr: message, code: .runtimeFailure))
        // Nothing was launched and nothing was destroyed.
        #expect(host.launched.isEmpty)
        #expect(host.cleared.isEmpty)
    }

    /// A crashed run must not block this directory forever — but recovering
    /// silently would hide that an earlier recording died. The note states the
    /// earlier movie's fate before the new one begins.
    @Test func aStaleControlFileIsRecoveredAndTheEarlierMoviesFateIsStated() throws {
        let earlier = "/runs/demo/video/earlier.mp4"
        let host = StubHost(state: .stale(control(output: earlier), reason: ""))
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        #expect(stdout(outcome) != nil)
        let note = try #require(notes(outcome).first)
        #expect(note.contains("stale"))
        #expect(note.contains(earlier))
        #expect(note.contains("never finalized"))
        #expect(note.contains("holds 2500000 bytes"))
        #expect(host.verified == [earlier])
        #expect(host.cleared == [paths.control])
        #expect(host.launched.count == 1)
    }

    @Test func recoveringAFinishedRecordingSaysItHadFinished() throws {
        let host = StubHost(state: .stale(finishedControl(), reason: ""))
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        let note = try #require(notes(outcome).first)
        #expect(note.contains("had finished"))
        #expect(!note.contains("never finalized"))
    }

    @Test func aStaleControlFileWhoseMovieDiedSaysSoAndStillStarts() throws {
        let host = StubHost(state: .stale(control(), reason: ""))
        host.verdict = .unreadable(path: movie, reason: "no moov atom")
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        #expect(stdout(outcome) != nil)
        let note = try #require(notes(outcome).first)
        #expect(note.contains("did NOT survive"))
        #expect(note.contains("no moov atom"))
    }

    @Test func aDamagedControlFileIsReplacedWithANote() throws {
        let host = StubHost(state: .damaged(path: paths.control, reason: ""))
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        #expect(stdout(outcome) != nil)
        let note = try #require(notes(outcome).first)
        #expect(note.contains("damaged"))
        #expect(note.contains(paths.control))
        // Nothing to verify: a damaged control file names no movie.
        #expect(host.verified.isEmpty)
        #expect(host.cleared == [paths.control])
    }

    /// A recorder that refuses to run — unsupported macOS, missing grant,
    /// unwritable path — must surface ITS reason, not a generic one.
    @Test func aRecorderThatExitsBeforeConfirmingIsAFailureQuotingItsLog() throws {
        let host = StubHost()
        host.handshakeResult = .exited(status: 2)
        host.log = "mtouch: Screen Recording permission is not granted."
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("exited with status 2"))
        #expect(message.contains("Screen Recording permission is not granted"))
    }

    @Test func aRecorderWithNoLogStillFailsCleanly() throws {
        let host = StubHost()
        host.handshakeResult = .exited(status: 1)
        host.log = "   \n  "
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("exited with status 1"))
        #expect(!message.contains("recorder log"))
    }

    /// A recorder that is alive but never confirmed is a process capturing the
    /// screen that nothing knows about. It is stopped, not left running.
    @Test func aRecorderThatNeverConfirmsIsStoppedAndReported() throws {
        let host = StubHost()
        host.handshakeResult = .timedOut(seconds: 45)
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("did not confirm"))
        #expect(message.contains("45s"))
        #expect(host.terminated == [9001])
        #expect(host.cleared == [paths.control])
    }

    @Test func aRecorderOutracedByAnotherIsStoppedAndReported() throws {
        let host = StubHost()
        host.handshakeResult = .mismatched(control(pid: 7))
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("another recorder (pid 7)"))
        #expect(host.terminated == [9001])
    }

    @Test func anUnpreparableDirectoryFailsBeforeAnythingIsSpawned() throws {
        let host = StubHost()
        host.directoryResult = .failure(RecordFailure("Read-only file system"))
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains(paths.directory))
        #expect(message.contains("Read-only file system"))
        #expect(host.launched.isEmpty)
    }

    @Test func aSpawnThatFailsIsReportedNotRetried() throws {
        let host = StubHost()
        host.launchResult = .failure(RecordFailure("/usr/local/bin/mtouch: No such file or directory"))
        let outcome = RecordPipeline.start(launch: launch(), host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("could not start the recorder"))
        #expect(message.contains("No such file or directory"))
    }

    @Test func everyStartFailureExitsOne() {
        for handshake in [RecordHandshake.exited(status: 3), .timedOut(seconds: 45), .mismatched(control(pid: 7))] {
            let host = StubHost()
            host.handshakeResult = handshake
            let outcome = RecordPipeline.start(launch: launch(), host: host)
            guard case let .failed(_, code) = outcome else {
                Issue.record("expected \(handshake) to fail")
                continue
            }
            #expect(code == .runtimeFailure)
        }
    }
}

// MARK: - stop

@Suite struct RecordStopTests {
    @Test func stoppingSignalsWaitsVerifiesAndReportsTheMovie() throws {
        let host = StubHost(state: .live(control()))
        let outcome = RecordPipeline.stop(paths: paths, host: host)
        let line = try #require(stdout(outcome))
        #expect(line == "stopped recording \(movie) (2500000 bytes, 42.5 s, 1 video track)")
        #expect(host.terminated == [4242])
        #expect(host.verified == [movie])
        #expect(host.cleared == [paths.control])
        #expect(notes(outcome).isEmpty)
    }

    /// The movie that is verified is the one the RECORDER named, not the one a
    /// fresh `start` would have chosen — the control file is the only path that
    /// can be trusted after the fact.
    @Test func theVerifiedMovieIsTheOneTheControlFileNames() throws {
        let host = StubHost(state: .live(control(output: "/somewhere/else.mp4")))
        _ = RecordPipeline.stop(paths: paths, host: host)
        #expect(host.verified == ["/somewhere/else.mp4"])
    }

    @Test func stoppingWithNothingRunningFailsSayingSo() throws {
        let host = StubHost()
        let outcome = RecordPipeline.stop(paths: paths, host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("no recording is in progress"))
        #expect(message.contains(paths.directory))
        #expect(outcome == .failed(stderr: message, code: .runtimeFailure))
        #expect(host.terminated.isEmpty)
        #expect(host.verified.isEmpty)
    }

    /// THE case this whole layer exists for. A SIGKILLed recorder leaves a movie
    /// that is SHORT BUT PERFECTLY PLAYABLE — ScreenCaptureKit flushes fragments
    /// as it goes — so artifact verification alone passes it. Only the missing
    /// countersignature reveals that the recording never finished, and that must
    /// be an exit-1 failure, never a success.
    @Test func aKilledRecorderIsRefusedEvenThoughItsMovieIsPlayable() throws {
        let host = StubHost(state: .stale(control(), reason: ""))
        // A movie that passes every artifact check: exactly the trap.
        host.verdict = .verified(RecordMovieFacts(byteCount: 106_122, durationSeconds: 3.3, videoTrackCount: 1))
        let outcome = RecordPipeline.stop(paths: paths, host: host)
        let message = try #require(stderr(outcome))
        #expect(stdout(outcome) == nil)
        #expect(message.contains(movie))
        #expect(message.contains("never finished"))
        #expect(message.contains("NOT a complete recording"))
        #expect(message.contains("playable but partial (106122 bytes, 3.3 s, 1 video track)"))
        #expect(outcome == .failed(stderr: message, code: .runtimeFailure))
        // It was never signalled — it was already gone — but it WAS verified.
        #expect(host.terminated.isEmpty)
        #expect(host.verified == [movie])
        // Cleared even on failure: the recording is over either way, and the next
        // start must not inherit a corpse.
        #expect(host.cleared == [paths.control])
    }

    @Test func aKilledRecorderWhoseMovieIsAlsoUnreadableReportsBothFacts() throws {
        let host = StubHost(state: .stale(control(), reason: ""))
        host.verdict = .unreadable(path: movie, reason: "The operation could not be completed")
        let message = try #require(stderr(RecordPipeline.stop(paths: paths, host: host)))
        #expect(message.contains("never finished"))
        #expect(message.contains("not a readable movie"))
    }

    /// "Killed" and "the capture failed" leave IDENTICAL traces on disk — an
    /// unfinished control file and a partial movie. Only the recorder's log tells
    /// them apart, so an unfinished stop quotes it.
    @Test func anUnfinishedRecordingQuotesTheRecordersLog() throws {
        let host = StubHost(state: .stale(control(), reason: ""))
        host.log = "mtouch: recording failed: the stream connection was interrupted"
        let message = try #require(stderr(RecordPipeline.stop(paths: paths, host: host)))
        #expect(message.contains("recorder log:"))
        #expect(message.contains("the stream connection was interrupted"))
    }

    /// A recording that STOPPED cleanly says nothing about the log: there is no
    /// failure to explain.
    @Test func aCleanStopNeverQuotesTheLog() throws {
        let host = StubHost(state: .live(control()))
        host.log = "mtouch: recording failed: something old and irrelevant"
        let outcome = RecordPipeline.stop(paths: paths, host: host)
        let line = try #require(stdout(outcome))
        #expect(!line.contains("recorder log"))
    }

    /// A recorder that finalized on its own `--max-duration` countersigned the
    /// control file before exiting, so the same stale-process state stops
    /// cleanly. The countersignature is the whole difference.
    @Test func aRecorderThatFinishedOnItsOwnStillStopsCleanly() throws {
        let host = StubHost(state: .stale(finishedControl(), reason: ""))
        let outcome = RecordPipeline.stop(paths: paths, host: host)
        #expect(stdout(outcome) == "stopped recording \(movie) (2500000 bytes, 42.5 s, 1 video track)")
        let note = try #require(notes(outcome).first)
        #expect(note.contains("had already exited"))
    }

    /// A recorder that took the signal and exited but never countersigned failed
    /// somewhere in finalization. Its movie is refused too.
    @Test func aRecorderThatExitedWithoutCountersigningIsRefused() throws {
        let host = StubHost(state: .live(control()))
        host.countersignsOnExit = false
        let message = try #require(stderr(RecordPipeline.stop(paths: paths, host: host)))
        #expect(message.contains("never finished"))
        #expect(host.terminated == [4242])
    }

    @Test(arguments: [
        RecordArtifactVerdict.missing(path: movie),
        .empty(path: movie),
        .noVideoTrack(path: movie),
        .zeroDuration(path: movie),
    ])
    func anyUnusableMovieIsAFailureNamingTheReason(_ verdict: RecordArtifactVerdict) throws {
        let host = StubHost(state: .live(control()))
        host.verdict = verdict
        let outcome = RecordPipeline.stop(paths: paths, host: host)
        #expect(outcome == .failed(stderr: verdict.diagnostic, code: .runtimeFailure))
    }

    /// The recorder is still running, so its control file still describes
    /// something real and must survive.
    @Test func aRecorderThatWillNotExitLeavesItsControlFileAlone() throws {
        let host = StubHost(state: .live(control()))
        host.exitResult = false
        let outcome = RecordPipeline.stop(paths: paths, host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("did not exit"))
        #expect(message.contains("has not been finalized"))
        #expect(host.cleared.isEmpty)
        #expect(host.verified.isEmpty)
    }

    @Test func aRecorderThatCannotBeSignalledIsReported() throws {
        let host = StubHost(state: .live(control()))
        host.terminateResult = false
        let outcome = RecordPipeline.stop(paths: paths, host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("could not signal"))
        #expect(message.contains("still running"))
        #expect(host.cleared.isEmpty)
    }

    @Test func aDamagedControlFileCannotBeStoppedAndSaysHowToRecover() throws {
        let host = StubHost(state: .damaged(path: paths.control, reason: ""))
        let outcome = RecordPipeline.stop(paths: paths, host: host)
        let message = try #require(stderr(outcome))
        #expect(message.contains("unreadable"))
        #expect(message.contains("record start"))
        #expect(host.terminated.isEmpty)
    }
}

// MARK: - status

@Suite struct RecordStatusTests {
    @Test func statusReportsTheLiveRecordingWithItsPidDisplayAndStart() throws {
        let host = StubHost(state: .live(control()))
        let line = try #require(stdout(RecordPipeline.status(paths: paths, host: host)))
        #expect(line.contains("recording \(movie)"))
        #expect(line.contains("pid 4242"))
        #expect(line.contains("display 1"))
        #expect(line.contains("2023-11-14"))
    }

    @Test func statusReportsWhenNothingIsRecording() throws {
        let line = try #require(stdout(RecordPipeline.status(paths: paths, host: StubHost())))
        #expect(line == "not recording (\(paths.directory))")
    }

    /// A dead recorder's leftovers must never read as a live recording, and
    /// status must say WHICH kind of leftover it is.
    @Test func statusReportsAStaleControlFileAsNotRecording() throws {
        let host = StubHost(state: .stale(control(), reason: ""))
        let line = try #require(stdout(RecordPipeline.status(paths: paths, host: host)))
        #expect(line.hasPrefix("not recording"))
        #expect(line.contains("never finalized"))
        #expect(line.contains(movie))
    }

    @Test func statusDistinguishesAFinishedRecordingFromOneThatDied() throws {
        let host = StubHost(state: .stale(finishedControl(), reason: ""))
        let line = try #require(stdout(RecordPipeline.status(paths: paths, host: host)))
        #expect(line.contains("a finished recording"))
        #expect(!line.contains("never finalized"))
    }

    @Test func statusReportsADamagedControlFileAsNotRecording() throws {
        let host = StubHost(state: .damaged(path: paths.control, reason: ""))
        let line = try #require(stdout(RecordPipeline.status(paths: paths, host: host)))
        #expect(line.hasPrefix("not recording"))
        #expect(line.contains("unreadable"))
    }

    /// Status is a QUESTION, not an assertion: every state is exit 0, and none
    /// of them touch the recording.
    @Test func statusNeverFailsAndNeverMutates() {
        let states: [RecordControlState] = [
            .absent, .live(control()), .stale(control(), reason: ""), .damaged(path: paths.control, reason: ""),
        ]
        for state in states {
            let host = StubHost(state: state)
            #expect(stdout(RecordPipeline.status(paths: paths, host: host)) != nil)
            #expect(host.terminated.isEmpty)
            #expect(host.cleared.isEmpty)
            #expect(host.launched.isEmpty)
        }
    }
}
