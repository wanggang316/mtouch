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
        rewalk: (pid_t) -> WalkResult? = { pid in BoundedWalk.run { AXTreeWalker.walk(pid: pid) } },
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
        // the impostor now occupying that position. The live per-element window-id
        // map is passed so the owning-window gate can reject a same-hint element in
        // a DIFFERENT (even identically-titled) window (VAL-ACT-011).
        guard let path = ElementRelocation.locatePath(
                  entry, in: liveTree.attributesByPath, windowIDsByPath: liveTree.windowIDsByPath
              ),
              let element = liveTree.elementsByPath[path] else {
            return .failed(stderr: goneRefDiagnostic(ref), code: .refError)
        }

        // The pre-action baseline: the walked tree carrying the session's refs so a
        // surviving element keeps its ref in the diff. A menu-opening verb needs the
        // longer settle so the just-opened `AXMenu`'s items become readable.
        let preSnapshot = Snapshot(roots: ScrollEnrichment.enrich(liveTree.nodes), refs: session.refs)
        let expectsMenu = verb == .showMenu
            || (verb == .press && MenuDescent.ownsSubmenu(ownerRole: entry.role))
        return runInputVerb(
            pid: pid, app: app, sessionPath: sessionPath,
            preSnapshot: preSnapshot, expectsMenu: expectsMenu, json: json,
            rewalk: rewalk, persist: persist, sleep: sleep
        ) {
            // Perform the action. An honest AX refusal (disabled control,
            // non-settable value, non-focusable element) is exit 1 with no diff.
            if case let .failure(failure) = performAction(element, verb, value) {
                return .failed(stderr: "mtouch: \(failure.message)", code: .runtimeFailure)
            }
            return nil
        }
    }

    // MARK: - Keyboard verbs (type / key)

    /// The resolved app target, or a terminal outcome returned as-is. Shared by the
    /// keyboard AND coordinate verbs (both act on "the session's app, or --app").
    /// Split out (like `resolveTarget`) so the permission-before-target precedence
    /// is exercisable without any AX access.
    enum KeyboardTarget {
        case resolved(pid: pid_t, app: String, refs: [String: RefEntry], sessionPath: String)
        case terminal(ActOutcome)
    }

    /// Resolve the app a keyboard verb targets: the explicit `--app`, else the
    /// current session's app. Delegates to the shared resolver with the keyboard
    /// no-target diagnostic ("no app to type into").
    static func resolveKeyboardTarget(
        appOverride: String?,
        environment: [String: String],
        permissions: PermissionProvider,
        loadSession: (String) -> Session?,
        resolvePID: (String) throws -> pid_t
    ) -> KeyboardTarget {
        resolveAppTarget(
            appOverride: appOverride, environment: environment, permissions: permissions,
            loadSession: loadSession, resolvePID: resolvePID,
            noTargetDiagnostic: noKeyboardTargetDiagnostic
        )
    }

    /// Resolve the app a coordinate verb targets: the explicit `--app`, else the
    /// current session's app. Same resolution as the keyboard verbs (so the pinned
    /// precedence is identical); only the exit-3 no-target message differs ("no app
    /// to act on").
    static func resolveCoordinateTarget(
        appOverride: String?,
        environment: [String: String],
        permissions: PermissionProvider,
        loadSession: (String) -> Session?,
        resolvePID: (String) throws -> pid_t
    ) -> KeyboardTarget {
        resolveAppTarget(
            appOverride: appOverride, environment: environment, permissions: permissions,
            loadSession: loadSession, resolvePID: resolvePID,
            noTargetDiagnostic: noCoordinateTargetDiagnostic
        )
    }

    /// Shared app-target resolution for the keyboard AND coordinate verbs. The
    /// permission gate (exit 2) is checked FIRST so it precedes every session/app
    /// resolution (pinned precedence 64 → 2 → 3 → 1; the usage-64 arg parse happens
    /// in the CLI before this). `noTargetDiagnostic` supplies the verb-appropriate
    /// exit-3 message for the "no session and no --app" case.
    private static func resolveAppTarget(
        appOverride: String?,
        environment: [String: String],
        permissions: PermissionProvider,
        loadSession: (String) -> Session?,
        resolvePID: (String) throws -> pid_t,
        noTargetDiagnostic: () -> String
    ) -> KeyboardTarget {
        // Permission (exit 2): fail fast with the doctor-pointing diagnostic,
        // BEFORE resolving the session or the target app.
        guard permissions.accessibilityGranted else {
            return .terminal(.failed(
                stderr: PermissionError(permission: .accessibility).diagnostic,
                code: .permissionMissing
            ))
        }

        let sessionPath = SessionStore.sessionFilePath(environment: environment)
        let session = loadSession(sessionPath)

        // Explicit `--app` selects the target directly. When it names the SAME
        // running app as the session, the session refs still describe that tree, so
        // carry them (a survivor keeps its ref in the diff); otherwise the session
        // (if any) describes a different app, so number the diff afresh.
        if let appOverride {
            let pid: pid_t
            do {
                pid = try resolvePID(appOverride)
            } catch let error as AppNotRunningError {
                return .terminal(.failed(stderr: error.message, code: .runtimeFailure))
            } catch {
                return .terminal(.failed(
                    stderr: "mtouch: could not resolve application '\(appOverride)': \(error)",
                    code: .runtimeFailure
                ))
            }
            if let session, session.pid == pid,
               session.app.caseInsensitiveCompare(appOverride) == .orderedSame {
                return .resolved(pid: pid, app: session.app, refs: session.refs, sessionPath: sessionPath)
            }
            return .resolved(pid: pid, app: appOverride, refs: [:], sessionPath: sessionPath)
        }

        // No override: the session's app is the target. Without a session there is
        // no target to act on — exit 3, advising a snapshot (or an explicit --app).
        guard let session else {
            return .terminal(.failed(stderr: noTargetDiagnostic(), code: .refError))
        }
        return .resolved(pid: session.pid, app: session.app, refs: session.refs, sessionPath: sessionPath)
    }

    /// Compose a keyboard `act` verb end-to-end, reusing the SAME back half as the
    /// ref verbs (pre-walk → act → bounded settle → diff → persist). The only
    /// difference is the "act" step: keystrokes are delivered to the target's
    /// FOCUSED element via `deliver` (activate + secure-check + post), rather than
    /// an AX action on a re-located element.
    ///
    /// An empty `type` is an explicit no-op: it delivers nothing and reports
    /// "(no changes)" (exit 0), short-circuiting before any permission/target work
    /// because it can neither fail nor change anything.
    public static func runKeyboard(
        action: KeyboardAction,
        appOverride: String?,
        json: Bool,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider(),
        loadSession: (String) -> Session? = { SessionStore.load(from: $0) },
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        isRunning: (pid_t, String) -> Bool = { ActProcess.isRunning(pid: $0, bundleId: $1) },
        rewalk: (pid_t) -> WalkResult? = { pid in BoundedWalk.run { AXTreeWalker.walk(pid: pid) } },
        deliver: (pid_t, KeyboardAction) throws -> Void = { pid, action in
            try LiveKeyboardDelivery.deliver(pid: pid, action: action)
        },
        persist: (Snapshot, String, pid_t, String) throws -> Void = { snapshot, app, pid, path in
            try SessionStore.save(snapshot, app: app, pid: pid, to: path)
        },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> ActOutcome {
        if case let .type(text) = action, text.isEmpty {
            let empty = Diff(added: [], removed: [], changed: [], staleRefs: [])
            return .acted(json ? renderDiffJSON(empty) : renderDiffText(empty))
        }

        let pid: pid_t
        let app: String
        let refs: [String: RefEntry]
        let sessionPath: String
        switch resolveKeyboardTarget(
            appOverride: appOverride, environment: environment,
            permissions: permissions, loadSession: loadSession, resolvePID: resolvePID
        ) {
        case let .terminal(outcome):
            return outcome
        case let .resolved(resolvedPID, resolvedApp, resolvedRefs, path):
            pid = resolvedPID
            app = resolvedApp
            refs = resolvedRefs
            sessionPath = path
        }

        // Runtime (exit 1): the target process is gone.
        guard isRunning(pid, app) else {
            return .failed(stderr: notRunningDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }

        // Pre-action walk for the diff baseline. A wedged target -> bounded exit 1.
        guard let preWalk = rewalk(pid) else {
            return .failed(stderr: timeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }
        // Carry the session's refs onto the pre tree so a changed focused element
        // keeps its ref in the diff (matching the ref verbs' pre snapshot).
        let preSnapshot = Snapshot(roots: ScrollEnrichment.enrich(preWalk.nodes), refs: refs)

        return runInputVerb(
            pid: pid, app: app, sessionPath: sessionPath,
            preSnapshot: preSnapshot, expectsMenu: false, json: json,
            rewalk: rewalk, persist: persist, sleep: sleep
        ) {
            // Deliver the keystrokes. Secure input active -> exit 5, ZERO events,
            // and a payload-free diagnostic (both from `SecureInputActive`).
            do {
                try deliver(pid, action)
            } catch let error as SecureInputActive {
                return .failed(stderr: error.diagnostic, code: error.exitCode)
            } catch {
                return .failed(stderr: "mtouch: failed to deliver keystrokes: \(error)", code: .runtimeFailure)
            }
            return nil
        }
    }

    // MARK: - Coordinate verbs (click / rightclick / doubleclick / drag / scroll)

    /// Compose a coordinate `act` verb end-to-end, reusing the SAME back half as
    /// the ref and keyboard verbs (pre-walk → act → bounded settle → diff →
    /// persist). The only differences are the "act" step — a mouse gesture at
    /// screen points delivered via `deliver` (activate + post) — and an off-screen
    /// guard: any target point outside every display is rejected (exit 1) BEFORE a
    /// single event is posted, so a bad coordinate never delivers input anywhere.
    public static func runCoordinate(
        action: PointerAction,
        appOverride: String?,
        json: Bool,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider(),
        loadSession: (String) -> Session? = { SessionStore.load(from: $0) },
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        isRunning: (pid_t, String) -> Bool = { ActProcess.isRunning(pid: $0, bundleId: $1) },
        onScreen: (ScreenPoint) -> Bool = { ScreenBounds.isOnScreen($0) },
        rewalk: (pid_t) -> WalkResult? = { pid in BoundedWalk.run { AXTreeWalker.walk(pid: pid) } },
        deliver: (pid_t, PointerAction) throws -> Void = { pid, action in
            LivePointerDelivery.deliver(pid: pid, action: action)
        },
        persist: (Snapshot, String, pid_t, String) throws -> Void = { snapshot, app, pid, path in
            try SessionStore.save(snapshot, app: app, pid: pid, to: path)
        },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> ActOutcome {
        let pid: pid_t
        let app: String
        let refs: [String: RefEntry]
        let sessionPath: String
        switch resolveCoordinateTarget(
            appOverride: appOverride, environment: environment,
            permissions: permissions, loadSession: loadSession, resolvePID: resolvePID
        ) {
        case let .terminal(outcome):
            return outcome
        case let .resolved(resolvedPID, resolvedApp, resolvedRefs, path):
            pid = resolvedPID
            app = resolvedApp
            refs = resolvedRefs
            sessionPath = path
        }

        // Off-screen (exit 1): validate EVERY target point before touching the live
        // process or posting anything, so a bad coordinate delivers zero events.
        for point in action.points where !onScreen(point) {
            return .failed(stderr: offScreenDiagnostic(point), code: .runtimeFailure)
        }

        // Runtime (exit 1): the target process is gone.
        guard isRunning(pid, app) else {
            return .failed(stderr: notRunningDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }

        // Pre-action walk for the diff baseline. A wedged target -> bounded exit 1.
        guard let preWalk = rewalk(pid) else {
            return .failed(stderr: timeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }
        // Carry the session's refs onto the pre tree so a changed element keeps its
        // ref in the diff (matching the ref/keyboard verbs' pre snapshot).
        let preSnapshot = Snapshot(roots: ScrollEnrichment.enrich(preWalk.nodes), refs: refs)

        // A right-click opens a context menu, so use the longer menu settle to let
        // its items become walkable.
        return runInputVerb(
            pid: pid, app: app, sessionPath: sessionPath,
            preSnapshot: preSnapshot, expectsMenu: action.opensMenu, json: json,
            rewalk: rewalk, persist: persist, sleep: sleep
        ) {
            // Deliver the gesture. Any delivery failure is a runtime error (exit 1).
            do {
                try deliver(pid, action)
            } catch {
                return .failed(stderr: "mtouch: failed to deliver pointer event: \(error)", code: .runtimeFailure)
            }
            return nil
        }
    }

    // MARK: - Shared back half (act -> settle -> persist -> render)

    /// The tail every `act` verb shares once its target is resolved and its
    /// pre-action baseline (`preSnapshot`) is taken: perform the verb-specific
    /// input, bounded-settle into a diff, persist the new session BEFORE rendering,
    /// then render. `act` runs the input and returns a terminal failure outcome to
    /// short-circuit (an AX refusal, secure input, a delivery error), or nil on
    /// success — so each verb keeps its own error mapping while the settle/persist/
    /// render invariants (persist-before-render; an unwritable path is exit 1) live
    /// in exactly one place.
    private static func runInputVerb(
        pid: pid_t,
        app: String,
        sessionPath: String,
        preSnapshot: Snapshot,
        expectsMenu: Bool,
        json: Bool,
        rewalk: (pid_t) -> WalkResult?,
        persist: (Snapshot, String, pid_t, String) throws -> Void,
        sleep: (TimeInterval) -> Void,
        act: () -> ActOutcome?
    ) -> ActOutcome {
        if let failure = act() { return failure }

        // Bounded re-walk until the change appears, diff against the pre tree,
        // persist the new session, then render.
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
        rewalk: (pid_t) -> WalkResult?,
        sleep: (TimeInterval) -> Void
    ) -> DiffResult {
        let maxAttempts = expectsMenu ? 10 : 4
        let interval: TimeInterval = expectsMenu ? 0.4 : 0.12

        // Baseline: identical-to-pre ⇒ "(no changes)" if every re-walk fails.
        var last = DiffEngine.diff(pre: pre, post: pre.roots)
        for attempt in 0..<maxAttempts {
            if let result = rewalk(pid) {
                // Thread the post walk's per-root window ids so the reconcile can
                // detect a ref whose owning window vanished/changed and let it go
                // stale instead of re-homing it onto a same-hint impostor.
                last = DiffEngine.diff(
                    pre: pre,
                    post: ScrollEnrichment.enrich(result.nodes),
                    postWindowIDsByPath: result.windowIDsByPath
                )
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

    static func noKeyboardTargetDiagnostic() -> String {
        "mtouch: no active snapshot session, so there is no app to type into. "
            + "Run 'mtouch snapshot --app <bundleId>' first, or pass '--app <bundleId>'."
    }

    static func noCoordinateTargetDiagnostic() -> String {
        "mtouch: no active snapshot session, so there is no app to act on. "
            + "Run 'mtouch snapshot --app <bundleId>' first, or pass '--app <bundleId>'."
    }

    static func offScreenDiagnostic(_ point: ScreenPoint) -> String {
        "mtouch: coordinate (\(JSONText.number(point.x)),\(JSONText.number(point.y))) is outside every display; "
            + "no event was delivered. Re-derive coordinates from a fresh 'mtouch snapshot'."
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
