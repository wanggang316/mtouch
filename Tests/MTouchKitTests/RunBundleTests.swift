import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures & helpers

/// A fresh, unique temp directory removed at the end of the closure. Tests write
/// ONLY here — never the real home, never a shared run directory, never the screen.
private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-run-bundle-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

/// A capture that never touches the screen: it hands back fixed bytes, or a fixed
/// failure. Every capture path in these tests goes through this, so nothing here
/// needs ScreenCaptureKit, TCC, or a display.
private struct StubCapture: RunCapturing {
    var payload: Result<Data, RunCaptureFailure> = .success(Data("stub-png-bytes".utf8))

    static let granted = StubCapture()
    static func denied(_ reason: String) -> StubCapture {
        StubCapture(payload: .failure(RunCaptureFailure(reason)))
    }

    func capturePNG() -> Result<Data, RunCaptureFailure> { payload }
}

private func info(ok: Bool, exit: Int32?, errorClass: String?, diff: String? = nil) -> TrajectoryOutcomeInfo {
    TrajectoryOutcomeInfo(ok: ok, exit: exit, errorClass: errorClass, diff: diff)
}

private func readRecords(_ path: String) throws -> [[String: Any]] {
    let content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    return try content.split(separator: "\n", omittingEmptySubsequences: true).map { line in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any])
    }
}

private func readMetadata(_ runRoot: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: RunBundle(root: runRoot).metadataPath))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Record one command into `environment`, returning the operation's result.
@discardableResult
private func recordOne(
    command: String = "act",
    kind: TrajectoryKind = .action,
    args: TrajectoryArgs = TrajectoryArgs(),
    environment: [String: String],
    capture: RunCapturing = StubCapture.granted,
    ok: Bool = true,
    operation: @escaping () -> Void = {}
) throws -> Int {
    try TrajectoryRecorder.record(
        command: command, args: args, kind: kind, environment: environment,
        operation: { operation(); return 7 },
        describe: { _ in info(ok: ok, exit: ok ? 0 : 1, errorClass: ok ? nil : "runtime") },
        capture: capture
    )
}

// MARK: - Layout

@Suite struct RunBundleLayoutTests {
    @Test func aRunDirectoryAloneTurnsRecordingOnAndBuildsTheLayout() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            // No MTOUCH_TRAJECTORY at all: the bundle's own stream is the target.
            try recordOne(command: "apps", kind: .read, environment: [MTouchEnvironment.runDirKey: run])

            let bundle = RunBundle(root: run)
            #expect(FileManager.default.fileExists(atPath: bundle.metadataPath))
            #expect(FileManager.default.fileExists(atPath: bundle.trajectoryPath))
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: bundle.stepsDirectory, isDirectory: &isDir))
            #expect(isDir.boolValue)
            #expect(try readRecords(bundle.trajectoryPath).count == 1)
        }
    }

    @Test func runJsonCarriesSchemaBothClocksVersionsLabelAndStepCount() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            try recordOne(
                command: "apps", kind: .read,
                environment: [
                    MTouchEnvironment.runDirKey: run,
                    MTouchEnvironment.runLabelKey: "checkout flow",
                ]
            )

            let metadata = try readMetadata(run)
            #expect(metadata["schemaVersion"] as? Int == RunMetadata.currentSchemaVersion)
            #expect(metadata["label"] as? String == "checkout flow")
            #expect(metadata["mtouchVersion"] as? String == MTouchVersion.current)
            #expect((metadata["macOSVersion"] as? String)?.isEmpty == false)
            #expect(metadata["stepCount"] as? Int == 1)
            // Both clocks, side by side and distinct: one absolute, one monotonic.
            let createdAt = try #require(metadata["createdAt"] as? [String: Any])
            let wall = try #require(createdAt["wallClock"] as? Double)
            let monotonic = try #require(createdAt["monotonic"] as? Double)
            #expect(wall > 1_600_000_000)          // a plausible epoch, not an uptime
            #expect(monotonic >= 0)
            #expect(wall != monotonic)
        }
    }

    @Test func labelIsOmittedWhenUnset() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            try recordOne(command: "apps", kind: .read, environment: [MTouchEnvironment.runDirKey: run])
            #expect(try readMetadata(run)["label"] == nil)
        }
    }

    @Test func theVideoDirectoryIsReservedButNotFabricated() throws {
        // The recording pass writes into `video/`; claiming the directory now would
        // assert evidence that does not exist. The report treats it as absent.
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            try recordOne(command: "apps", kind: .read, environment: [MTouchEnvironment.runDirKey: run])
            #expect(!FileManager.default.fileExists(atPath: RunBundle(root: run).videoDirectory))
            #expect(RunBundle.videoDirectoryName == "video")
        }
    }

    @Test func stepImagePathsAreZeroPaddedRunRelativeAndFilenameSafe() {
        let step = RunStep(index: 7, command: "act")
        #expect(step.relativePath(.before) == "steps/0007-act-before.png")
        #expect(step.relativePath(.after) == "steps/0007-act-after.png")
        #expect(step.relativePath(.state) == "steps/0007-act-state.png")
        // A command name that could escape the directory loses its separators, so
        // it stays ONE filename inside steps/ rather than a traversal.
        let hostile = RunStep(index: 1, command: "../../etc/passwd").relativePath(.state)
        #expect(hostile == "steps/0001-..-..-etc-passwd-state.png")
        #expect(hostile.filter { $0 == "/" }.count == 1)
        // Non-ASCII is reduced too: a step image must be addressable by its path.
        #expect(RunBundle.filenameSafe("日本 🎉") == "----")
        #expect(RunBundle.filenameSafe("") == "command")
    }
}

// MARK: - Idempotent re-open

@Suite struct RunBundleReopenTests {
    @Test func reopeningAppendsWithoutClobberingMetadataOrRestartingNumbering() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let env = [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runLabelKey: "first"]

            try recordOne(command: "apps", kind: .read, environment: env)
            let first = try readMetadata(run)
            let firstCreated = try #require(first["createdAt"] as? [String: Any])

            // A SECOND command, arriving with a different label, must not restamp
            // the run it is joining.
            try recordOne(
                command: "snapshot", kind: .snapshot,
                environment: [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runLabelKey: "second"]
            )
            try recordOne(command: "act", kind: .action, environment: env)

            let latest = try readMetadata(run)
            #expect(latest["label"] as? String == "first")             // untouched
            let latestCreated = try #require(latest["createdAt"] as? [String: Any])
            #expect(latestCreated["wallClock"] as? Double == firstCreated["wallClock"] as? Double)
            #expect(latest["stepCount"] as? Int == 3)                  // continued, not restarted

            let records = try readRecords(RunBundle(root: run).trajectoryPath)
            #expect(records.count == 3)
            #expect(records.compactMap { $0["step"] as? Int } == [1, 2, 3])
        }
    }

    @Test func recoveryFromADeletedRunJsonNeverReusesAnExistingStepNumber() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let env = [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"]
            try recordOne(command: "act", environment: env)
            try recordOne(command: "act", environment: env)

            // Something external damages the counter. The next allocation must land
            // ABOVE the highest evidence already on disk, never on top of it.
            try Data("not json".utf8).write(to: URL(fileURLWithPath: RunBundle(root: run).metadataPath))
            try recordOne(command: "act", environment: env)

            let steps = try readRecords(RunBundle(root: run).trajectoryPath).compactMap { $0["step"] as? Int }
            #expect(steps == [1, 2, 3])
        }
    }
}

// MARK: - Concurrent step allocation

@Suite struct RunBundleConcurrencyTests {
    @Test func concurrentCommandsNeverClaimTheSameStepNumber() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let env = [MTouchEnvironment.runDirKey: run]
            let count = 40

            // Many parallel invocations append to ONE run. The counter is allocated
            // under the bundle's exclusive lock, so every writer gets a distinct
            // ordinal — without the lock they would collide on 0001 and silently
            // interleave their evidence.
            DispatchQueue.concurrentPerform(iterations: count) { index in
                _ = try? TrajectoryRecorder.record(
                    command: "act",
                    args: TrajectoryArgs.build(["worker": .int(index)]),
                    kind: .action, environment: env, operation: {},
                    describe: { _ in info(ok: true, exit: 0, errorClass: nil) },
                    capture: StubCapture.granted
                )
            }

            let records = try readRecords(RunBundle(root: run).trajectoryPath)
            #expect(records.count == count)
            let steps = records.compactMap { $0["step"] as? Int }
            #expect(steps.count == count)
            #expect(Set(steps) == Set(1...count))               // distinct, contiguous
            #expect(try readMetadata(run)["stepCount"] as? Int == count)
        }
    }

    @Test func concurrentCapturingCommandsWriteDistinctStepImages() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let env = [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"]
            let count = 12

            DispatchQueue.concurrentPerform(iterations: count) { _ in
                _ = try? TrajectoryRecorder.record(
                    command: "act", args: TrajectoryArgs(), kind: .action, environment: env,
                    operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) },
                    capture: StubCapture.granted
                )
            }

            // Two files per action step, all distinct: no writer overwrote another's.
            let files = try FileManager.default.contentsOfDirectory(atPath: RunBundle(root: run).stepsDirectory)
                .filter { $0.hasSuffix(".png") }
            #expect(files.count == count * 2)
            #expect(Set(files).count == files.count)
        }
    }
}

// MARK: - Fail fast

@Suite struct RunBundleFailFastTests {
    @Test func aRunDirectoryThatIsAFileAbortsBeforeRunningTheOperation() throws {
        try withTempDir { dir in
            let asFile = dir.appendingPathComponent("iam-a-file")
            try Data("x".utf8).write(to: asFile)

            var ran = false
            #expect(throws: RunBundleError.self) {
                _ = try TrajectoryRecorder.record(
                    command: "apps", args: TrajectoryArgs(), kind: .read,
                    environment: [MTouchEnvironment.runDirKey: asFile.path],
                    operation: { ran = true },
                    describe: { _ in info(ok: true, exit: 0, errorClass: nil) },
                    capture: StubCapture.granted
                )
            }
            #expect(!ran)   // never a silent, undocumented run
        }
    }

    @Test func anUncreatableRunDirectoryAbortsBeforeRunningTheOperation() throws {
        // Root bypasses POSIX permission bits; the assertion only holds for a
        // non-root user.
        try #require(getuid() != 0)
        try withTempDir { dir in
            let locked = dir.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)

            var ran = false
            #expect(throws: RunBundleError.self) {
                _ = try TrajectoryRecorder.record(
                    command: "apps", args: TrajectoryArgs(), kind: .read,
                    environment: [MTouchEnvironment.runDirKey: locked.appendingPathComponent("run").path],
                    operation: { ran = true },
                    describe: { _ in info(ok: true, exit: 0, errorClass: nil) },
                    capture: StubCapture.granted
                )
            }
            #expect(!ran)
        }
    }

    @Test func theDiagnosticsNameTheOffendingPath() {
        #expect(RunBundleError.pathIsFile("/tmp/x").diagnostic
            == "mtouch: cannot open run directory: path is a file: /tmp/x")
        #expect(RunBundleError.notWritable(path: "/tmp/x", reason: "Permission denied").diagnostic
            == "mtouch: cannot write run directory /tmp/x: Permission denied")
    }

    @Test func anUnusableRunDirectoryReachesTheMCPSurfaceWithTheSameWording() throws {
        try withTempDir { dir in
            let asFile = dir.appendingPathComponent("iam-a-file")
            try Data("x".utf8).write(to: asFile)
            let result = MCPToolDispatch.dispatchRecorded(
                tool: "apps", arguments: ToolArguments(),
                environment: [MTouchEnvironment.runDirKey: asFile.path]
            )
            #expect(result.isError)
            #expect(result.payloads.contains(.text(RunBundleError.pathIsFile(asFile.path).diagnostic)))
        }
    }
}

// MARK: - Opt-in captures

@Suite struct RunBundleCaptureTests {
    @Test func capturesAreOffUnlessAskedFor() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            try recordOne(environment: [MTouchEnvironment.runDirKey: run])

            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            #expect(record["step"] as? Int == 1)          // the step still exists…
            #expect(record["evidence"] == nil)            // …but nothing was captured
            let files = try FileManager.default.contentsOfDirectory(atPath: RunBundle(root: run).stepsDirectory)
            #expect(files.isEmpty)
        }
    }

    @Test func captureFlagVocabularyIsExplicit() {
        for on in ["1", "true", "TRUE", "yes", "on", " 1 "] {
            #expect(RunBundle.captureEnabled(environment: [MTouchEnvironment.runCaptureKey: on]))
        }
        for off in ["0", "false", "no", "", "maybe"] {
            #expect(!RunBundle.captureEnabled(environment: [MTouchEnvironment.runCaptureKey: off]))
        }
        #expect(!RunBundle.captureEnabled(environment: [:]))
    }

    @Test func aMutatingCommandIsBracketedByABeforeAndAnAfter() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            try recordOne(environment: [
                MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1",
            ])

            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            let evidence = try #require(record["evidence"] as? [String: Any])
            #expect(evidence["before"] as? String == "steps/0001-act-before.png")
            #expect(evidence["after"] as? String == "steps/0001-act-after.png")
            #expect(evidence["state"] == nil)
            #expect(evidence["captureError"] == nil)
            for relative in ["steps/0001-act-before.png", "steps/0001-act-after.png"] {
                let path = RunBundle(root: run).absolutePath(forRelative: relative)
                #expect(FileManager.default.fileExists(atPath: path))
            }
        }
    }

    @Test func aReadOnlyCommandCapturesExactlyOnce() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            try recordOne(command: "wait", kind: .read, environment: [
                MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1",
            ])

            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            let evidence = try #require(record["evidence"] as? [String: Any])
            #expect(evidence["state"] as? String == "steps/0001-wait-state.png")
            #expect(evidence["before"] == nil)
            #expect(evidence["after"] == nil)
            let files = try FileManager.default.contentsOfDirectory(atPath: RunBundle(root: run).stepsDirectory)
            #expect(files == ["0001-wait-state.png"])
        }
    }

    @Test func aScreenshotCommandIsItsOwnEvidenceAndIsNotCapturedTwice() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            _ = try TrajectoryRecorder.record(
                command: "screenshot", args: TrajectoryArgs(), kind: .screenshot,
                environment: [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"],
                operation: {},
                describe: { _ in
                    TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil, screenshotPath: "/tmp/shot.png")
                },
                capture: StubCapture.granted
            )

            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            #expect(record["screenshotPath"] as? String == "/tmp/shot.png")
            #expect(record["evidence"] == nil)
            let files = try FileManager.default.contentsOfDirectory(atPath: RunBundle(root: run).stepsDirectory)
            #expect(files.isEmpty)
        }
    }
}

// MARK: - Evidence never breaks the task

@Suite struct RunBundleDegradationTests {
    @Test func aCaptureFailureIsRecordedAndTheOperationStillRunsAndReturns() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let denied = PermissionError(permission: .screenRecording).diagnostic

            var ran = 0
            let result = try TrajectoryRecorder.record(
                command: "act", args: TrajectoryArgs.build(["verb": .string("press")]), kind: .action,
                environment: [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"],
                operation: { ran += 1; return 99 },
                describe: { _ in info(ok: true, exit: 0, errorClass: nil, diff: "+ e2") },
                capture: StubCapture.denied(denied)
            )

            // The documented operation ran exactly once and its result is untouched.
            #expect(ran == 1)
            #expect(result == 99)

            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            let outcome = try #require(record["outcome"] as? [String: Any])
            #expect(outcome["ok"] as? Bool == true)          // the command still succeeded
            #expect(outcome["exit"] as? Int == 0)            // at its own exit code
            let evidence = try #require(record["evidence"] as? [String: Any])
            #expect(evidence["before"] == nil)
            #expect(evidence["after"] == nil)
            // Both attempts are named, in order, so the gap is explained rather than blank.
            let error = try #require(evidence["captureError"] as? String)
            #expect(error.hasPrefix("before: "))
            #expect(error.contains("; after: "))
            #expect(error.contains(denied))
        }
    }

    @Test func aFailingCommandKeepsItsOwnExitCodeWhileEvidenceIsCollected() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            try recordOne(
                environment: [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"],
                ok: false
            )
            let record = try #require(try readRecords(RunBundle(root: run).trajectoryPath).first)
            let outcome = try #require(record["outcome"] as? [String: Any])
            #expect(outcome["ok"] as? Bool == false)
            #expect(outcome["exit"] as? Int == 1)
            #expect(record["evidence"] != nil)               // still documented
        }
    }

    @Test func anUnwritableStepsDirectoryDegradesToACaptureErrorNotAFailure() throws {
        try #require(getuid() != 0)
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let bundle = RunBundle(root: run)
            _ = try RunBundle.open(path: run)
            // Evidence can no longer be WRITTEN, but the run must go on.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bundle.stepsDirectory)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.stepsDirectory)
            }

            var ran = false
            let result = try TrajectoryRecorder.record(
                command: "act", args: TrajectoryArgs(), kind: .action,
                environment: [MTouchEnvironment.runDirKey: run, MTouchEnvironment.runCaptureKey: "1"],
                operation: { ran = true; return 5 },
                describe: { _ in info(ok: true, exit: 0, errorClass: nil) },
                capture: StubCapture.granted
            )
            #expect(ran)
            #expect(result == 5)
            let record = try #require(try readRecords(bundle.trajectoryPath).first)
            let evidence = try #require(record["evidence"] as? [String: Any])
            #expect((evidence["captureError"] as? String)?.contains("cannot write screenshot") == true)
        }
    }
}

// MARK: - Explicit beats implicit

@Suite struct RunBundleTrajectoryPrecedenceTests {
    @Test func anExplicitTrajectoryWinsOverTheRunDirectorysOwnStream() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            let explicit = dir.appendingPathComponent("chosen.jsonl").path

            try recordOne(environment: [
                MTouchEnvironment.runDirKey: run,
                MTouchEnvironment.trajectoryKey: explicit,
                MTouchEnvironment.runCaptureKey: "1",
            ])

            // The record went to the operator's file…
            let records = try readRecords(explicit)
            #expect(records.count == 1)
            #expect(records[0]["step"] as? Int == 1)
            // …and the bundle's own stream stayed untouched…
            #expect(!FileManager.default.fileExists(atPath: RunBundle(root: run).trajectoryPath))
            // …while the bundle still numbered the step and collected its evidence,
            // so the record in the chosen file still resolves against the bundle.
            let evidence = try #require(records[0]["evidence"] as? [String: Any])
            #expect(evidence["before"] as? String == "steps/0001-act-before.png")
            let absolute = RunBundle(root: run).absolutePath(forRelative: "steps/0001-act-before.png")
            #expect(FileManager.default.fileExists(atPath: absolute))
        }
    }

    @Test func anEmptyExplicitTrajectoryDefersToTheBundle() throws {
        try withTempDir { dir in
            let run = dir.appendingPathComponent("run").path
            try recordOne(environment: [
                MTouchEnvironment.runDirKey: run,
                MTouchEnvironment.trajectoryKey: "",
            ])
            #expect(try readRecords(RunBundle(root: run).trajectoryPath).count == 1)
        }
    }

    @Test func withNeitherSetRecordingStaysOffAndNothingIsWritten() throws {
        try withTempDir { dir in
            let result = try recordOne(environment: ["HOME": dir.path])
            #expect(result == 7)
            let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(contents.isEmpty)
        }
    }
}
