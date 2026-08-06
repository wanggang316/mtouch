import Foundation

/// A failure to prepare the trajectory file. Both cases name the offending path so
/// the caller can surface it (mapping to exit 1). It is thrown BEFORE the recorded
/// operation runs, so a bad `MTOUCH_TRAJECTORY` aborts the command rather than
/// performing a silent, unrecorded run.
public enum TrajectoryError: Error, LocalizedError, Equatable {
    /// The configured path already exists and is a directory.
    case pathIsDirectory(String)
    /// The path could not be created/opened for append (parent not writable,
    /// read-only location, …). `reason` carries the underlying system message.
    case notWritable(path: String, reason: String)

    /// Stderr diagnostic, in the project's `mtouch: …` voice.
    public var diagnostic: String {
        switch self {
        case let .pathIsDirectory(path):
            return "mtouch: cannot write trajectory: path is a directory: \(path)"
        case let .notWritable(path, reason):
            return "mtouch: cannot write trajectory to \(path): \(reason)"
        }
    }

    public var errorDescription: String? { diagnostic }
}

/// The single, cross-cutting OBSERVER both the CLI and MCP surfaces route through
/// to record a trajectory. When `MTOUCH_TRAJECTORY` names a usable file, `record`
/// appends exactly one JSONL line describing the call; otherwise it is a pure
/// pass-through. Recording NEVER alters the operation's result, so stdout, stderr,
/// and exit are byte-identical whether or not recording is on (transparency).
///
/// Both surfaces feed the SAME `TrajectoryRecord` model here, so a CLI command and
/// its MCP tool shape identically (parity). The only per-surface differences are
/// how `args`/`kind` are derived and how the native result maps to a
/// `TrajectoryOutcomeInfo` — both small closures the caller supplies.
public enum TrajectoryRecorder {
    /// Payload-bearing keyboard keys stripped from a FAILED/refused record, so a
    /// secure-input refusal (or any other failed `type`/`key`) records the event
    /// but never the typed text/combo (a possible password).
    private static let secretKeys: Set<String> = ["text", "combo"]

    /// Run `operation` and, when recording is on, append one record for it.
    ///
    /// - Recording off (`MTOUCH_TRAJECTORY` unset/empty): returns `operation()`
    ///   verbatim, touching no files and never throwing.
    /// - Recording on but the path is unusable (a directory, or an
    ///   uncreatable/unwritable parent): THROWS `TrajectoryError` BEFORE running
    ///   `operation`, so the caller aborts (exit 1) instead of a silent run.
    /// - Recording on and usable: reads the pre-digest (for `.action`), runs
    ///   `operation`, reads the post-digest, and appends the shaped line.
    public static func record<Outcome>(
        command: String,
        args: TrajectoryArgs,
        kind: TrajectoryKind,
        environment: [String: String],
        operation: () -> Outcome,
        describe: (Outcome) -> TrajectoryOutcomeInfo,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) throws -> Outcome {
        guard let path = environment[MTouchEnvironment.trajectoryKey], !path.isEmpty else {
            // Recording off: pure pass-through, zero file work, zero throws.
            return operation()
        }

        // Prepare the file BEFORE running the operation so an unusable path aborts
        // the command (exit 1) rather than a silent unrecorded run. The fd stays
        // open across the operation and its single-write append.
        let fd = try openForAppend(path)
        defer { close(fd) }

        let sessionPath = SessionStore.sessionFilePath(environment: environment)
        let preDigest = (kind == .action) ? sessionDigest(sessionPath) : nil
        let timestamp = now()

        let outcome = operation()
        let info = describe(outcome)

        let postDigest = (kind == .action) ? sessionDigest(sessionPath) : nil
        // A snapshot's digest is the tree it just persisted; only meaningful when
        // the snapshot succeeded.
        let snapshotDigest = (kind == .snapshot && info.ok) ? sessionDigest(sessionPath) : nil

        // Secret-safety: a failed/refused type/key never records its payload.
        let safeArgs = info.ok ? args : args.removing(secretKeys)

        let record = TrajectoryRecord(
            command: command,
            timestamp: timestamp,
            args: safeArgs,
            ok: info.ok,
            exit: info.exit,
            errorClass: info.errorClass,
            preDigest: preDigest,
            postDigest: postDigest,
            digest: snapshotDigest,
            diff: kind == .action ? info.diff : nil,
            screenshotPath: kind == .screenshot ? info.screenshotPath : nil
        )
        try appendLine(record.jsonLine(), to: fd, path: path)
        return outcome
    }

    // MARK: - File handling

    /// The current tree digest persisted at `sessionPath`, or nil when there is no
    /// (readable) session. Reused for pre/post/snapshot digests.
    private static func sessionDigest(_ sessionPath: String) -> String? {
        SessionStore.load(from: sessionPath)?.digest
    }

    /// Validate the path and open it for appending, creating missing parents. An
    /// existing FILE is opened for append (prior sessions preserved, never
    /// truncated). Throws `TrajectoryError` for a directory path or an
    /// uncreatable/unwritable location.
    private static func openForAppend(_ path: String) throws -> Int32 {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            throw TrajectoryError.pathIsDirectory(path)
        }

        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            } catch {
                throw TrajectoryError.notWritable(path: path, reason: message(for: error))
            }
        }

        // O_APPEND (no O_TRUNC): every write lands atomically at end-of-file, and
        // an existing file keeps its prior lines. 0644 mirrors the session store.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw TrajectoryError.notWritable(path: path, reason: String(cString: strerror(errno)))
        }
        return fd
    }

    /// Append the record as ONE `write(2)` of the complete `<json>\n` buffer. On a
    /// file opened O_APPEND this is atomic on macOS, so a crash mid-session leaves
    /// every completed line intact (at most a final truncated line) and concurrent
    /// writers to the same file never interleave partial lines.
    private static func appendLine(_ line: String, to fd: Int32, path: String) throws {
        let data = Data(line.utf8)
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
            return write(fd, base, buffer.count)
        }
        guard written == data.count else {
            let reason = written < 0 ? String(cString: strerror(errno)) : "short write (\(written)/\(data.count) bytes)"
            throw TrajectoryError.notWritable(path: path, reason: reason)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    }
}
