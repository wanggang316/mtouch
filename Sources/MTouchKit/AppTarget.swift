import AppKit
import Foundation

/// Raised when `--pid <pid>` names a process that is not running. Paired with
/// exit 1 (`MTouchExitCode.runtimeFailure`): the target is simply absent.
public struct PidNotRunningError: MTouchDiagnosticError, Equatable, Sendable {
    public let pid: pid_t

    public init(pid: pid_t) {
        self.pid = pid
    }

    public var message: String {
        "mtouch: no running application with pid \(pid). "
            + "Run 'mtouch apps' to list running applications with their pids."
    }

    public var exitCode: MTouchExitCode { .runtimeFailure }
}

/// Raised when `--pid <pid>` names a RUNNING process whose bundle id is not the
/// one `--app` asked for. Paired with exit 64 (`MTouchExitCode.usageError`): the
/// invocation contradicts itself, so no target can be correct — this is a
/// malformed request, not a missing app.
public struct PidBundleMismatchError: MTouchDiagnosticError, Equatable, Sendable {
    public let pid: pid_t
    /// The bundle id `--app` asked for.
    public let requested: String
    /// The bundle id the process actually has, nil when it has none.
    public let actual: String?

    public init(pid: pid_t, requested: String, actual: String?) {
        self.pid = pid
        self.requested = requested
        self.actual = actual
    }

    /// States BOTH values, so the caller can see which half of its own request was
    /// wrong without running another command.
    public var message: String {
        let identity = actual.map { "is '\($0)'" } ?? "has no bundle identifier"
        return "mtouch: --pid \(pid) \(identity), but --app says '\(requested)'. "
            + "Pass a pid belonging to that application, or drop --pid; 'mtouch apps' lists both."
    }

    public var exitCode: MTouchExitCode { .usageError }
}

/// Identity of a running process as far as targeting cares. Absent (`nil` in place
/// of the whole value) means no such process; a present value with a nil
/// `bundleId` means a running process that has none.
public struct ProcessIdentity: Equatable, Sendable {
    public let bundleId: String?

    public init(bundleId: String?) {
        self.bundleId = bundleId
    }
}

/// Resolves WHICH process a command targets, honoring an explicit `--pid`
/// override over bundle-id resolution.
///
/// It produces the `(String) throws -> pid_t` closure the pipelines already accept
/// as their `resolvePID` seam, so adding `--pid` needs no pipeline signature
/// change: the CLI and MCP surfaces build the closure and hand it over, and every
/// pipeline maps the thrown `MTouchDiagnosticError` to the same stderr + exit code.
public enum AppTarget {
    /// The pinned refusal when `--pid` arrives without `--app`. A pid alone would
    /// have to be trusted blindly; requiring `--app` keeps the pid checkable
    /// against the application it must belong to.
    public static let pidRequiresAppMessage =
        "--pid requires --app: pass '--app <bundleId> --pid <pid>' so the pid can be "
            + "checked against the application it must belong to."

    /// The pid-resolution seam for a command. Without an override this is today's
    /// bundle-id resolution (which now refuses an ambiguous match); with one, the
    /// pid WINS and is validated against `--app`.
    public static func resolver(pid override: pid_t?) -> (String) throws -> pid_t {
        { bundleId in
            guard let override else {
                return try AXWindowEnumerator.resolveRunningPID(bundleId: bundleId)
            }
            return try validate(pid: override, bundleId: bundleId, identity: liveIdentity(of: override))
        }
    }

    /// Pure validation of an explicit pid against the requested bundle id, so both
    /// refusals are testable without a live process:
    ///   - no such process        -> exit 1, naming the pid;
    ///   - running, wrong bundle  -> exit 64, naming both values.
    public static func validate(pid: pid_t, bundleId: String, identity: ProcessIdentity?) throws -> pid_t {
        guard let identity else { throw PidNotRunningError(pid: pid) }
        guard let actual = identity.bundleId,
              actual.caseInsensitiveCompare(bundleId) == .orderedSame else {
            throw PidBundleMismatchError(pid: pid, requested: bundleId, actual: identity.bundleId)
        }
        return pid
    }

    /// Live lookup via NSRunningApplication (not TCC-gated). nil ⇒ no such process.
    static func liveIdentity(of pid: pid_t) -> ProcessIdentity? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return ProcessIdentity(bundleId: app.bundleIdentifier)
    }
}
