import Foundation

/// Everything `record start` needs to launch a recorder.
public struct RecordLaunch: Equatable, Sendable {
    public let paths: RecordPaths
    /// `CGDirectDisplayID` to capture, or nil for the main display.
    public let display: UInt32?
    public let maxDuration: RecordDuration

    public init(paths: RecordPaths, display: UInt32?, maxDuration: RecordDuration) {
        self.paths = paths
        self.display = display
        self.maxDuration = maxDuration
    }
}

/// How the start handshake ended. `record start` succeeds on `.live` ONLY — the
/// other three are the ways "a recorder was launched" fails to mean "a recording
/// is happening", and each is reported rather than swallowed.
public enum RecordHandshake: Sendable, Equatable {
    /// The recorder published a control file naming itself: capture is live.
    case live(RecordControl)
    /// The recorder exited before confirming (bad OS version, missing grant,
    /// unwritable path, ScreenCaptureKit refusal…).
    case exited(status: Int32)
    /// Still running but silent past the deadline.
    case timedOut(seconds: Double)
    /// A control file appeared naming a DIFFERENT process — another recorder
    /// raced us for this directory.
    case mismatched(RecordControl)
}

/// The observable outcome of a `record` invocation, kept SEPARATE from the side
/// effects (printing, exiting) so the whole flow is unit-testable — the same
/// shape `ScreenshotPipeline` uses.
///
/// `notes` are stderr lines that accompany a SUCCESS: recovering from a stale
/// control file is not a failure, but it is something an operator must be told.
public enum RecordOutcome: Equatable, Sendable {
    case reported(stdout: String, notes: [String])
    case failed(stderr: String, code: MTouchExitCode)

    public static func reported(_ stdout: String) -> RecordOutcome {
        .reported(stdout: stdout, notes: [])
    }
}

/// The syscall-shaped collaborators `RecordPipeline` needs: the filesystem, the
/// process table, spawning, signalling, and the artifact probe. Isolating them
/// behind one protocol is what lets every DECISION in the pipeline — refuse,
/// recover, verify, fail — be tested without a display, a grant, or a spawn.
public protocol RecordHost {
    func readControl(_ path: String) -> Data?
    func clearControl(_ path: String)
    func identity(of pid: pid_t) -> RecordProcessIdentity
    func createDirectory(_ path: String) -> Result<Void, RecordFailure>
    func launch(_ launch: RecordLaunch) -> Result<pid_t, RecordFailure>
    func awaitHandshake(pid: pid_t, controlPath: String) -> RecordHandshake
    /// Ask `pid` to stop and finalize (SIGTERM). False when the signal could not
    /// be delivered.
    func terminate(pid: pid_t) -> Bool
    /// Wait for `pid` to leave the process table. False on timeout.
    func awaitExit(pid: pid_t) -> Bool
    func verify(movie: String) -> RecordArtifactVerdict
    /// The tail of the detached recorder's log, so a failure that happened after
    /// the parent exited is still readable.
    func logTail(_ path: String) -> String?
}

/// Composes `record start|stop|status` on top of `RecordHost`.
public enum RecordPipeline {
    // MARK: - start

    public static func start(launch: RecordLaunch, host: RecordHost) -> RecordOutcome {
        let paths = launch.paths
        if case let .failure(failure) = host.createDirectory(paths.directory) {
            return .failed(
                stderr: "mtouch: cannot prepare the recording directory \(paths.directory): \(failure.reason)",
                code: .runtimeFailure
            )
        }

        var notes: [String] = []
        switch state(paths: paths, host: host) {
        case .absent:
            break
        case let .live(control):
            return .failed(stderr: alreadyRecording(control, directory: paths.directory), code: .runtimeFailure)
        case let .stale(previous, reason):
            // Recover, but never silently: the previous movie's fate is stated
            // before this one begins, so a crashed recording is not lost in the
            // noise of a successful start.
            notes.append(
                "mtouch: recovered a stale recording control file — \(reason). That recording "
                    + (previous.finishedCleanly ? "had finished" : "never finalized")
                    + "; its movie \(previous.output) \(verdictNote(host.verify(movie: previous.output)))"
            )
            host.clearControl(paths.control)
        case let .damaged(path, reason):
            notes.append("mtouch: replaced a damaged recording control file at \(path) — \(reason).")
            host.clearControl(paths.control)
        }

        let pid: pid_t
        switch host.launch(launch) {
        case let .success(spawned):
            pid = spawned
        case let .failure(failure):
            return .failed(stderr: "mtouch: could not start the recorder: \(failure.reason)", code: .runtimeFailure)
        }

        switch host.awaitHandshake(pid: pid, controlPath: paths.control) {
        case let .live(control):
            return .reported(
                stdout: "recording \(control.output) (pid \(control.pid), display \(control.display), "
                    + "max \(launch.maxDuration.text))",
                notes: notes
            )
        case let .exited(status):
            return .failed(
                stderr: "mtouch: the recorder exited with status \(status) before capture started."
                    + logSuffix(host.logTail(paths.log)),
                code: .runtimeFailure
            )
        case let .timedOut(seconds):
            // The recorder is still alive but never confirmed. Leaving it running
            // would be a process capturing the screen that nothing knows about.
            _ = host.terminate(pid: pid)
            host.clearControl(paths.control)
            return .failed(
                stderr: "mtouch: the recorder (pid \(pid)) did not confirm that capture started within "
                    + "\(JSONText.number(seconds))s; it was stopped."
                    + logSuffix(host.logTail(paths.log)),
                code: .runtimeFailure
            )
        case let .mismatched(control):
            _ = host.terminate(pid: pid)
            return .failed(
                stderr: "mtouch: another recorder (pid \(control.pid)) claimed \(paths.directory) first; "
                    + "the recorder just started was stopped. Only one recording per directory is allowed.",
                code: .runtimeFailure
            )
        }
    }

    // MARK: - stop

    public static func stop(paths: RecordPaths, host: RecordHost) -> RecordOutcome {
        var notes: [String] = []
        let control: RecordControl

        switch state(paths: paths, host: host) {
        case .absent:
            return .failed(
                stderr: "mtouch: no recording is in progress in \(paths.directory) "
                    + "(no \(RecordPlan.controlFileName)).",
                code: .runtimeFailure
            )
        case let .damaged(path, reason):
            return .failed(
                stderr: "mtouch: cannot stop a recording: the control file at \(path) is unreadable — \(reason). "
                    + "'mtouch record start' will replace it.",
                code: .runtimeFailure
            )
        case let .stale(previous, reason):
            // The recorder is gone without having been asked to stop. Whether it
            // finished on its own `--max-duration` or was killed is answered by
            // its countersignature, never by the file — a killed capture is just
            // as playable as a finished one.
            notes.append("mtouch: the recorder had already exited — \(reason).")
            control = previous
        case let .live(running):
            guard host.terminate(pid: running.pid) else {
                return .failed(
                    stderr: "mtouch: could not signal the recorder (pid \(running.pid)) to stop; "
                        + "the recording at \(running.output) is still running.",
                    code: .runtimeFailure
                )
            }
            guard host.awaitExit(pid: running.pid) else {
                // Still alive: the control file stays, because the recording it
                // describes is still real.
                return .failed(
                    stderr: "mtouch: the recorder (pid \(running.pid)) did not exit after being asked to stop; "
                        + "\(running.output) has not been finalized.",
                    code: .runtimeFailure
                )
            }
            // Re-read: the recorder countersigns the control file on its way out,
            // so this is where a finalization that failed after the signal
            // becomes visible.
            control = host.readControl(paths.control).flatMap(RecordControl.parse) ?? running
        }

        // The recorder is gone either way, so the control file has outlived its
        // meaning — cleared before the verdict so a failed verification does not
        // also block the next recording.
        host.clearControl(paths.control)

        let verdict = host.verify(movie: control.output)
        guard control.finishedCleanly else {
            return .failed(
                stderr: interrupted(control, verdict: verdict, log: host.logTail(paths.log)),
                code: .runtimeFailure
            )
        }
        guard let facts = verdict.facts else {
            return .failed(stderr: verdict.diagnostic, code: .runtimeFailure)
        }
        return .reported(
            stdout: "stopped recording \(control.output) (\(RecordArtifactVerdict.factsText(facts)))",
            notes: notes
        )
    }

    /// The diagnostic for a recording whose recorder never countersigned it.
    ///
    /// This is the case the countersignature exists for: ScreenCaptureKit writes
    /// playable fragments as it goes, so the movie left by a recorder that was
    /// killed — or whose stream was torn out from under it — passes every
    /// artifact check while containing only the part of the run that happened to
    /// be flushed. Reporting that as a successful recording would be the worst
    /// failure this feature has: evidence that silently under-reports what it
    /// witnessed.
    ///
    /// The recorder's log is quoted because "killed" and "the capture failed"
    /// leave identical traces on disk, and only the log distinguishes them.
    private static func interrupted(
        _ control: RecordControl,
        verdict: RecordArtifactVerdict,
        log: String?
    ) -> String {
        let head = "mtouch: the recorder (pid \(control.pid)) never finished the recording at "
            + "\(control.output) — it was killed, or its capture failed, so this is NOT a "
            + "complete recording of the run."
        let survived = verdict.facts
            .map { " What survived is playable but partial (\(RecordArtifactVerdict.factsText($0)))." }
            ?? ("\n" + verdict.diagnostic)
        return head + survived + logSuffix(log)
    }

    // MARK: - status

    public static func status(paths: RecordPaths, host: RecordHost) -> RecordOutcome {
        switch state(paths: paths, host: host) {
        case .absent:
            return .reported("not recording (\(paths.directory))")
        case let .live(control):
            return .reported(
                "recording \(control.output) (pid \(control.pid), display \(control.display), "
                    + "started \(RunReportHTML.utcText(control.startedAt)))"
            )
        case let .stale(control, reason):
            let fate = control.finishedCleanly
                ? "a finished recording"
                : "a recording that never finalized"
            return .reported(
                "not recording (\(paths.directory)); a stale control file names \(fate): "
                    + "\(control.output) — \(reason)"
            )
        case let .damaged(path, reason):
            return .reported("not recording (\(paths.directory)); the control file at \(path) is unreadable — \(reason)")
        }
    }

    // MARK: - Internals

    static func state(paths: RecordPaths, host: RecordHost) -> RecordControlState {
        RecordControlStateMachine.state(
            path: paths.control,
            data: host.readControl(paths.control),
            identity: host.identity(of:)
        )
    }

    private static func alreadyRecording(_ control: RecordControl, directory: String) -> String {
        "mtouch: a recording is already in progress in \(directory): \(control.output) "
            + "(pid \(control.pid), started \(RunReportHTML.utcText(control.startedAt))). "
            + "Run 'mtouch record stop' before starting another."
    }

    /// How a recovered stale movie reads inside the start note. Deliberately
    /// states what the file HOLDS rather than calling it good: whether it is a
    /// complete recording is the countersignature's question, not the file's.
    private static func verdictNote(_ verdict: RecordArtifactVerdict) -> String {
        guard let facts = verdict.facts else {
            return "did NOT survive: \(verdict.diagnostic)"
        }
        return "holds \(RecordArtifactVerdict.factsText(facts))."
    }

    private static func logSuffix(_ tail: String?) -> String {
        guard let tail, !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "\nrecorder log:\n" + tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
