import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures & helpers

/// A fresh, unique temp directory removed at the end of the closure. Tests write
/// ONLY here — never the real home, never a shared run directory, and nothing in
/// this file ever opens a capture session, decodes a movie, or needs a display.
private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-step-frame-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

/// A capture that COUNTS how often it was asked to run. The central claim of this
/// feature — "while a recording is live we open no capture session" — is only
/// testable as an absence, so the seam has to be able to report zero.
private final class SpyCapture: RunCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func capturePNG() -> Result<Data, RunCaptureFailure> {
        lock.lock(); count += 1; lock.unlock()
        return .success(Data("stub-png-bytes".utf8))
    }
}

/// A recording probe with a fixed answer, so "a recording is live" needs no
/// recorder process.
private struct StubRecordingProbe: RunRecordingProbing {
    var facts: RunRecordingFacts?
    static let none = StubRecordingProbe(facts: nil)

    static func live(movie: String, startedAt: Double, pid: pid_t = 4242) -> StubRecordingProbe {
        StubRecordingProbe(facts: RunRecordingFacts(movie: movie, startedAt: startedAt, pid: pid))
    }

    func liveRecording(for run: RunBundle) -> RunRecordingFacts? { facts }
}

/// An extractor that never touches AVFoundation: it records what it was asked
/// for and hands back whatever the test wants — including DIFFERENT bytes on
/// every call, which is how "a second render does not extract again" is proved.
private final class StubExtractor: RunFrameExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Request] = []
    private let failure: String?

    struct Request: Hashable {
        let movie: String
        let offset: Double
    }

    init(failure: String? = nil) {
        self.failure = failure
    }

    var recorded: [Request] { lock.lock(); defer { lock.unlock() }; return requests }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    func extractPNG(movie: String, atOffset offset: Double) -> Result<Data, RunCaptureFailure> {
        lock.lock()
        requests.append(Request(movie: movie, offset: offset))
        let ordinal = requests.count
        lock.unlock()
        if let failure { return .failure(RunCaptureFailure(failure)) }
        // Distinct bytes per call: identical output across two renders can then
        // only mean the second render reused the file rather than re-extracting.
        return .success(Data("frame-bytes-\(ordinal)".utf8))
    }
}

private func info(ok: Bool, exit: Int32?) -> TrajectoryOutcomeInfo {
    TrajectoryOutcomeInfo(ok: ok, exit: exit, errorClass: ok ? nil : "runtime")
}

private func readRecords(_ path: String) throws -> [[String: Any]] {
    let content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    return try content.split(separator: "\n", omittingEmptySubsequences: true).map { line in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any])
    }
}

/// A control file naming THIS process, which the state machine therefore reads as
/// a live recording — a live recorder without spawning one.
private func writeLiveControl(into run: RunBundle, movie: String, startedAt: Double = 1_700_000_000) throws {
    try FileManager.default.createDirectory(atPath: run.videoDirectory, withIntermediateDirectories: true)
    let control = RecordControl(
        pid: getpid(),
        output: movie,
        startedAt: startedAt,
        display: 1,
        executable: LiveProcessProbe.executablePath(of: getpid()) ?? ""
    )
    try Data(control.jsonText().utf8).write(to: URL(fileURLWithPath: run.recordControlPath))
}

// MARK: - The capture path defers instead of capturing

@Suite struct RunStepFrameCaptureTests {
    /// The whole point: a live recording means NO second capture session, and the
    /// step still carries evidence — a marker naming where in the movie it sits.
    @Test func aLiveRecordingIsMarkedAndNoCaptureSessionIsOpened() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let movie = RunBundle(root: run).absolutePath(forRelative: "video/run.mp4")
            let spy = SpyCapture()

            _ = try TrajectoryRecorder.record(
                command: "act", args: TrajectoryArgs(), kind: .action,
                environment: [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"],
                operation: {}, describe: { _ in info(ok: true, exit: 0) },
                wallNow: { 1_700_000_010 },
                capture: spy,
                recording: StubRecordingProbe.live(movie: movie, startedAt: 1_700_000_000)
            )

            // Nothing asked the screen for anything.
            #expect(spy.calls == 0)
            let steps = try FileManager.default.contentsOfDirectory(atPath: RunBundle(root: run).stepsDirectory)
            #expect(steps.isEmpty)

            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            let evidence = try #require(record["evidence"] as? [String: Any])
            #expect(evidence["before"] == nil)
            #expect(evidence["after"] == nil)
            #expect(evidence["captureError"] == nil)
            let frames = try #require(evidence["frames"] as? [String: Any])
            let before = try #require(frames["before"] as? [String: Any])
            let after = try #require(frames["after"] as? [String: Any])
            // Recorded RELATIVE, so the bundle stays movable.
            #expect(before["movie"] as? String == "video/run.mp4")
            #expect(before["offset"] as? Double == 10)
            #expect(before["recordingStartedAt"] as? Double == 1_700_000_000)
            #expect(before["wallClock"] as? Double == 1_700_000_010)
            #expect(after["offset"] as? Double == 10)
        }
    }

    /// The no-recording path must be untouched: this is the behaviour every
    /// existing run bundle depends on.
    @Test func withNoRecordingLiveTheStillsAreCapturedExactlyAsBefore() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let spy = SpyCapture()

            _ = try TrajectoryRecorder.record(
                command: "act", args: TrajectoryArgs(), kind: .action,
                environment: [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"],
                operation: {}, describe: { _ in info(ok: true, exit: 0) },
                capture: spy, recording: StubRecordingProbe.none
            )

            #expect(spy.calls == 2)
            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            let evidence = try #require(record["evidence"] as? [String: Any])
            #expect(evidence["before"] as? String == "steps/0001-act-before.png")
            #expect(evidence["after"] as? String == "steps/0001-act-after.png")
            #expect(evidence["frames"] == nil)
        }
    }

    /// A marker that cannot be placed is recorded like any other missing
    /// evidence, and — crucially — does NOT fall back to capturing, which is the
    /// one thing that would kill the recording it failed to point into.
    @Test func aMarkerThatCannotBePlacedIsRecordedAndNeverFallsBackToCapturing() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let spy = SpyCapture()
            var ran = 0

            let result = try TrajectoryRecorder.record(
                command: "act", args: TrajectoryArgs(), kind: .action,
                environment: [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"],
                operation: { ran += 1; return 99 },
                describe: { _ in info(ok: false, exit: 1) },
                // A live recording that never published a start time.
                capture: spy, recording: StubRecordingProbe.live(movie: "/tmp/x.mp4", startedAt: 0)
            )

            // The documented command ran once, kept its result, and kept its exit code.
            #expect(ran == 1)
            #expect(result == 99)
            #expect(spy.calls == 0)

            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            let outcome = try #require(record["outcome"] as? [String: Any])
            #expect(outcome["ok"] as? Bool == false)
            #expect(outcome["exit"] as? Int == 1)
            let evidence = try #require(record["evidence"] as? [String: Any])
            #expect(evidence["frames"] == nil)
            let error = try #require(evidence["captureError"] as? String)
            #expect(error.hasPrefix("before: "))
            #expect(error.contains("; after: "))
            #expect(error.contains("no start time"))
        }
    }

    @Test func aStepDatedBeforeTheRecordingStartedIsRefusedRatherThanMarkedNegative() {
        let facts = RunRecordingFacts(movie: "/tmp/x.mp4", startedAt: 1_700_000_100, pid: 7)
        let outcome = TrajectoryRecorder.marker(for: facts, run: RunBundle(root: "/tmp/run"), at: 1_700_000_000)
        guard case let .failure(failure) = outcome else {
            Issue.record("a step before the recording started must not produce a marker")
            return
        }
        #expect(failure.diagnostic.contains("dated before the live recording started"))
    }

    /// A movie written outside the bundle (`record start --out …`) cannot be made
    /// relative, so it is recorded as what it is rather than as a wrong relative
    /// path.
    @Test func aMovieOutsideTheBundleIsMarkedByItsAbsolutePath() {
        let facts = RunRecordingFacts(movie: "/elsewhere/capture.mp4", startedAt: 1_000, pid: 7)
        let outcome = TrajectoryRecorder.marker(for: facts, run: RunBundle(root: "/tmp/run"), at: 1_002.5)
        guard case let .success(frame) = outcome else {
            Issue.record("expected a marker, got \(outcome)")
            return
        }
        #expect(frame.movie == "/elsewhere/capture.mp4")
        #expect(frame.offset == 2.5)
    }

    @Test func aReadOnlyCommandMarksItsSingleStateSlot() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let spy = SpyCapture()
            _ = try TrajectoryRecorder.record(
                command: "wait", args: TrajectoryArgs(), kind: .read,
                environment: [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"],
                operation: {}, describe: { _ in info(ok: true, exit: 0) },
                wallNow: { 1_700_000_004 },
                capture: spy,
                recording: StubRecordingProbe.live(movie: "video/run.mp4", startedAt: 1_700_000_000)
            )
            #expect(spy.calls == 0)
            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            let evidence = try #require(record["evidence"] as? [String: Any])
            let frames = try #require(evidence["frames"] as? [String: Any])
            #expect(frames["before"] == nil)
            #expect(frames["after"] == nil)
            let state = try #require(frames["state"] as? [String: Any])
            #expect(state["offset"] as? Double == 4)
        }
    }
}

// MARK: - What counts as "a recording is live"

@Suite struct RunStepFrameProbeTests {
    /// Liveness is the SAME question `record status` answers, read from the same
    /// file by the same state machine — there is only one definition of live.
    @Test func aRunningRecorderForThisRunIsLive() throws {
        try withTempDir { dir in
            let run = RunBundle(root: dir.appendingPathComponent("run").path)
            try writeLiveControl(into: run, movie: "/tmp/movie.mp4", startedAt: 1_700_000_000)

            let facts = try #require(LiveRunRecordingProbe().liveRecording(for: run))
            #expect(facts.movie == "/tmp/movie.mp4")
            #expect(facts.startedAt == 1_700_000_000)
            #expect(facts.pid == getpid())
        }
    }

    @Test func aRecorderThatIsGoneIsNotLiveSoAnOrdinaryCaptureIsSafeAgain() throws {
        try withTempDir { dir in
            let run = RunBundle(root: dir.appendingPathComponent("run").path)
            try writeLiveControl(into: run, movie: "/tmp/movie.mp4")
            let probe = LiveRunRecordingProbe(identity: { _ in .gone })
            #expect(probe.liveRecording(for: run) == nil)
        }
    }

    @Test func aRecycledPidIsNotLive() throws {
        try withTempDir { dir in
            let run = RunBundle(root: dir.appendingPathComponent("run").path)
            try writeLiveControl(into: run, movie: "/tmp/movie.mp4")
            let probe = LiveRunRecordingProbe(identity: { _ in .alive(executable: "/usr/bin/something-else") })
            #expect(probe.liveRecording(for: run) == nil)
        }
    }

    @Test func noControlFileAndADamagedOneBothMeanNothingIsRecording() throws {
        try withTempDir { dir in
            let run = RunBundle(root: dir.appendingPathComponent("run").path)
            #expect(LiveRunRecordingProbe().liveRecording(for: run) == nil)

            try FileManager.default.createDirectory(atPath: run.videoDirectory, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: URL(fileURLWithPath: run.recordControlPath))
            #expect(LiveRunRecordingProbe().liveRecording(for: run) == nil)
        }
    }

    /// Asking the question must not CREATE the thing it asks about.
    @Test func probingCreatesNothingOnDisk() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            _ = LiveRunRecordingProbe().liveRecording(for: RunBundle(root: run))
            let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(!FileManager.default.fileExists(atPath: run))
            #expect(contents.isEmpty)
        }
    }

    @Test func theControlFileIsLookedForWhereARecordingIntoThisBundlePublishesIt() {
        let run = RunBundle(root: "/tmp/run")
        #expect(run.recordControlPath == "/tmp/run/video/\(RecordPlan.controlFileName)")
        // The same place `RecordPlan` puts it for a run directory.
        let planned = RecordPlan.paths(runDirectory: "/tmp/run", out: nil, workingDirectory: "/elsewhere")
        #expect(planned.control == run.recordControlPath)
    }

    /// Scoped to the ACTIVE RUN: with no run directory there is nothing to
    /// protect and nothing is probed.
    @Test func theGuardOnlyAsksAboutTheActiveRun() {
        #expect(RunRecordingGuard.liveRecording(environment: [:]) == nil)
        #expect(RunRecordingGuard.liveRecording(environment: [MTouchEnvironment.runDirKey: ""]) == nil)
    }
}

// MARK: - Marker serialization

@Suite struct RunStepFrameRecordShapeTests {
    @Test func aMarkerRoundTripsThroughTheRecordedJSON() throws {
        let evidence = RunEvidence(frames: [
            .before: RunStepFrame(movie: "video/a.mp4", offset: 1.5, recordingStartedAt: 100, wallClock: 101.5),
            .state: RunStepFrame(movie: "video/a.mp4", offset: 2, recordingStartedAt: 100, wallClock: 102),
        ])
        let json = evidence.jsonObject()
        // Sorted keys, as everything else this project writes by hand.
        #expect(json.contains("\"frames\":{\"before\":{\"movie\":\"video/a.mp4\",\"offset\":1.5,"))
        #expect(json.range(of: "\"before\"")!.lowerBound < json.range(of: "\"state\"")!.lowerBound)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let parsed = RunEvidence.parseFrames(object["frames"] as? [String: Any])
        #expect(parsed == evidence.frames)
    }

    @Test func anUnreadableMarkerDegradesToAbsenceRatherThanDamage() {
        #expect(RunEvidence.parseFrames(["before": ["offset": 1.0]]).isEmpty)          // no movie
        #expect(RunEvidence.parseFrames(["before": ["movie": "a.mp4"]]).isEmpty)       // no offset
        #expect(RunEvidence.parseFrames(["nonsense": ["movie": "a.mp4", "offset": 1.0]]).isEmpty)
        #expect(RunEvidence.parseFrames(nil).isEmpty)
    }

    @Test func evidenceCarryingOnlyAMarkerIsNotEmpty() {
        var evidence = RunEvidence()
        #expect(evidence.isEmpty)
        evidence.frames[.before] = RunStepFrame(movie: "v.mp4", offset: 0, recordingStartedAt: 1, wallClock: 1)
        #expect(!evidence.isEmpty)
    }
}

// MARK: - The report materializes frames out of the movie

/// A bundle on disk, built by hand so each test pins exactly the shape it is
/// about.
private struct FrameBundleBuilder {
    let root: String

    init(root: String) throws {
        self.root = root
        try FileManager.default.createDirectory(
            atPath: RunBundle(root: root).stepsDirectory, withIntermediateDirectories: true
        )
        let facts = RunMetadata(
            createdAtWallClock: 1_700_000_000, createdAtMonotonic: 100,
            mtouchVersion: "9.9.9", macOSVersion: "15.5.0", label: "framed", stepCount: 1
        )
        try Data(facts.jsonText().utf8).write(to: URL(fileURLWithPath: RunBundle(root: root).metadataPath))
    }

    func writeTrajectory(_ lines: [String]) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8)
            .write(to: URL(fileURLWithPath: RunBundle(root: root).trajectoryPath))
    }

    /// Bytes standing in for the movie. They are never decoded: extraction goes
    /// through the `RunFrameExtracting` seam, so the file only has to EXIST.
    func writeMovie(_ name: String = "run.mp4") throws {
        let directory = RunBundle(root: root).videoDirectory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data("stand-in-movie-bytes".utf8)
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}

private func frameJSON(movie: String, offset: Double) -> String {
    RunStepFrame(movie: movie, offset: offset, recordingStartedAt: 1_700_000_000, wallClock: 1_700_000_000 + offset)
        .jsonObject()
}

private func recordLine(
    command: String = "act",
    step: Int? = 1,
    evidence: String? = nil
) -> String {
    var fields = [
        "\"command\":\(JSONText.string(command))",
        "\"timestamp\":101",
        "\"wallClock\":1700000001",
        "\"args\":{}",
        "\"outcome\":{\"ok\":true,\"exit\":0,\"errorClass\":null}",
    ]
    if let step { fields.append("\"step\":\(step)") }
    if let evidence { fields.append("\"evidence\":\(evidence)") }
    return "{" + fields.joined(separator: ",") + "}"
}

private func rendered(_ root: String, extractor: RunFrameExtracting, redact: Bool = false) -> String {
    let bundle = redact
        ? RunReportLoader.load(runDirectory: root)
        : RunFrameMaterializer.materialize(RunReportLoader.load(runDirectory: root), extractor: extractor)
    return RunReportHTML.render(bundle, redact: redact)
}

@Suite struct RunStepFrameReportTests {
    @Test func markersAreCutOutOfTheMovieAtTheirRecordedOffsets() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try FrameBundleBuilder(root: root)
            try builder.writeMovie()
            try builder.writeTrajectory([
                recordLine(evidence: "{\"frames\":{"
                    + "\"after\":\(frameJSON(movie: "video/run.mp4", offset: 4.25)),"
                    + "\"before\":\(frameJSON(movie: "video/run.mp4", offset: 1.5))}}"),
            ])
            let extractor = StubExtractor()

            let html = rendered(root, extractor: extractor)

            // Both moments were asked for, at exactly the offsets recorded.
            let movie = RunBundle(root: root).absolutePath(forRelative: "video/run.mp4")
            #expect(Set(extractor.recorded) == [
                StubExtractor.Request(movie: movie, offset: 1.5),
                StubExtractor.Request(movie: movie, offset: 4.25),
            ])
            // The PNGs landed under the ordinary step naming, so the page renders
            // them the way it renders any other still.
            for relative in ["steps/0001-act-before.png", "steps/0001-act-after.png"] {
                #expect(FileManager.default.fileExists(atPath: RunBundle(root: root).absolutePath(forRelative: relative)))
            }
            #expect(html.contains("data:image/png;base64,\(Data("frame-bytes-1".utf8).base64EncodedString())"))
            #expect(html.contains("data:image/png;base64,\(Data("frame-bytes-2".utf8).base64EncodedString())"))
            // …and their provenance is stated, never passed off as a direct capture.
            #expect(html.contains("extracted from the recording"))
            #expect(html.contains("<code>video/run.mp4</code> at 1.500 s"))
            #expect(html.contains("<code>video/run.mp4</code> at 4.250 s"))
            #expect(html.contains("from-recording"))
            #expect(!html.contains("frame unavailable"))
        }
    }

    /// A step whose still was captured directly and one whose still came out of
    /// the movie can sit side by side — a recording that started mid-run does
    /// exactly that — and only the second claims the recording as its source.
    @Test func aDirectStillAndAnExtractedFrameAreDistinguishableOnTheSameStep() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try FrameBundleBuilder(root: root)
            try builder.writeMovie()
            try Data("DIRECT".utf8).write(
                to: URL(fileURLWithPath: RunBundle(root: root).absolutePath(forRelative: "steps/0001-act-before.png"))
            )
            try builder.writeTrajectory([
                recordLine(evidence: "{\"before\":\"steps/0001-act-before.png\","
                    + "\"frames\":{\"after\":\(frameJSON(movie: "video/run.mp4", offset: 3))}}"),
            ])

            let html = rendered(root, extractor: StubExtractor())
            #expect(html.contains("<img alt=\"before screenshot\""))
            #expect(html.contains("<img alt=\"after frame\""))
            let direct = try #require(html.range(of: Data("DIRECT".utf8).base64EncodedString()))
            let provenance = try #require(html.range(of: "extracted from the recording"))
            #expect(direct.lowerBound < provenance.lowerBound)
            // The direct still's caption stays exactly what it was.
            #expect(html.contains("<figcaption>before — <code>steps/0001-act-before.png</code></figcaption>"))
        }
    }

    @Test func aMissingMovieDegradesVisiblyAndTheStepStillRenders() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try FrameBundleBuilder(root: root)
            try builder.writeTrajectory([
                recordLine(evidence: "{\"frames\":{\"before\":\(frameJSON(movie: "video/run.mp4", offset: 1.5))}}"),
            ])
            let extractor = StubExtractor()

            let html = rendered(root, extractor: extractor)
            #expect(extractor.calls == 0)
            #expect(html.contains("before frame unavailable"))
            #expect(html.contains("video/run.mp4"))
            #expect(html.contains("is missing or empty"))
            #expect(html.contains("at 1.500 s"))
            #expect(html.contains(">act<"))               // the step itself still renders
            #expect(html.hasSuffix("</html>\n"))
            #expect(!html.contains("data:image/png;base64,"))
        }
    }

    /// Every reason a frame cannot be produced — a generator failure, an offset
    /// past the end of the movie — reaches the page as a stated absence.
    @Test func aFailureToCutTheFrameIsStatedWithItsReason() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try FrameBundleBuilder(root: root)
            try builder.writeMovie()
            try builder.writeTrajectory([
                recordLine(evidence: "{\"frames\":{\"before\":\(frameJSON(movie: "video/run.mp4", offset: 99))}}"),
            ])
            let reason = "mtouch: this step is 99 s into the recording, but it is only 12 s long"

            let html = rendered(root, extractor: StubExtractor(failure: reason))
            #expect(html.contains("before frame unavailable"))
            #expect(html.contains("only 12 s long"))
            #expect(html.contains("no screenshot was taken because a screen recording was live"))
            #expect(html.hasSuffix("</html>\n"))
        }
    }

    @Test func aRecordWithoutAStepNumberSaysWhyItsFrameHasNoHome() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try FrameBundleBuilder(root: root)
            try builder.writeMovie()
            try builder.writeTrajectory([
                recordLine(step: nil, evidence: "{\"frames\":{\"state\":\(frameJSON(movie: "video/run.mp4", offset: 1))}}"),
            ])
            let extractor = StubExtractor()

            let html = rendered(root, extractor: extractor)
            #expect(extractor.calls == 0)
            #expect(html.contains("no step number"))
        }
    }

    /// The same containment rule the renderer applies before inlining a file:
    /// `report` must not become a way to read `../../somewhere`.
    @Test func aMarkerPointingOutsideTheBundleIsRefused() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try FrameBundleBuilder(root: root)
            try Data("NOT-A-MOVIE-BUT-SECRET".utf8).write(to: dir.appendingPathComponent("secret.mp4"))
            try builder.writeTrajectory([
                recordLine(evidence: "{\"frames\":{\"before\":\(frameJSON(movie: "../secret.mp4", offset: 1))}}"),
            ])
            let extractor = StubExtractor()

            let html = rendered(root, extractor: extractor)
            #expect(extractor.calls == 0)
            #expect(html.contains("is not inside this run bundle"))
        }
    }

    @Test func theLegendExplainsTheProvenanceOnlyWhenThereIsSomeToExplain() throws {
        try withTempDir { dir in
            let plain = dir.appendingPathComponent("plain").path
            let framed = dir.appendingPathComponent("framed").path
            let plainBuilder = try FrameBundleBuilder(root: plain)
            try plainBuilder.writeTrajectory([recordLine()])
            let framedBuilder = try FrameBundleBuilder(root: framed)
            try framedBuilder.writeMovie()
            try framedBuilder.writeTrajectory([
                recordLine(evidence: "{\"frames\":{\"before\":\(frameJSON(movie: "video/run.mp4", offset: 1))}}"),
            ])

            #expect(!rendered(plain, extractor: StubExtractor()).contains("were not captured at the time"))
            #expect(rendered(framed, extractor: StubExtractor()).contains("were not captured at the time"))
        }
    }
}

// MARK: - Report stays deterministic even though it writes files

@Suite struct RunStepFrameDeterminismTests {
    /// Extraction writes into the bundle, so re-rendering could easily feed on
    /// its own output. It must not: the second render reuses the PNGs and
    /// produces the same bytes.
    @Test func reRenderingIsByteIdenticalAndExtractsNothingASecondTime() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try FrameBundleBuilder(root: root)
            try builder.writeMovie()
            try builder.writeTrajectory([
                recordLine(evidence: "{\"frames\":{"
                    + "\"after\":\(frameJSON(movie: "video/run.mp4", offset: 4)),"
                    + "\"before\":\(frameJSON(movie: "video/run.mp4", offset: 1))}}"),
            ])
            // Hands back different bytes every call, so a second extraction would
            // be impossible to miss.
            let extractor = StubExtractor()

            let first = ReportPipeline.run(runDirectory: root, out: nil, extractor: extractor)
            let firstBytes = try Data(contentsOf: URL(fileURLWithPath: RunBundle(root: root).reportPath))
            let second = ReportPipeline.run(runDirectory: root, out: nil, extractor: extractor)
            let secondBytes = try Data(contentsOf: URL(fileURLWithPath: RunBundle(root: root).reportPath))

            #expect(first == second)
            #expect(firstBytes == secondBytes)
            #expect(extractor.calls == 2)              // two slots, extracted once
        }
    }

    /// `--redact` exists to keep imagery out of the render; materializing would
    /// create new imagery on disk in order to then omit it.
    @Test func redactNeitherExtractsNorInlinesAnything() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try FrameBundleBuilder(root: root)
            try builder.writeMovie()
            try builder.writeTrajectory([
                recordLine(evidence: "{\"frames\":{\"before\":\(frameJSON(movie: "video/run.mp4", offset: 1))}}"),
            ])
            let extractor = StubExtractor()

            let outcome = ReportPipeline.run(runDirectory: root, out: nil, redact: true, extractor: extractor)
            guard case .rendered = outcome else {
                Issue.record("expected a rendered report, got \(outcome)")
                return
            }
            #expect(extractor.calls == 0)
            let steps = try FileManager.default.contentsOfDirectory(atPath: RunBundle(root: root).stepsDirectory)
            #expect(steps.isEmpty)
            let html = try String(contentsOf: URL(fileURLWithPath: RunBundle(root: root).reportPath), encoding: .utf8)
            #expect(!html.contains("data:image/png;base64,"))
            #expect(html.contains("Redacted"))
        }
    }
}

// MARK: - The live extractor's own guards

@Suite struct LiveFrameExtractorGuardTests {
    /// The arithmetic guard, which is decided before any file is opened — so it
    /// holds on a host with no media stack at all. Everything past it is
    /// integration with AVFoundation and is exercised through the seam above and
    /// live against a real recording.
    @Test func anImpossibleOffsetIsRefusedWithoutTouchingTheMovie() {
        for offset in [-1.0, -0.001, Double.nan, -Double.infinity] {
            let result = LiveFrameExtractor().extractPNG(movie: "/nonexistent/movie.mp4", atOffset: offset)
            guard case let .failure(failure) = result else {
                Issue.record("offset \(offset) must not be accepted as a position in a movie")
                continue
            }
            #expect(failure.diagnostic.contains("not a position in a movie"))
        }
    }

    /// Non-zero, because the recorder writes a frame only when the screen
    /// changes and no fixed rate may be assumed. Bounded well under a second,
    /// because a wide window snaps steps that are seconds apart onto one frame —
    /// the same picture captioned as four different moments, which is wrong
    /// evidence rather than missing evidence.
    @Test func theToleranceIsNonZeroButNarrowEnoughToKeepDistinctMomentsDistinct() {
        #expect(LiveFrameExtractor.toleranceSeconds > 0)
        #expect(LiveFrameExtractor.toleranceSeconds < 1)
        #expect(LiveFrameExtractor.toleranceSeconds.isFinite)
    }
}

// MARK: - Standalone screenshot refuses rather than destroying the recording

@Suite struct RunStepFrameScreenshotRefusalTests {
    @Test func aLiveRecordingRefusesTheScreenshotAndCapturesNothing() {
        let spy = SpyCapture()
        var wrote = false
        let facts = RunRecordingFacts(movie: "/tmp/run/video/run.mp4", startedAt: 1_700_000_000, pid: 4242)

        let outcome = ScreenshotPipeline.run(
            window: nil, out: "/tmp/should-not-write.png", directory: "/tmp",
            permissions: StubRecordingPermissions(granted: true),
            liveRecording: { facts },
            capture: { _ in
                Issue.record("no capture may be attempted while a recording is live")
                return .failure(.blankCapture)
            },
            write: { _, _ in wrote = true; return .success(()) }
        )

        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(code == .runtimeFailure)          // recoverable, not a permission problem
        #expect(!wrote)
        #expect(spy.calls == 0)
        #expect(stderr.contains("a recording is in progress for this run"))
        #expect(stderr.contains("/tmp/run/video/run.mp4"))
        #expect(stderr.contains("pid 4242"))
        #expect(stderr.contains("mtouch record stop"))
        #expect(stderr.contains("--capture"))
    }

    @Test func withNothingRecordingTheScreenshotIsUnaffected() {
        let outcome = ScreenshotPipeline.run(
            window: nil, out: "/tmp/mtouch-frame-test.png", directory: "/tmp",
            permissions: StubRecordingPermissions(granted: true),
            liveRecording: { nil },
            capture: { _ in .success(nonBlankCapture()) },
            write: { _, _ in .success(()) }
        )
        guard case .written = outcome else {
            Issue.record("expected a written screenshot, got \(outcome)")
            return
        }
    }

    /// Protecting the recording outranks every other refusal: a missing grant is
    /// reported on the next run, a destroyed recording is not recoverable at all.
    @Test func theRefusalComesBeforeEveryOtherCheck() {
        let outcome = ScreenshotPipeline.run(
            window: "not-a-number", out: nil, directory: "/tmp",
            permissions: StubRecordingPermissions(granted: false),
            liveRecording: { RunRecordingFacts(movie: "/tmp/m.mp4", startedAt: 1, pid: 9) },
            capture: { _ in .failure(.blankCapture) }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("a recording is in progress for this run"))
    }

    /// The MCP surface refuses with the SAME wording — an agent must not be able
    /// to destroy the recording of the run it is being observed in either.
    @Test func theMCPSurfaceRefusesIdentically() throws {
        try withTempDir { dir in
            let run = RunBundle(root: dir.appendingPathComponent("run").path)
            try writeLiveControl(into: run, movie: "/tmp/run/video/run.mp4")

            let result = MCPToolDispatch.dispatch(
                tool: "screenshot", arguments: ToolArguments(),
                environment: [MTouchEnvironment.runDirKey: run.root],
                permissions: StubRecordingPermissions(granted: true)
            )
            #expect(result.isError)
            let facts = try #require(LiveRunRecordingProbe().liveRecording(for: run))
            #expect(result.payloads.contains(.text(RunRecordingGuard.refusal(facts))))
        }
    }
}

/// A permission provider with a fixed answer, so no TCC state is consulted.
private struct StubRecordingPermissions: PermissionProvider {
    let granted: Bool
    var accessibilityGranted: Bool { granted }
    var screenRecordingGranted: Bool { granted }
}

/// A 2x2 non-black image, enough to get past the blank-capture backstop without
/// touching the screen.
private func nonBlankCapture() -> CapturedImage {
    let width = 2
    let height = 2
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    pixels[0] = 10
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return CapturedImage(cgImage: context.makeImage()!, displayName: "Test", scale: 1)
}
