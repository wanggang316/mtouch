import Darwin
import Foundation

/// The live `RecordHost`: real files, real processes, real signals.
///
/// The one genuinely delicate part is the spawn. A recorder must OUTLIVE the
/// `record start` that created it, and a plain child shares its parent's session
/// — so it dies with the terminal, or with the agent that ran the command. This
/// spawns with `POSIX_SPAWN_SETSID`, which puts the recorder in a session of its
/// own with no controlling terminal, and redirects its output to a log file so a
/// failure occurring after the parent exits is still readable.
public struct LiveRecordHost: RecordHost {
    /// How long `record start` waits for the recorder's handshake. Comfortably
    /// above the recorder's own internal deadlines, so a recorder that fails
    /// reports its OWN reason (via exit status + log) instead of being masked by
    /// a timeout here.
    public static let handshakeTimeout: TimeInterval = 45
    /// How long `record stop` waits for a signalled recorder to exit. Finalizing
    /// a long movie and verifying it takes a moment.
    public static let exitTimeout: TimeInterval = 45
    static let pollInterval: TimeInterval = 0.05

    /// Absolute path of the `mtouch` binary to re-exec as the recorder.
    public let executable: String

    public init(executable: String = LiveRecordHost.currentExecutablePath()) {
        self.executable = executable
    }

    /// This process's own resolved binary path — the same source the recorder
    /// stamps into its control file, so the two always agree.
    public static func currentExecutablePath() -> String {
        LiveProcessProbe.executablePath(of: getpid())
            ?? Bundle.main.executablePath
            ?? CommandLine.arguments.first
            ?? "mtouch"
    }

    // MARK: - Files

    public func readControl(_ path: String) -> Data? { RecordControlStore.read(path) }

    public func clearControl(_ path: String) { RecordControlStore.clear(path) }

    public func createDirectory(_ path: String) -> Result<Void, RecordFailure> {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return .success(())
        } catch {
            return .failure(RecordFailure((error as NSError).localizedDescription))
        }
    }

    public func logTail(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(20).joined(separator: "\n")
    }

    // MARK: - Processes

    public func identity(of pid: pid_t) -> RecordProcessIdentity { LiveProcessProbe.identity(of: pid) }

    public func terminate(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        // Already gone counts as terminated: the caller's goal is "not running".
        return kill(pid, SIGTERM) == 0 || errno == ESRCH
    }

    public func awaitExit(pid: pid_t) -> Bool {
        let deadline = Date(timeIntervalSinceNow: LiveRecordHost.exitTimeout)
        while Date() < deadline {
            if case .gone = identity(of: pid) { return true }
            Thread.sleep(forTimeInterval: LiveRecordHost.pollInterval)
        }
        if case .gone = identity(of: pid) { return true }
        return false
    }

    public func verify(movie: String) -> RecordArtifactVerdict { RecordArtifact.verify(path: movie) }

    // MARK: - Spawning

    public func launch(_ launch: RecordLaunch) -> Result<pid_t, RecordFailure> {
        var arguments = [
            executable,
            RecordRunCommand.name,
            "--out", launch.paths.movie,
            "--control", launch.paths.control,
            "--max-duration", JSONText.number(launch.maxDuration.seconds),
        ]
        if let display = launch.display {
            arguments.append(contentsOf: ["--display", String(display)])
        }
        return spawnDetached(arguments: arguments, log: launch.paths.log)
    }

    /// `posix_spawn` into a NEW SESSION with stdin on /dev/null and
    /// stdout+stderr on the log file.
    func spawnDetached(arguments: [String], log: String) -> Result<pid_t, RecordFailure> {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            return .failure(RecordFailure("posix_spawnattr_init: \(String(cString: strerror(errno)))"))
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // POSIX_SPAWN_SETSID: the recorder becomes a session leader with no
        // controlling terminal, so closing the shell that started it does not
        // deliver SIGHUP and kill the capture.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            return .failure(RecordFailure("posix_spawn_file_actions_init: \(String(cString: strerror(errno)))"))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &fileActions, &attributes, &argv, environ)
        guard status == 0 else {
            return .failure(RecordFailure("\(executable): \(String(cString: strerror(status)))"))
        }
        return .success(pid)
    }

    // MARK: - Handshake

    /// Polls for the control file until it names `pid`, the recorder exits, or
    /// the deadline passes.
    ///
    /// The recorder is still this process's direct child at this point, so its
    /// exit is observable with `waitpid` — which is how a recorder that refuses
    /// to run (unsupported OS, missing grant, unwritable path) is reported as its
    /// own failure rather than as a timeout.
    public func awaitHandshake(pid: pid_t, controlPath: String) -> RecordHandshake {
        let deadline = Date(timeIntervalSinceNow: LiveRecordHost.handshakeTimeout)
        while Date() < deadline {
            if let data = readControl(controlPath), let control = RecordControl.parse(data) {
                return control.pid == pid ? .live(control) : .mismatched(control)
            }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                // One last look: the control file may have landed in the same
                // instant the recorder was reaped.
                if let data = readControl(controlPath), let control = RecordControl.parse(data), control.pid == pid {
                    return .live(control)
                }
                return .exited(status: LiveRecordHost.exitStatus(status))
            }
            Thread.sleep(forTimeInterval: LiveRecordHost.pollInterval)
        }
        return .timedOut(seconds: LiveRecordHost.handshakeTimeout)
    }

    /// The child's exit code, or `128 + signal` when it was killed — the shell
    /// convention, so the number in the diagnostic is one an operator recognises.
    static func exitStatus(_ raw: Int32) -> Int32 {
        if raw & 0x7F == 0 { return (raw >> 8) & 0xFF }
        return 128 + (raw & 0x7F)
    }
}
