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
        enumerate: (pid_t) -> [WindowInfo] = { AXWindowEnumerator.windows(ofPID: $0) }
    ) -> WindowsOutcome {
        // 1. Preflight FIRST (exit 2): a missing grant fails fast with the
        //    doctor-pointing diagnostic.
        guard permissions.accessibilityGranted else {
            return .failed(
                stderr: PermissionError(permission: .accessibility).diagnostic,
                code: .permissionMissing
            )
        }

        // 2. Resolve the bundle id to a running pid (exit 1). A non-running target
        //    has no windows to list: fail immediately.
        let pid: pid_t
        do {
            pid = try resolvePID(bundleId)
        } catch let error as AppNotRunningError {
            return .failed(stderr: error.message, code: .runtimeFailure)
        } catch {
            return .failed(
                stderr: "mtouch: could not resolve application '\(bundleId)': \(error)",
                code: .runtimeFailure
            )
        }

        // 3. Enumerate + render (exit 0). Zero windows is a success state, said so
        //    explicitly in text mode; JSON always emits the (possibly empty) array.
        let windows = enumerate(pid)
        if json {
            return .listed(WindowInfo.jsonArray(windows))
        }
        if windows.isEmpty {
            return .listed("no windows for \(bundleId)")
        }
        return .listed(windows.map(\.textLine).joined(separator: "\n"))
    }
}
