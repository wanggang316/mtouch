import ArgumentParser
import Foundation
import MTouchKit

// MARK: - Shared --app option groups

struct RequiredAppOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Bundle identifier of the target application.", valueName: "bundleId"))
    var app: String

    mutating func validate() throws {
        guard !app.isEmpty else {
            throw ValidationError("--app value must not be empty; pass a bundle identifier such as 'com.apple.Safari'.")
        }
    }
}

struct OptionalAppOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Bundle identifier of the target application.", valueName: "bundleId"))
    var app: String?

    mutating func validate() throws {
        if let app, app.isEmpty {
            throw ValidationError("--app value must not be empty; pass a bundle identifier such as 'com.apple.Safari'.")
        }
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
/// stay byte-identical whether or not `MTOUCH_TRAJECTORY` is set. An unusable
/// trajectory path (a directory, or an uncreatable/unwritable parent) writes the
/// pinned diagnostic to stderr and aborts with exit 1, mirroring the CLI's other
/// fail-fast diagnostics — never a silent unrecorded run.
func recorded<Outcome>(
    command: String,
    args: TrajectoryArgs,
    kind: TrajectoryKind,
    describe: (Outcome) -> TrajectoryOutcomeInfo,
    _ operation: () -> Outcome
) throws -> Outcome {
    do {
        return try TrajectoryRecorder.record(
            command: command,
            args: args,
            kind: kind,
            environment: ProcessInfo.processInfo.environment,
            operation: operation,
            describe: describe
        )
    } catch let error as TrajectoryError {
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
