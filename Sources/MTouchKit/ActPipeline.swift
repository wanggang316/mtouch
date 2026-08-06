import AppKit
import ApplicationServices
import Foundation

/// The observable outcome of a ref-based `act` invocation, kept SEPARATE from the
/// side effects (printing, exiting) so the exit-code mapping is unit-testable.
///
/// `.acted` prints the rendered diff to stdout and exits 0; `.failed` writes the
/// diagnostic to stderr and exits with `code`. A failure NEVER carries stdout, so
/// an error keeps stdout empty (never a hybrid).
public enum ActOutcome: Equatable, Sendable {
    /// The rendered diff (text or JSON) to write to stdout; exit 0.
    case acted(String)
    /// A stderr diagnostic paired with its non-zero exit code.
    case failed(stderr: String, code: MTouchExitCode)
}

/// Composes a ref-based `act` verb end-to-end:
/// preflight → resolve ref against the session → re-locate the live element by
/// its hints → perform the AX action → bounded re-walk → diff → persist the new
/// session. The front half (`resolveTarget`) is pure and AX-free so the whole
/// exit-code precedence (usage 64 → permission 2 → session/ref 3 → runtime 1) is
/// exercised without any grant; the back half wires the live AX collaborators,
/// each injectable so the mapping around them can be tested too.
public enum ActPipeline {
    // MARK: - Front half (pure): usage + permission + ref resolution

    /// The resolved act target, or a terminal outcome the caller returns as-is.
    /// Splitting the AX-free resolution out keeps the precedence rules testable.
    enum Target {
        case resolved(entry: RefEntry, session: Session, sessionPath: String)
        case terminal(ActOutcome)
    }

    /// Validate the argument shape, check the permission, and resolve the ref
    /// against the persisted session — all without touching AX. Precedence is
    /// encoded by ORDER: a malformed ref (usage 64) short-circuits before the
    /// permission check (2), which precedes session/ref errors (3).
    static func resolveTarget(
        ref: String,
        verb: ActVerb,
        value: String?,
        environment: [String: String],
        permissions: PermissionProvider,
        loadSession: (String) -> Session?
    ) -> Target {
        // 1. Usage (exit 64): a non-token argument is a malformed reference, not a
        //    missing element — and `set-value` needs a payload. Both are decided
        //    from the argument alone, so they outrank the permission/session gates.
        guard Session.isRefToken(ref) else {
            return .terminal(.failed(stderr: unknownRefDiagnostic(ref), code: .usageError))
        }
        if verb == .setValue, value == nil {
            return .terminal(.failed(
                stderr: "mtouch: 'act set-value' requires a value: mtouch act set-value <ref> <value>.",
                code: .usageError
            ))
        }

        // 2. Permission (exit 2): fail fast with the doctor-pointing diagnostic.
        guard permissions.accessibilityGranted else {
            return .terminal(.failed(
                stderr: PermissionError(permission: .accessibility).diagnostic,
                code: .permissionMissing
            ))
        }

        // 3. Session / ref (exit 3): resolve the token against the current session.
        let sessionPath = SessionStore.sessionFilePath(environment: environment)
        let session = loadSession(sessionPath)
        switch SessionStore.resolve(ref, in: session) {
        case let .resolved(entry):
            // `.resolved` is only returned when a session exists.
            return .resolved(entry: entry, session: session!, sessionPath: sessionPath)
        case .stale:
            return .terminal(.failed(stderr: staleRefDiagnostic(ref), code: .refError))
        case .noSession:
            return .terminal(.failed(stderr: noSessionDiagnostic(ref), code: .refError))
        case .unknown:
            // Unreachable: token shape was validated above. Mapped for totality.
            return .terminal(.failed(stderr: unknownRefDiagnostic(ref), code: .usageError))
        }
    }

    // MARK: - Full run (front half + live AX back half)

    public static func run(
        ref: String,
        verb: ActVerb,
        value: String?,
        json: Bool,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider(),
        loadSession: (String) -> Session? = { SessionStore.load(from: $0) },
        isRunning: (pid_t, String) -> Bool = { ActProcess.isRunning(pid: $0, bundleId: $1) },
        walkLive: (pid_t) -> LiveElementTree? = { pid in BoundedWalk.run { LiveElementTree.walk(pid: pid) } },
        rewalk: (pid_t) -> [AXNode]? = { pid in BoundedWalk.run { AXTreeWalker.walk(pid: pid).nodes } },
        performAction: (AXUIElement, ActVerb, String?) -> Result<Void, AXActionFailure> = { AXAction.perform($0, $1, value: $2) },
        persist: (Snapshot, String, pid_t, String) throws -> Void = { snapshot, app, pid, path in
            try SessionStore.save(snapshot, app: app, pid: pid, to: path)
        },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> ActOutcome {
        let entry: RefEntry
        let session: Session
        let sessionPath: String
        switch resolveTarget(
            ref: ref, verb: verb, value: value,
            environment: environment, permissions: permissions, loadSession: loadSession
        ) {
        case let .terminal(outcome):
            return outcome
        case let .resolved(resolvedEntry, resolvedSession, path):
            entry = resolvedEntry
            session = resolvedSession
            sessionPath = path
        }

        // The ref namespace is session-scoped, so the target app is the one the
        // snapshot was taken from — not any later `--app` override.
        let pid = session.pid
        let app = session.app

        // Runtime (exit 1): the snapshotted process is gone.
        guard isRunning(pid, app) else {
            return .failed(stderr: notRunningDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }

        // Pre-action walk, retaining handles for re-location. A bounded timeout on
        // a wedged target surfaces as an explicit exit-1 diagnostic, never a hang.
        guard let liveTree = walkLive(pid) else {
            return .failed(stderr: timeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }

        // Re-locate the SAME element by its hints. A miss means the element is gone
        // (window/element closed): stale (exit 3), and NOTHING is acted on — never
        // the impostor now occupying that position.
        guard let path = ElementRelocation.locatePath(entry, in: liveTree.attributesByPath),
              let element = liveTree.elementsByPath[path] else {
            return .failed(stderr: goneRefDiagnostic(ref), code: .refError)
        }

        // Perform the action. An honest AX refusal (disabled control, non-settable
        // value, non-focusable element) is exit 1 with no fabricated diff.
        if case let .failure(failure) = performAction(element, verb, value) {
            return .failed(stderr: "mtouch: \(failure.message)", code: .runtimeFailure)
        }

        // Re-walk (bounded, with a settle so a just-opened menu's items become
        // readable), diff against the pre-action state, and carry refs across.
        let preSnapshot = Snapshot(roots: ScrollEnrichment.enrich(liveTree.nodes), refs: session.refs)
        let expectsMenu = verb == .showMenu
            || (verb == .press && MenuDescent.ownsSubmenu(ownerRole: entry.role))
        let result = settledDiff(
            pre: preSnapshot, pid: pid, expectsMenu: expectsMenu, rewalk: rewalk, sleep: sleep
        )

        // Persist the new session BEFORE printing act-able refs: an unwritable path
        // is a failure (exit 1 naming it); we never advertise refs we could not save.
        do {
            try persist(result.newSnapshot, app, pid, sessionPath)
        } catch {
            return .failed(stderr: saveDiagnostic(error, path: sessionPath), code: .runtimeFailure)
        }

        let rendered = json ? renderDiffJSON(result.diff) : renderDiffText(result.diff)
        return .acted(rendered)
    }

    // MARK: - Post-action settle

    /// Re-walk and diff until the action's effect is visible or the budget is
    /// spent, returning the last `DiffResult` (an empty diff ⇒ "(no changes)").
    /// A menu-opening action needs a bounded settle because the opened `AXMenu`
    /// only becomes walkable once it reports a real frame (M1 menu-collapse gates
    /// on frame); every attempt RE-WALKS — this is never a sleep-only wait — and
    /// the loop stops the instant a change appears, so a genuine no-op returns
    /// promptly instead of exhausting the budget.
    static func settledDiff(
        pre: Snapshot,
        pid: pid_t,
        expectsMenu: Bool,
        rewalk: (pid_t) -> [AXNode]?,
        sleep: (TimeInterval) -> Void
    ) -> DiffResult {
        let maxAttempts = expectsMenu ? 10 : 4
        let interval: TimeInterval = expectsMenu ? 0.4 : 0.12

        // Baseline: identical-to-pre ⇒ "(no changes)" if every re-walk fails.
        var last = DiffEngine.diff(pre: pre, post: pre.roots)
        for attempt in 0..<maxAttempts {
            if let post = rewalk(pid) {
                last = DiffEngine.diff(pre: pre, post: ScrollEnrichment.enrich(post))
                if !last.diff.isEmpty { return last }
            }
            if attempt < maxAttempts - 1 { sleep(interval) }
        }
        return last
    }

    // MARK: - Diagnostics (all name the ref/app; ref errors advise a re-snapshot)

    static func unknownRefDiagnostic(_ ref: String) -> String {
        "mtouch: '\(ref)' is not a valid element reference. References look like 'e5' and are issued by "
            + "'mtouch snapshot'."
    }

    static func staleRefDiagnostic(_ ref: String) -> String {
        "mtouch: reference '\(ref)' is no longer valid: the UI has changed since the last snapshot. "
            + "Re-run 'mtouch snapshot' to get fresh references."
    }

    static func goneRefDiagnostic(_ ref: String) -> String {
        "mtouch: reference '\(ref)' could not be located: its element is gone (its window or menu closed). "
            + "Re-run 'mtouch snapshot' to get fresh references. Nothing was acted on."
    }

    static func noSessionDiagnostic(_ ref: String) -> String {
        "mtouch: no active snapshot session, so reference '\(ref)' cannot be resolved. "
            + "Run 'mtouch snapshot --app <bundleId>' first."
    }

    static func notRunningDiagnostic(app: String, pid: pid_t) -> String {
        "mtouch: application '\(app)' (pid \(pid)) is no longer running. "
            + "Relaunch it and re-run 'mtouch snapshot' to get fresh references."
    }

    static func timeoutDiagnostic(app: String, pid: pid_t) -> String {
        "mtouch: act timed out reading the accessibility tree of '\(app)' (pid \(pid)); "
            + "the application appears unresponsive. Bounded to avoid an indefinite hang."
    }

    static func saveDiagnostic(_ error: Error, path: String) -> String {
        if let storeError = error as? SessionStoreError {
            return "mtouch: \(storeError)"
        }
        return "mtouch: cannot write session to \(path): \(error.localizedDescription)"
    }
}

/// Liveness of the snapshotted process. A pid whose process is gone — or whose
/// number was recycled by a DIFFERENT app (bundle id mismatch) — is treated as
/// "no longer running", so act never targets an impostor process.
public enum ActProcess {
    public static func isRunning(pid: pid_t, bundleId: String) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        guard let running = app.bundleIdentifier else { return false }
        return running.caseInsensitiveCompare(bundleId) == .orderedSame
    }
}
