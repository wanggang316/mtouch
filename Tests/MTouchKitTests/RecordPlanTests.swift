import Foundation
import Testing
@testable import MTouchKit

// MARK: - --max-duration

@Suite struct RecordDurationParsingTests {
    @Test func theDefaultCeilingIsTenMinutes() {
        #expect(RecordDuration.default.seconds == 600)
        #expect(RecordDuration.default.text == "10m")
    }

    /// The same grammar `--timeout` uses, so the CLI parses durations one way.
    @Test(arguments: [
        ("600", 600.0),
        ("600s", 600.0),
        ("  90S ", 90.0),
        ("2.5", 2.5),
        ("1500ms", 1.5),
        ("14400", 14400.0),
        ("1", 1.0),
    ])
    func wellFormedDurationsWithinTheBoundsParse(_ raw: String, _ seconds: Double) throws {
        let duration = try #require(RecordDuration(parsing: raw))
        #expect(duration.seconds == seconds)
    }

    /// Every rejection is a usage error BEFORE a recorder is spawned. Zero is
    /// rejected here even though the shared grammar accepts it: `--timeout 0`
    /// means "check once", but a zero-length recording is never what was meant.
    @Test(arguments: [
        "", "   ", "abc", "5sx", "s", "ms", "-1", "-5s",
        "inf", "nan", "0", "0s", "999ms", "14401", "1e9",
    ])
    func malformedOrOutOfBoundsDurationsAreRejected(_ raw: String) {
        #expect(RecordDuration(parsing: raw) == nil)
    }

    @Test func theUsageMessageNamesTheOffenderAndBothBounds() {
        let message = RecordDuration.usageMessage("5sx")
        #expect(message.contains("'5sx'"))
        #expect(message.contains("1s"))
        #expect(message.contains("4h"))
    }
}

@Suite struct RecordDurationArithmeticTests {
    @Test func aDeadlineIsTheStartPlusTheCeiling() {
        let duration = RecordDuration(seconds: 600)
        #expect(duration.deadline(startingAt: 1000) == 1600)
        #expect(duration.deadline(startingAt: 0) == 600)
    }

    /// The boundary is inclusive: at exactly the deadline the recorder
    /// finalizes, rather than running one more poll interval.
    @Test func expiryIsInclusiveAtTheDeadline() {
        let duration = RecordDuration(seconds: 60)
        #expect(!duration.isExpired(startedAt: 100, now: 159.999))
        #expect(duration.isExpired(startedAt: 100, now: 160))
        #expect(duration.isExpired(startedAt: 100, now: 160.001))
    }

    /// A clock reading BEFORE the start — which the monotonic clock cannot do,
    /// but a caller could still pass — must not read as expired.
    @Test func aClockBeforeTheStartIsNotExpired() {
        #expect(!RecordDuration(seconds: 60).isExpired(startedAt: 100, now: 50))
    }

    /// Long past the deadline stays expired: the check must not wrap or
    /// overflow into "still running" for a recording nobody stopped.
    @Test func longPastTheDeadlineStaysExpired() {
        #expect(RecordDuration(seconds: 60).isExpired(startedAt: 100, now: 1_000_000))
    }

    @Test(arguments: [
        (1.0, "1s"), (45.0, "45s"), (60.0, "1m"), (150.0, "2m30s"),
        (600.0, "10m"), (3600.0, "1h"), (5400.0, "1h30m"), (14400.0, "4h"),
        (3661.0, "1h1m1s"),
    ])
    func theCompactTextFormReadsAsHoursMinutesSeconds(_ seconds: Double, _ text: String) {
        #expect(RecordDuration(seconds: seconds).text == text)
    }
}

// MARK: - Where a recording lives

@Suite struct RecordPlanPathTests {
    /// The whole point of the run-bundle integration: with a run directory the
    /// movie lands where `mtouch report` already looks.
    @Test func aRunDirectoryPutsEverythingInsideItsVideoFolder() {
        let paths = RecordPlan.paths(
            runDirectory: "/runs/demo", out: nil, workingDirectory: "/elsewhere",
            now: Date(timeIntervalSince1970: 1_700_000_000), unique: { "abcd1234" }
        )
        #expect(paths.directory == "/runs/demo/video")
        #expect(paths.control == "/runs/demo/video/record.json")
        #expect(paths.log == "/runs/demo/video/record.log")
        #expect(paths.movie.hasPrefix("/runs/demo/video/mtouch-recording-"))
        #expect(paths.movie.hasSuffix("-abcd1234.mp4"))
    }

    /// Without a run directory the state is still VISIBLE: an operator can see —
    /// and delete — the control file of a recording they started.
    @Test func withoutARunDirectoryEverythingLandsInTheWorkingDirectory() {
        let paths = RecordPlan.paths(
            runDirectory: nil, out: nil, workingDirectory: "/work/here",
            unique: { "abcd1234" }
        )
        #expect(paths.directory == "/work/here")
        #expect(paths.control == "/work/here/record.json")
        #expect(paths.log == "/work/here/record.log")
        #expect(paths.movie.hasPrefix("/work/here/mtouch-recording-"))
    }

    @Test func anExplicitOutIsHonouredVerbatimWhileTheControlStaysPut() {
        let paths = RecordPlan.paths(
            runDirectory: "/runs/demo", out: "/tmp/somewhere/else.mov", workingDirectory: "/work"
        )
        #expect(paths.movie == "/tmp/somewhere/else.mov")
        #expect(paths.control == "/runs/demo/video/record.json")
    }

    @Test func anEmptyOutFallsBackToTheDefaultName() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let paths = RecordPlan.paths(
            runDirectory: nil, out: "", workingDirectory: "/work", now: now, unique: { "abcd1234" }
        )
        #expect(paths.movie == "/work/mtouch-recording-\(ScreenCapturePath.timestamp(now))-abcd1234.mp4")
    }

    /// Two recordings started in the same second must not collide.
    @Test func theDefaultNameIsTimestampedAndCollisionProof() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var counter = 0
        let unique = { counter += 1; return "u\(counter)" }
        let first = RecordPlan.paths(runDirectory: nil, out: nil, workingDirectory: "/w", now: now, unique: unique)
        let second = RecordPlan.paths(runDirectory: nil, out: nil, workingDirectory: "/w", now: now, unique: unique)
        #expect(first.movie != second.movie)
        #expect(first.movie.contains(ScreenCapturePath.timestamp(now)))
    }

    @Test func aTrailingSlashInTheRunDirectoryNormalizes() {
        let paths = RecordPlan.paths(runDirectory: "/runs/demo/", out: nil, workingDirectory: "/w")
        #expect(paths.directory == "/runs/demo/video")
    }
}

@Suite struct RecordPlanRunDirectoryTests {
    @Test func theFlagWinsOverTheEnvironment() {
        let resolved = RecordPlan.runDirectory(
            flag: "/from/flag", environment: [MTouchEnvironment.runDirKey: "/from/env"]
        )
        #expect(resolved == "/from/flag")
    }

    @Test func theEnvironmentIsUsedWhenTheFlagIsAbsent() {
        #expect(RecordPlan.runDirectory(flag: nil, environment: [MTouchEnvironment.runDirKey: "/from/env"])
            == "/from/env")
    }

    /// Empty counts as unset on BOTH sides, so `MTOUCH_RUN_DIR=` behaves as no
    /// run directory rather than as the root of the filesystem.
    @Test func emptyValuesCountAsUnset() {
        #expect(RecordPlan.runDirectory(flag: "", environment: [:]) == nil)
        #expect(RecordPlan.runDirectory(flag: nil, environment: [MTouchEnvironment.runDirKey: ""]) == nil)
        #expect(RecordPlan.runDirectory(flag: nil, environment: [:]) == nil)
        #expect(RecordPlan.runDirectory(flag: "", environment: [MTouchEnvironment.runDirKey: "/from/env"])
            == "/from/env")
    }
}

// MARK: - The spawn seam

@Suite struct RecordSpawnTests {
    /// Proves the spawn itself: a real detached process runs, its stdout AND
    /// stderr land in the log, and its exit status is observed through the
    /// handshake — all without a display, a grant, or a capture.
    @Test func aSpawnedProcessRunsRedirectsBothStreamsAndItsExitIsObserved() throws {
        try withRecordTempDir { dir in
            let log = dir.appendingPathComponent("record.log").path
            let host = LiveRecordHost(executable: "/bin/sh")
            let result = host.spawnDetached(
                arguments: ["/bin/sh", "-c", "echo to-stdout; echo to-stderr 1>&2; exit 7"],
                log: log
            )
            guard case let .success(pid) = result else {
                Issue.record("spawn failed: \(result)")
                return
            }
            #expect(pid > 0)

            // No control file will ever appear, so the handshake resolves via the
            // child's exit — the path that reports a recorder's own refusal.
            let handshake = host.awaitHandshake(
                pid: pid, controlPath: dir.appendingPathComponent("never.json").path
            )
            #expect(handshake == .exited(status: 7))

            let tail = try #require(host.logTail(log))
            #expect(tail.contains("to-stdout"))
            #expect(tail.contains("to-stderr"))
        }
    }

    @Test func spawningSomethingThatIsNotThereIsAPreciseFailure() throws {
        try withRecordTempDir { dir in
            let missing = dir.appendingPathComponent("no-such-binary").path
            let host = LiveRecordHost(executable: missing)
            let log = dir.appendingPathComponent("l").path
            guard case let .failure(failure) = host.spawnDetached(arguments: [missing], log: log) else {
                Issue.record("expected spawning a missing binary to fail")
                return
            }
            #expect(failure.reason.contains(missing))
        }
    }

    /// The shell convention, so the number in the diagnostic is one an operator
    /// recognises: a clean exit reports its code, a killed process reports
    /// 128 + signal.
    @Test func exitStatusDistinguishesACleanExitFromASignalDeath() {
        #expect(LiveRecordHost.exitStatus(0) == 0)
        #expect(LiveRecordHost.exitStatus(1 << 8) == 1)
        #expect(LiveRecordHost.exitStatus(2 << 8) == 2)
        #expect(LiveRecordHost.exitStatus(SIGKILL) == 128 + SIGKILL)
        #expect(LiveRecordHost.exitStatus(SIGTERM) == 128 + SIGTERM)
    }

    /// Waiting on something that has already exited returns at once rather than
    /// burning the exit timeout, and pid 0 — which addresses a process GROUP in
    /// `kill(2)` — is refused rather than passed through.
    @Test func waitingOnAnAlreadyExitedProcessReturnsImmediately() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let host = LiveRecordHost(executable: "/bin/sh")
        let started = Date()
        #expect(host.awaitExit(pid: process.processIdentifier))
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(!host.terminate(pid: 0))
    }
}
