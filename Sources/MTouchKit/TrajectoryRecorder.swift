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
    /// Payload-bearing arg keys stripped from a FAILED/refused record, so the
    /// event is recorded but its secret payload is not. Covers the keyboard verbs
    /// (`type`/`key` → `text`/`combo`) AND `set-value`'s `value`, which bypasses
    /// the secure-input gate: without this a failed `set-value <secret>` would
    /// persist the secret plaintext. Stripped only on failure — a SUCCESSFUL
    /// set-value's value change is legitimately observable.
    private static let secretKeys: Set<String> = ["text", "combo", "value"]

    /// Run `operation` and, when recording is on, append one record for it.
    ///
    /// - Recording off (no `MTOUCH_TRAJECTORY` and no `MTOUCH_RUN_DIR`): returns
    ///   `operation()` verbatim, touching no files and never throwing.
    /// - Recording on but the trajectory path or the run directory is unusable:
    ///   THROWS (`TrajectoryError` / `RunBundleError`) BEFORE running `operation`,
    ///   so the caller aborts (exit 1) instead of a silent unrecorded run.
    /// - Recording on and usable: claims a step in the run bundle (if any), takes
    ///   the opt-in "before" capture, reads the pre-digest (for `.action`), runs
    ///   `operation`, takes the "after" capture, reads the post-digest, and
    ///   appends the shaped line.
    ///
    /// `MTOUCH_RUN_DIR` alone is enough to turn recording on: the bundle's own
    /// `trajectory.jsonl` becomes the stream. An explicitly set `MTOUCH_TRAJECTORY`
    /// still WINS over it — explicit beats implicit — in which case the bundle
    /// still numbers the steps and collects the screenshots, and the records
    /// naming them land in the operator's chosen file.
    public static func record<Outcome>(
        command: String,
        args: TrajectoryArgs,
        kind: TrajectoryKind,
        environment: [String: String],
        operation: () -> Outcome,
        describe: (Outcome) -> TrajectoryOutcomeInfo,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        wallNow: () -> Double = { Date().timeIntervalSince1970 },
        capture: RunCapturing = LiveRunCapture()
    ) throws -> Outcome {
        // Prepare the bundle BEFORE anything else: an unusable run directory must
        // abort the command rather than let it run undocumented.
        let run = try RunBundle.resolve(environment: environment, now: now, wallNow: wallNow)

        guard let path = trajectoryPath(environment: environment, run: run) else {
            // Recording off: pure pass-through, zero file work, zero throws.
            return operation()
        }

        // Prepare the file BEFORE running the operation so an unusable path aborts
        // the command (exit 1) rather than a silent unrecorded run. The fd stays
        // open across the operation and its single-write append.
        let fd = try openForAppend(path)
        defer { close(fd) }

        // Claim the step ordinal under the bundle's lock, also before the
        // operation, so concurrent commands can never share a number.
        let step = try run?.allocateStep(command: command)
        let capturing = run != nil && RunBundle.captureEnabled(environment: environment)
        var evidence = RunEvidence()
        if capturing, let run, let step, let slot = preSlot(for: kind) {
            collect(into: &evidence, run: run, step: step, slot: slot, capture: capture)
        }

        let sessionPath = SessionStore.sessionFilePath(environment: environment)
        let preDigest = (kind == .action) ? sessionDigest(sessionPath) : nil
        let timestamp = now()
        let wallClock = wallNow()

        let outcome = operation()
        let info = describe(outcome)

        if capturing, let run, let step, let slot = postSlot(for: kind) {
            collect(into: &evidence, run: run, step: step, slot: slot, capture: capture)
        }

        let postDigest = (kind == .action) ? sessionDigest(sessionPath) : nil
        // A snapshot's digest is the tree it just persisted; only meaningful when
        // the snapshot succeeded.
        let snapshotDigest = (kind == .snapshot && info.ok) ? sessionDigest(sessionPath) : nil

        // Secret-safety: a failed/refused type/key never records its payload.
        let safeArgs = info.ok ? args : args.removing(secretKeys)

        let record = TrajectoryRecord(
            command: command,
            timestamp: timestamp,
            wallClock: wallClock,
            args: safeArgs,
            ok: info.ok,
            exit: info.exit,
            errorClass: info.errorClass,
            preDigest: preDigest,
            postDigest: postDigest,
            digest: snapshotDigest,
            diff: kind == .action ? info.diff : nil,
            screenshotPath: kind == .screenshot ? info.screenshotPath : nil,
            step: step?.index,
            evidence: evidence.isEmpty ? nil : evidence
        )
        try appendLine(record.jsonLine(), to: fd, path: path)
        return outcome
    }

    // MARK: - Run bundle wiring

    /// The stream to append to: an explicitly set `MTOUCH_TRAJECTORY` first, then
    /// the run bundle's own `trajectory.jsonl`, then nil (recording off).
    static func trajectoryPath(environment: [String: String], run: RunBundle?) -> String? {
        if let explicit = environment[MTouchEnvironment.trajectoryKey], !explicit.isEmpty {
            return explicit
        }
        return run?.trajectoryPath
    }

    /// The capture taken BEFORE the operation: only a MUTATING command has a
    /// "before" worth keeping, since only it changes what is on screen.
    private static func preSlot(for kind: TrajectoryKind) -> RunStepSlot? {
        kind == .action ? .before : nil
    }

    /// The capture taken AFTER the operation. A mutating command closes its
    /// bracket with `.after`; a read-only command has nothing to bracket, so it
    /// takes ONE capture — `.state`, the screen as the command left it, which for
    /// a `wait` is the state that finally satisfied the condition. A `screenshot`
    /// command IS its own evidence — its record already names the PNG it wrote —
    /// so it takes none.
    private static func postSlot(for kind: TrajectoryKind) -> RunStepSlot? {
        switch kind {
        case .action: return .after
        case .snapshot, .read: return .state
        case .screenshot: return nil
        }
    }

    /// Capture one slot and fold the result — a relative path, or the reason there
    /// is none — into `evidence`. Never throws and never alters the operation.
    private static func collect(
        into evidence: inout RunEvidence,
        run: RunBundle,
        step: RunStep,
        slot: RunStepSlot,
        capture: RunCapturing
    ) {
        switch capture.capturePNG() {
        case let .success(data):
            switch run.writeStepImage(data, step: step, slot: slot) {
            case let .success(relative): evidence[slot] = relative
            case let .failure(failure): evidence.note(failure: failure.diagnostic, slot: slot)
            }
        case let .failure(failure):
            evidence.note(failure: failure.diagnostic, slot: slot)
        }
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

    /// Append the record's complete `<json>\n` buffer to the O_APPEND fd both
    /// ATOMICALLY and COMPLETELY, so the file is always fully `jq -c .`-parseable.
    ///
    /// Both halves of that guarantee come from `LockedFile`, which a run bundle's
    /// step counter shares so the two multi-process writers cannot drift:
    ///
    ///   - An advisory exclusive lock is held for the whole append. This
    ///     serializes concurrent recorders, so a large record that needs more than
    ///     one `write(2)` (a big `diff` can exceed the kernel's atomic-append size)
    ///     cannot interleave with another writer and tear a line.
    ///   - The `write(2)` is looped until the entire buffer is out, so a
    ///     short/interrupted write completes rather than leaving a torn line.
    ///
    /// A crash mid-session still leaves every completed line intact (at most a final
    /// truncated line). A genuinely unusable fd surfaces as `notWritable` (exit 1).
    private static func appendLine(_ line: String, to fd: Int32, path: String) throws {
        do {
            try LockedFile.withExclusiveLock(fd) {
                try LockedFile.writeAll(Data(line.utf8), to: fd)
            }
        } catch let failure as FileIOFailure {
            throw TrajectoryError.notWritable(path: path, reason: failure.reason)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    }
}
