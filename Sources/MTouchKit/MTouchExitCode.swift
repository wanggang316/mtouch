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
