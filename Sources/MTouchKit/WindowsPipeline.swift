import Foundation

/// The observable outcome of a `windows` invocation, kept SEPARATE from the side
/// effects (stdout/stderr, exit) so the mapping is unit-testable and shared byte
/// for byte across the CLI and MCP surfaces. Mirrors `WaitOutcome`.
public enum WindowsOutcome: Equatable, Sendable {
    /// The listing to print on stdout (a JSON array, a "no windows" note, or the
    /// tab-separated text rows); exit 0.
    case listed(String)
    /// A stderr diagnostic paired with its non-zero exit code.
    case failed(stderr: String, code: MTouchExitCode)
}

/// Composes `windows` end-to-end: accessibility preflight → resolve bundle id to a
/// running pid → enumerate the app's AX windows → render (JSON array / "no windows"
/// note / text rows). The SINGLE source of truth shared by `Commands/Windows.swift`
/// and `MCPToolDispatch.windows(...)` so the two surfaces cannot drift.
///
/// Precedence is encoded by ORDER, matching the rest of the CLI: the missing-`app`
/// usage error is rejected by each command layer BEFORE this runs; here the
/// permission gate (exit 2) precedes app resolution (exit 1), which precedes the
/// enumeration + render (exit 0). Each collaborator is injectable so the whole flow
/// is exercised without any AX/TCC access; the live defaults wire the real ones.
public enum WindowsPipeline {
    public static func run(
        bundleId: String,
        json: Bool,
        permissions: PermissionProvider = LivePermissionProvider(),
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        enumerate: (pid_t) -> Result<[WindowInfo], AXReadFailure> = { AXWindowEnumerator.windows(ofPID: $0) },
        isAlive: (pid_t) -> Bool = { ProcessLiveness.isAlive($0) }
    ) -> WindowsOutcome {
        // 1. Preflight FIRST (exit 2): a missing grant fails fast with the
        //    doctor-pointing diagnostic.
        guard permissions.accessibilityGranted else {
            return .failed(
                stderr: PermissionError(permission: .accessibility).diagnostic,
                code: .permissionMissing
            )
        }

        // 2. Resolve the bundle id to a running pid. A non-running target has no
        //    windows to list, and an ambiguous or self-contradictory one must not be
        //    guessed at: each resolution failure carries its own exit code (1 for a
        //    missing/ambiguous target, 64 for a `--pid` that contradicts `--app`).
        let pid: pid_t
        do {
            pid = try resolvePID(bundleId)
        } catch let error as MTouchDiagnosticError {
            return .failed(stderr: error.message, code: error.exitCode)
        } catch {
            return .failed(
                stderr: "mtouch: could not resolve application '\(bundleId)': \(error)",
                code: .runtimeFailure
            )
        }

        // 3. Enumerate. A REFUSED read (exit 1) is not an empty listing: reporting
        //    "no windows" for an app whose accessibility interface would not answer
        //    hands an agent a falsehood it cannot detect, so the AX error is named.
        //    A refusal from a DEAD process is the process's absence, not an AX
        //    condition, so it is named as app-gone instead — liveness is consulted
        //    only on this failure path, never on a successful listing.
        let windows: [WindowInfo]
        switch enumerate(pid) {
        case let .success(listed):
            windows = listed
        case let .failure(failure):
            guard isAlive(pid) else {
                return .failed(stderr: AppGone.diagnostic(app: bundleId, pid: pid), code: .runtimeFailure)
            }
            return .failed(
                stderr: failure.diagnostic(reading: "windows", of: bundleId),
                code: .runtimeFailure
            )
        }

        // 4. Render (exit 0). Zero windows — the app ANSWERED, with none — is a
        //    success state, said so explicitly in text mode; JSON always emits the
        //    (possibly empty) array, never null.
        if json {
            return .listed(WindowInfo.jsonArray(windows))
        }
        if windows.isEmpty {
            return .listed("no windows for \(bundleId)")
        }
        return .listed(windows.map(\.textLine).joined(separator: "\n"))
    }
}
