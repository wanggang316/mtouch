import Foundation

/// The observable outcome of a `snapshot` invocation, kept SEPARATE from the
/// side effects (printing, exiting) so the whole flow is unit-testable.
///
/// The CLI command executes it: `.rendered` prints to stdout and exits 0;
/// `.failed` writes the diagnostic to stderr and exits with `code`. A failure
/// NEVER carries stdout — so a `--json` error keeps stdout empty (never a hybrid).
public enum SnapshotOutcome: Equatable, Sendable {
    /// The text or JSON snapshot to write to stdout; exit 0.
    case rendered(String)
    /// A stderr diagnostic paired with its non-zero exit code.
    case failed(stderr: String, code: MTouchExitCode)
}

/// Composes the `snapshot` command end-to-end: accessibility preflight → resolve
/// bundle id to pid → bounded walk → scroll-position enrichment → render (text or
/// JSON) → persist the session. Each collaborator is injectable so the flow can
/// be exercised without any AX/TCC access; the live defaults wire the real ones.
public enum SnapshotPipeline {
    public static func run(
        bundleId: String,
        json: Bool,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider(),
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        walk: (pid_t) -> WalkResult? = { pid in BoundedWalk.run { AXTreeWalker.walk(pid: pid) } },
        diagnoseEmptyTree: (pid_t) -> AXReadFailure? = { AXWindowEnumerator.readFailure(ofPID: $0) },
        persist: (Snapshot, String, pid_t, String) throws -> Void = { snapshot, app, pid, path in
            try SessionStore.save(snapshot, app: app, pid: pid, to: path)
        }
    ) -> SnapshotOutcome {
        // 1. Preflight FIRST: without the grant, fail fast with the doctor-pointing
        //    diagnostic (exit 2). No stdout is produced on any failure path, so
        //    `--json` stays clean. Mirrors `preflightOrExit`'s contract, but as a
        //    value so the not-granted path is testable with a stub provider.
        guard permissions.accessibilityGranted else {
            return .failed(
                stderr: PermissionError(permission: .accessibility).diagnostic,
                code: .permissionMissing
            )
        }

        // 2. Resolve the bundle id to a running pid. Each resolution failure carries
        //    its own exit code (1 for a missing/ambiguous target, 64 for a `--pid`
        //    that contradicts `--app`).
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

        // 3. Walk under a hard deadline: a hung/SIGSTOPped target yields nil, which
        //    becomes an explicit bounded timeout diagnostic instead of a hang.
        guard let result = walk(pid) else {
            return .failed(stderr: timeoutDiagnostic(bundleId: bundleId, pid: pid), code: .runtimeFailure)
        }

        // 3b. NO roots at all is ambiguous, because the walker flattens every failed
        //     per-element read to a default: an app that genuinely exposes nothing
        //     looks exactly like one whose accessibility interface refused every
        //     read. Ask the app element directly (one read, only on this already-
        //     degenerate path) and, if the read is REFUSED, say so at exit 1 instead
        //     of printing an empty tree an agent would read as truth. A successful
        //     read keeps today's behavior: an explicitly-marked empty tree, exit 0.
        if result.nodes.isEmpty, let failure = diagnoseEmptyTree(pid) {
            return .failed(
                stderr: failure.diagnostic(reading: "the accessibility tree", of: bundleId),
                code: .runtimeFailure
            )
        }

        // 4. Enrich scroll areas with a derived scroll position (see ScrollEnrichment).
        //    Thread the walk's per-root owning-window ids through so each ref records
        //    its owning-window identity (VAL-ACT-011). Enrichment maps roots 1:1 in
        //    order, so the root-keyed ids stay aligned with the enriched tree.
        let snapshot = Snapshot(
            roots: ScrollEnrichment.enrich(result.nodes),
            windowIDsByPath: result.windowIDsByPath
        )
        let note = fallbackNote(result)

        // 5. Persist the session BEFORE printing refs: an unwritable path is a
        //    failure (exit 1 naming the path); we never print refs we could not save.
        let path = SessionStore.sessionFilePath(environment: environment)
        do {
            try persist(snapshot, bundleId, pid, path)
        } catch {
            return .failed(stderr: saveDiagnostic(error, path: path), code: .runtimeFailure)
        }

        let output = json ? renderJSONOutput(snapshot, note: note) : renderTextOutput(snapshot, note: note)
        return .rendered(output)
    }

    // MARK: - Rendering (note-aware wrappers over the shared renderers)

    /// Text output, prefixing a `note:` line when the fallback engaged.
    static func renderTextOutput(_ snapshot: Snapshot, note: String?) -> String {
        let tree = renderText(snapshot)
        guard let note else { return tree }
        return "note: \(note)\n\(tree)"
    }

    /// JSON output. The top level is a stable object `{ "nodes": [...] }` with an
    /// optional `"note"` field — an object (not a bare array) so a fallback note
    /// has somewhere to live while `nodes` carries the full filtered tree
    /// (geometry and scroll positions included).
    static func renderJSONOutput(_ snapshot: Snapshot, note: String?) -> String {
        var fields = ["\"nodes\":\(renderJSON(snapshot))"]
        if let note { fields.append("\"note\":\(JSONText.string(note))") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Advisory note when the AXManualAccessibility fallback engaged, else nil.
    static func fallbackNote(_ result: WalkResult) -> String? {
        guard result.fallbackFired else { return nil }
        return result.fallbackHelped
            ? "accessibility tree was recovered via the AXManualAccessibility fallback"
            : "accessibility tree may be incomplete: the AXManualAccessibility fallback "
                + "engaged but recovered no additional content"
    }

    // MARK: - Diagnostics

    static func timeoutDiagnostic(bundleId: String, pid: pid_t) -> String {
        "mtouch: snapshot timed out after \(JSONText.number(BoundedWalk.defaultDeadline))s reading the "
            + "accessibility tree of '\(bundleId)' (pid \(pid)); the application appears unresponsive "
            + "(e.g. stopped). Bounded to avoid an indefinite hang."
    }

    static func saveDiagnostic(_ error: Error, path: String) -> String {
        // `SessionStoreError` already names the offending path; other errors are
        // wrapped so the path is still surfaced.
        if let storeError = error as? SessionStoreError {
            return "mtouch: \(storeError)"
        }
        return "mtouch: cannot write session to \(path): \(error.localizedDescription)"
    }
}
