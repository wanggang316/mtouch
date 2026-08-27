import ArgumentParser
import Foundation
import MTouchKit

// MARK: - Shared --app option groups

/// Help for `--pid`, shared by both groups: it is the disambiguator for a bundle
/// id that names several live processes, which `--app` alone cannot express.
private let pidHelp = ArgumentHelp(
    "Process id of the target instance. Overrides bundle-id resolution; required when "
        + "several running processes share the bundle id ('mtouch apps' lists them).",
    valueName: "pid"
)

struct RequiredAppOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Bundle identifier of the target application.", valueName: "bundleId"))
    var app: String

    @Option(help: pidHelp)
    var pid: pid_t?

    mutating func validate() throws {
        guard !app.isEmpty else {
            throw ValidationError("--app value must not be empty; pass a bundle identifier such as 'com.apple.Safari'.")
        }
    }
}

struct OptionalAppOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Bundle identifier of the target application.", valueName: "bundleId"))
    var app: String?

    @Option(help: pidHelp)
    var pid: pid_t?

    mutating func validate() throws {
        if let app, app.isEmpty {
            throw ValidationError("--app value must not be empty; pass a bundle identifier such as 'com.apple.Safari'.")
        }
        // A pid with no bundle id to check it against would have to be trusted
        // blindly, so it is refused at parse time (exit 64) rather than silently
        // ignored — the same "refuse, do not guess" rule the resolver applies.
        if pid != nil, app == nil {
            throw ValidationError(AppTarget.pidRequiresAppMessage)
        }
    }
}

// MARK: - Shared run-bundle options

/// `--run-dir` / `--capture`, offered by EVERY recorded command so a whole
/// sequence of invocations can be pointed at one evidence bundle without
/// exporting anything into the shell.
///
/// Each flag is the per-invocation equivalent of its environment variable and
/// WINS over it, the same "explicit beats implicit" rule `MTOUCH_TRAJECTORY`
/// follows against the bundle's own stream.
struct RunOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "Directory of the run evidence bundle this command appends to; created if missing. "
            + "Overrides MTOUCH_RUN_DIR.",
        valueName: "path"
    ))
    var runDir: String?

    @Flag(help: ArgumentHelp(
        "Also capture screenshots into the run bundle around this command (same as "
            + "MTOUCH_RUN_CAPTURE=1). Off by default: a capture costs real time per action."
    ))
    var capture = false

    mutating func validate() throws {
        if let runDir, runDir.isEmpty {
            throw ValidationError("--run-dir value must not be empty; pass a directory path.")
        }
        // --capture with nowhere to put the captures would be a silent no-op, and a
        // silent no-op in an evidence system is exactly the failure mode this
        // feature exists to prevent.
        if capture, runDir == nil, (ProcessInfo.processInfo.environment[MTouchEnvironment.runDirKey] ?? "").isEmpty {
            throw ValidationError(
                "--capture needs a run bundle to capture into; pass --run-dir <path> or set MTOUCH_RUN_DIR."
            )
        }
    }

    /// The environment the recorder sees: the inherited one with these flags
    /// layered over it.
    func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var merged = base
        if let runDir { merged[MTouchEnvironment.runDirKey] = runDir }
        if capture { merged[MTouchEnvironment.runCaptureKey] = "1" }
        return merged
    }
}

// MARK: - Argument conversions for MTouchKit value types

extension ScreenPoint: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(parsing: argument)
    }
}

extension WaitDuration: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(parsing: argument)
    }
}

// MARK: - Permission preflight mapping

/// Runs a `Preflight` requirement, mapping a `PermissionError` to its pinned
/// stderr diagnostic and exit code 2. Permission-gated commands (windows,
/// snapshot, act, wait, screenshot) call this verbatim before touching the
/// gated API, e.g. `preflightOrExit(Preflight.requireAccessibility)`.
func preflightOrExit(_ requirement: (PermissionProvider) throws -> Void,
                     provider: PermissionProvider = LivePermissionProvider()) {
    do {
        try requirement(provider)
    } catch let error as PermissionError {
        FileHandle.standardError.write(Data((error.diagnostic + "\n").utf8))
        exit(MTouchExitCode.permissionMissing.rawValue)
    } catch {
        FileHandle.standardError.write(Data("mtouch: preflight failed: \(error)\n".utf8))
        exit(MTouchExitCode.runtimeFailure.rawValue)
    }
}

// MARK: - Trajectory recording

/// Run `operation` under `TrajectoryRecorder`, mapping its result to a record via
/// `describe`, and return the result UNCHANGED so the command's stdout/stderr/exit
/// stay byte-identical whether or not recording is on. An unusable trajectory path
/// (a directory, or an uncreatable/unwritable parent) or an unusable run directory
/// (a file, or an uncreatable/unwritable parent) writes the pinned diagnostic to
/// stderr and aborts with exit 1 BEFORE the operation — never a silent unrecorded
/// run.
func recorded<Outcome>(
    command: String,
    args: TrajectoryArgs,
    kind: TrajectoryKind,
    run: RunOptions,
    describe: (Outcome) -> TrajectoryOutcomeInfo,
    _ operation: () -> Outcome
) throws -> Outcome {
    do {
        return try TrajectoryRecorder.record(
            command: command,
            args: args,
            kind: kind,
            environment: run.environment(),
            operation: operation,
            describe: describe
        )
    } catch let error as TrajectoryError {
        FileHandle.standardError.write(Data((error.diagnostic + "\n").utf8))
        throw ExitCode(MTouchExitCode.runtimeFailure.rawValue)
    } catch let error as RunBundleError {
        FileHandle.standardError.write(Data((error.diagnostic + "\n").utf8))
        throw ExitCode(MTouchExitCode.runtimeFailure.rawValue)
    }
}

// MARK: - Stub exit

/// Placeholder body for subcommands whose behavior lands in later features.
func stubExit(_ commandPath: String) -> Never {
    FileHandle.standardError.write(Data("mtouch: \(commandPath): not implemented\n".utf8))
    exit(MTouchExitCode.runtimeFailure.rawValue)
}
