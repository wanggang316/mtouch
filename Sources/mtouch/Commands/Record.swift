import ArgumentParser
import Foundation
import MTouchKit

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record the screen to a movie for the duration of a run.",
        discussion: """
        Runs a screen recording alongside a sequence of mtouch commands. 'start' \
        launches a detached recorder and returns only once ScreenCaptureKit has \
        confirmed that capture is LIVE; 'stop' asks it to finalize the movie and \
        then VERIFIES the result — a file that is missing, empty, unreadable, \
        without a video track, or of zero duration is reported as a failure \
        (exit 1) naming the reason, never as a successful recording.

        With MTOUCH_RUN_DIR / --run-dir the movie lands in <run-dir>/video/, so \
        'mtouch report <run-dir>' embeds it with no extra flags. Without a run \
        directory the recording, its control file, and its log are written in the \
        current directory.

        One recording per directory: a second 'start' fails, naming the live one. \
        A control file left behind by a crashed recorder is recovered on the next \
        'start', which first reports whether that earlier movie survived.

        DO NOT run 'mtouch screenshot' — or any command with --capture / \
        MTOUCH_RUN_CAPTURE=1 — while a recording is live. ScreenCaptureKit \
        invalidates a running stream when a SECOND process of the same binary \
        opens and closes its own capture session, so the screenshot succeeds and \
        the recording dies with "application connection interrupted". This is not \
        silent: the recorder refuses to sign off, and 'record stop' then exits 1 \
        quoting the failure. Take per-step screenshots or a recording, not both.

        Recording needs macOS 15 or later and the Screen Recording permission \
        (run 'mtouch doctor'). It captures WHATEVER IS ON SCREEN, including other \
        applications and notifications.
        """,
        subcommands: [RecordStart.self, RecordStop.self, RecordStatus.self]
    )

    mutating func run() throws {
        throw ValidationError("Missing subcommand. Use 'record start', 'record stop', or 'record status'.")
    }
}

// MARK: - Shared plumbing

/// `--run-dir` for the record subcommands.
///
/// Deliberately NOT `RunOptions`: that group also offers `--capture`, which
/// would be a silent no-op here, and every recorded command wraps itself in a
/// trajectory record. `record` is not recorded — `start` returns while the
/// capture is still running, so a record claiming an instantaneous step would
/// misrepresent it. The movie in `video/` is the evidence.
struct RecordLocationOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "Run bundle the recording belongs to; the movie lands in <path>/video/. Overrides MTOUCH_RUN_DIR.",
        valueName: "path"
    ))
    var runDir: String?

    mutating func validate() throws {
        if let runDir, runDir.isEmpty {
            throw ValidationError("--run-dir value must not be empty; pass a directory path.")
        }
    }

    private var runDirectory: String? {
        RecordPlan.runDirectory(flag: runDir, environment: ProcessInfo.processInfo.environment)
    }

    /// Where a recording would live, touching NOTHING. `stop` and `status` use
    /// this: asking whether something is recording must not create the bundle it
    /// is asking about.
    func paths(out: String? = nil) -> RecordPaths {
        RecordPlan.paths(
            runDirectory: runDirectory,
            out: out,
            workingDirectory: FileManager.default.currentDirectoryPath
        )
    }

    /// The same paths, with the run bundle created and stamped first — the thing
    /// every other run-aware command does. Only `start` needs it, because only
    /// `start` is about to write a movie into that bundle.
    func preparedPaths(out: String?) throws -> RecordPaths {
        if let runDirectory {
            do {
                _ = try RunBundle.open(path: runDirectory)
            } catch let error as RunBundleError {
                FileHandle.standardError.write(Data((error.diagnostic + "\n").utf8))
                throw ExitCode(MTouchExitCode.runtimeFailure.rawValue)
            }
        }
        return paths(out: out)
    }
}

/// Prints a `RecordOutcome`: stderr notes first (they explain the state the
/// command found), then the stdout line — or the diagnostic and its exit code.
func emit(_ outcome: RecordOutcome) throws {
    switch outcome {
    case let .reported(stdout, notes):
        for note in notes {
            FileHandle.standardError.write(Data((note + "\n").utf8))
        }
        print(stdout)
    case let .failed(stderr, code):
        FileHandle.standardError.write(Data((stderr + "\n").utf8))
        throw ExitCode(code.rawValue)
    }
}

// MARK: - start

struct RecordStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start recording the screen, returning once capture is confirmed live.",
        discussion: """
        Spawns a detached recorder in its own session, so it survives the shell \
        that started it, and waits for it to publish record.json. A non-zero exit \
        means NO recording is running — the recorder's own diagnostic (missing \
        permission, unsupported macOS, unwritable path) is quoted from its log.

        The recorder finalizes and exits on its own after --max-duration even if \
        'record stop' is never issued, so a forgotten recording cannot fill the \
        disk.
        """
    )

    @OptionGroup var location: RecordLocationOptions

    @Option(help: ArgumentHelp(
        "Destination movie path. Defaults to a timestamped .mp4 in the recording directory; "
            + "H.264/MP4 bytes are written regardless of the extension.",
        valueName: "path"
    ))
    var out: String?

    @Option(help: ArgumentHelp(
        "CGDirectDisplayID to record (from 'mtouch doctor'). Omit to record the main display.",
        valueName: "id"
    ))
    var display: UInt32?

    @Option(help: ArgumentHelp(
        "Ceiling after which the recorder finalizes and exits by itself: "
            + "600, 600s, or 500ms (default 10m, maximum 4h).",
        valueName: "duration"
    ))
    var maxDuration: String?

    mutating func validate() throws {
        if let out, out.isEmpty {
            throw ValidationError("--out value must not be empty; pass a file path.")
        }
        if let maxDuration, RecordDuration(parsing: maxDuration) == nil {
            throw ValidationError(RecordDuration.usageMessage(maxDuration))
        }
    }

    mutating func run() throws {
        let duration = maxDuration.flatMap(RecordDuration.init(parsing:)) ?? .default
        let launch = RecordLaunch(
            paths: try location.preparedPaths(out: out), display: display, maxDuration: duration
        )
        try emit(RecordPipeline.start(launch: launch, host: LiveRecordHost()))
    }
}

// MARK: - stop

struct RecordStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the running recording and verify the movie it produced.",
        discussion: """
        Signals the recorder, waits for it to exit, then applies two independent \
        checks. The FILE must exist, be non-empty, carry at least one video \
        track, and have a positive duration. And the RECORDER must have signed \
        off — it stamps the control file only after finalizing and verifying its \
        own output.

        Both are needed. ScreenCaptureKit flushes playable fragments as it \
        records, so a recorder that was killed leaves a movie that passes every \
        file check while holding only part of the run; without the recorder's \
        sign-off that would be reported as a complete recording. Either check \
        failing is exit 1 naming the reason, with the recorder's log quoted.

        With no recording in progress, exits 1 saying so.
        """
    )

    @OptionGroup var location: RecordLocationOptions

    mutating func run() throws {
        try emit(RecordPipeline.stop(paths: location.paths(), host: LiveRecordHost()))
    }
}

// MARK: - status

struct RecordStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether a recording is live here.",
        discussion: """
        Prints the live recording's movie, pid, display, and start time; or that \
        nothing is recording. A control file whose recorder is gone is reported as \
        stale rather than as a live recording. Always exits 0: this is a question, \
        not an assertion.
        """
    )

    @OptionGroup var location: RecordLocationOptions

    mutating func run() throws {
        try emit(RecordPipeline.status(paths: location.paths(), host: LiveRecordHost()))
    }
}
