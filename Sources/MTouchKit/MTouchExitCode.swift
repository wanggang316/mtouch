/// Exit-code taxonomy shared by every `mtouch` subcommand.
///
/// Usage errors (unknown subcommand, missing required flag, empty `--app`)
/// use 64 to match `EX_USAGE` and swift-argument-parser's validation exit.
public enum MTouchExitCode: Int32, Sendable, CaseIterable {
    case success = 0
    case runtimeFailure = 1
    case permissionMissing = 2
    case refError = 3
    case waitTimeout = 4
    case secureInput = 5
    case usageError = 64
}

/// An error that already knows BOTH how it reads on stderr and which exit code it
/// carries, so every pipeline maps it the same way instead of re-deciding per call
/// site. Target-resolution failures (app not running, an ambiguous bundle id, a
/// `--pid` that names no process or contradicts `--app`) all travel through the
/// pipelines' injected `resolvePID` seam, and they do NOT share one exit code — a
/// self-contradictory invocation is a usage error (64) while a missing target is a
/// runtime failure (1). Conforming lets the seam stay `(String) throws -> pid_t`.
public protocol MTouchDiagnosticError: Error {
    /// Actionable stderr line, already prefixed with `mtouch: `.
    var message: String { get }
    var exitCode: MTouchExitCode { get }
}
