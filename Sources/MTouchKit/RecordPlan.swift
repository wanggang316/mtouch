import Foundation

/// The ceiling a recorder self-terminates at.
///
/// This is a SAFETY property, not a convenience: a recorder that lost its
/// operator — the shell exited, the agent crashed, `stop` was never issued —
/// must not keep writing until the disk is full. It finalizes at the ceiling and
/// exits, leaving a playable, signed-off movie behind.
///
/// The ceiling is measured on the MONOTONIC clock, so neither a wall-clock
/// adjustment nor time the machine spent asleep can move it.
///
/// The grammar is `WaitDuration`'s (`600`, `600s`, `500ms`), so the whole CLI
/// parses durations one way. Zero is rejected here even though `WaitDuration`
/// accepts it: a zero-length recording is never what was meant.
public struct RecordDuration: Equatable, Sendable {
    /// Ten minutes: long enough for a realistic agent session, short enough that
    /// a leaked recorder is bounded.
    public static let `default` = RecordDuration(seconds: 600)
    /// Below a second there is nothing to finalize.
    public static let minimumSeconds: Double = 1
    /// Four hours. Past this a "recording" is a disk-filling accident.
    public static let maximumSeconds: Double = 4 * 60 * 60

    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    /// Parse and bounds-check. Nil for anything malformed, non-finite, negative,
    /// shorter than a second, or longer than the ceiling — each a usage error
    /// (exit 64) BEFORE a recorder is spawned.
    public init?(parsing raw: String) {
        guard let parsed = WaitDuration(parsing: raw),
              parsed.seconds >= RecordDuration.minimumSeconds,
              parsed.seconds <= RecordDuration.maximumSeconds
        else { return nil }
        self.init(seconds: parsed.seconds)
    }

    /// The monotonic instant this recording must be finalized at.
    public func deadline(startingAt monotonic: Double) -> Double {
        monotonic + seconds
    }

    /// Whether a recording started at `start` has reached its ceiling. Both
    /// arguments are MONOTONIC (`systemUptime`), so a wall-clock adjustment can
    /// neither cut a recording short nor let it overrun.
    public func isExpired(startedAt start: Double, now: Double) -> Bool {
        now >= deadline(startingAt: start)
    }

    /// Compact human form for diagnostics: `10m`, `1h30m`, `45s`, `2m30s`.
    public var text: String {
        let total = Int(seconds.rounded())
        guard total > 0 else { return "0s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        var out = ""
        if hours > 0 { out += "\(hours)h" }
        if minutes > 0 { out += "\(minutes)m" }
        if rest > 0 || out.isEmpty { out += "\(rest)s" }
        return out
    }

    /// The usage diagnostic for a rejected `--max-duration`, naming the bounds.
    public static func usageMessage(_ raw: String) -> String {
        "--max-duration value '\(raw)' is not a duration between "
            + "\(RecordDuration(seconds: minimumSeconds).text) and \(RecordDuration(seconds: maximumSeconds).text); "
            + "pass a value like 600, 600s, or 90s."
    }
}

/// The hidden, BLOCKING recorder subcommand that `record start` re-execs. Named
/// here rather than in the CLI target so the spawn and the parser can never
/// drift apart.
public enum RecordRunCommand {
    public static let name = "__record-run"
}

/// Where a recording's three files live.
///
/// They sit TOGETHER in one directory so `stop` and `status` can find a
/// recording from the same inputs `start` was given, without being told a path.
public struct RecordPaths: Equatable, Sendable {
    /// Directory holding the control file, the recorder log, and (by default)
    /// the movie.
    public let directory: String
    /// `record.json` — the handshake artifact.
    public let control: String
    /// `record.log` — the detached recorder's stdout+stderr, so a failure that
    /// happened after the parent exited is still readable.
    public let log: String
    /// The movie a `start` would write. `stop` and `status` ignore it: a
    /// recording in progress names its OWN movie in the control file, which is
    /// the only path that can be trusted after the fact.
    public let movie: String

    public init(directory: String, control: String, log: String, movie: String) {
        self.directory = directory
        self.control = control
        self.log = log
        self.movie = movie
    }
}

/// Resolves what `record start|stop|status` operate on. Pure over its inputs (an
/// environment, the flags, a working directory, a clock), so the run-bundle
/// integration and the default naming are testable without a filesystem.
public enum RecordPlan {
    public static let controlFileName = "record.json"
    public static let logFileName = "record.log"

    /// The run directory in force: `--run-dir` WINS over `MTOUCH_RUN_DIR`, the
    /// same "explicit beats implicit" rule the rest of the CLI follows. Empty
    /// values count as unset.
    public static func runDirectory(flag: String?, environment: [String: String]) -> String? {
        if let flag, !flag.isEmpty { return flag }
        guard let fromEnvironment = environment[MTouchEnvironment.runDirKey], !fromEnvironment.isEmpty else {
            return nil
        }
        return fromEnvironment
    }

    /// Where a recording lives.
    ///
    /// With a run bundle it is `<run>/video/`, so `mtouch report` finds the movie
    /// with no extra flags. Without one it is the working directory, which keeps
    /// the state VISIBLE — a hidden per-user control file would leave an operator
    /// unable to see, or clean up, a recording they started.
    public static func directory(runDirectory: String?, workingDirectory: String) -> String {
        if let runDirectory {
            return RunBundle(root: URL(fileURLWithPath: runDirectory).path).videoDirectory
        }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true).path
    }

    public static func paths(
        runDirectory: String?,
        out: String?,
        workingDirectory: String,
        now: Date = Date(),
        unique: () -> String = { String(UUID().uuidString.prefix(8)) }
    ) -> RecordPaths {
        let directory = directory(runDirectory: runDirectory, workingDirectory: workingDirectory)
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        return RecordPaths(
            directory: directory,
            control: root.appendingPathComponent(controlFileName).path,
            log: root.appendingPathComponent(logFileName).path,
            movie: movie(out: out, directory: directory, now: now, unique: unique)
        )
    }

    /// A non-empty `--out` is honoured VERBATIM; otherwise a timestamped,
    /// collision-proof `.mp4` lands in the record directory — the same rule
    /// `screenshot` uses for its PNGs, so the two artifacts read alike.
    static func movie(
        out: String?,
        directory: String,
        now: Date,
        unique: () -> String
    ) -> String {
        if let out, !out.isEmpty { return out }
        let name = "mtouch-recording-\(ScreenCapturePath.timestamp(now))-\(unique()).mp4"
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name).path
    }
}
