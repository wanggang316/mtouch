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
    /// The rendered diff (text or JSON) to write to stdout; exit 0. The diff was
    /// SETTLED: the tree was identical on two consecutive post-action walks, so the
    /// change it reports is the application's finished response, not a frame of it.
    case acted(String)
    /// The post-action diff was taken, but it never stopped changing before the
    /// settle budget expired (see `SettleBudget`). The payload is the best — most
    /// recent — reading, rendered with the "did not settle" marker; exit 0, because
    /// the action itself succeeded and re-running it would apply it twice.
    ///
    /// A case of its own rather than an `.acted` variant, for the same reason
    /// `.deliveredUnverified` is: a partial diff read as a settled one is WORSE than
    /// no diff at all. An agent that sees "nothing changed" after a successful
    /// action retries it; one that sees half a value believes the application is in
    /// a state it is not in. No consumer may reach the payload without also seeing
    /// that the reading is provisional.
    case actedUnsettled(String)
    /// Input was delivered under `--no-verify`: no walk was taken before or after
    /// it, so there is NO diff. The payload is the rendered "nothing was verified"
    /// notice, written to stdout where a diff would go; exit 0.
    ///
    /// A case of its own rather than an `.acted` variant, so no consumer — stdout,
    /// the MCP payload, the trajectory record — can silently treat an unverified
    /// delivery as a verified action.
    case deliveredUnverified(String)
    /// The synthesized events were POSTED, but the bounded flush could not confirm
    /// the window server processed them (see `InputDeliveryFlush`). The payload is
    /// the rendered "could not be confirmed" notice, written to stdout where a diff
    /// would go; exit 0, because the input did go out and re-sending it blindly
    /// would risk delivering it twice.
    ///
    /// Reported by the VERIFIED verbs too: once delivery is in doubt there is
    /// nothing to verify against, so the post-action walk is skipped rather than
    /// dressed up as the effect of an action that may never have happened. A case
    /// of its own so it can never render as the weaker `.deliveredUnverified`.
    case deliveredUnconfirmed(String)
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
        return resolveRefTarget(
            ref: ref, environment: environment, permissions: permissions, loadSession: loadSession
        )
    }

    /// The verb-INDEPENDENT half of `resolveTarget`: token shape (usage 64) →
    /// permission (2) → session/ref resolution (3), in that pinned order.
    ///
    /// Internal so a read-only ref command composes the SAME resolution — and
    /// therefore the same exit codes and byte-identical diagnostics — instead of
    /// restating them. `resolveTarget` layers the act-only `set-value` payload rule
    /// on top; the token check is repeated here so this entry point is total on its
    /// own (it is idempotent, so the ordering is unchanged either way).
    static func resolveRefTarget(
        ref: String,
        environment: [String: String],
        permissions: PermissionProvider,
        loadSession: (String) -> Session?
    ) -> Target {
        // 1. Usage (exit 64): a non-token argument is a malformed reference, not a
        //    missing element — decided from the argument alone, so it outranks the
        //    permission/session gates.
        guard Session.isRefToken(ref) else {
            return .terminal(.failed(stderr: unknownRefDiagnostic(ref), code: .usageError))
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
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
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
            return .failed(stderr: inputTimeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure)
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
            rewalk: rewalk, persist: persist, now: now, sleep: sleep
        ) {
            // Perform the action. An honest AX refusal (disabled control,
            // non-settable value, non-focusable element) is exit 1 with no diff.
            if case let .failure(failure) = performAction(element, verb, value) {
                return .failed(stderr: "mtouch: \(failure.message)", code: .runtimeFailure)
            }
            return nil
        }
    }

    // MARK: - Criteria-targeted ref verbs (--of)

    /// Resolve the app a criteria-targeted verb acts in. The set-value payload
    /// rule (usage, exit 64) is decided from the arguments alone, so it precedes
    /// the permission gate — the same order `resolveTarget` pins for a ref — and
    /// the rest is the shared app resolution the keyboard/coordinate verbs use,
    /// so `--app`/`--pid` fail with the same diagnostics everywhere.
    static func resolveCriteriaTarget(
        app: String,
        verb: ActVerb,
        value: String?,
        environment: [String: String],
        permissions: PermissionProvider,
        loadSession: (String) -> Session?,
        resolvePID: (String) throws -> pid_t
    ) -> KeyboardTarget {
        if verb == .setValue, value == nil {
            return .terminal(.failed(
                stderr: "mtouch: 'act set-value' requires a value: "
                    + "mtouch act set-value --of <criteria> --app <bundleId> <value>.",
                code: .usageError
            ))
        }
        return resolveAppTarget(
            appOverride: app, environment: environment, permissions: permissions,
            loadSession: loadSession, resolvePID: resolvePID,
            noTargetDiagnostic: noCriteriaTargetDiagnostic
        )
    }

    /// Compose a criteria-targeted ref verb end-to-end: resolve the app → walk it
    /// (retaining handles) → resolve the criteria to EXACTLY ONE actionable
    /// element → perform the AX action → the SAME back half as every other input
    /// verb (bounded settle → diff → persist). No session is required on the way
    /// in — the criteria is matched against the pre-action walk itself, so a
    /// scripted flow needs no snapshot and holds no ref that could go stale — and
    /// the session written on the way out is the pipeline's normal one, so a
    /// later ref-based act can still follow.
    ///
    /// Several matches are REFUSED (exit 1), never resolved to "the first one":
    /// acting on a guessed element is the silent-misdelivery class this project
    /// exists to prevent. Zero actionable matches is likewise exit 1, with the
    /// non-actionable count called out when the criteria matched only inert
    /// elements. The contrast with `read --of` (which returns every match) is
    /// deliberate: reading many is safe, acting on many is not.
    public static func runCriteria(
        criteria: WaitCriteria,
        verb: ActVerb,
        value: String?,
        app: String,
        json: Bool,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider(),
        loadSession: (String) -> Session? = { SessionStore.load(from: $0) },
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        isRunning: (pid_t, String) -> Bool = { ActProcess.isRunning(pid: $0, bundleId: $1) },
        walkLive: (pid_t) -> LiveElementTree? = { pid in BoundedWalk.run { LiveElementTree.walk(pid: pid) } },
        rewalk: (pid_t) -> WalkResult? = { pid in BoundedWalk.run { AXTreeWalker.walk(pid: pid) } },
        performAction: (AXUIElement, ActVerb, String?) -> Result<Void, AXActionFailure> = { AXAction.perform($0, $1, value: $2) },
        persist: (Snapshot, String, pid_t, String) throws -> Void = { snapshot, app, pid, path in
            try SessionStore.save(snapshot, app: app, pid: pid, to: path)
        },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> ActOutcome {
        let pid: pid_t
        let appName: String
        let refs: [String: RefEntry]
        let sessionPath: String
        switch resolveCriteriaTarget(
            app: app, verb: verb, value: value, environment: environment,
            permissions: permissions, loadSession: loadSession, resolvePID: resolvePID
        ) {
        case let .terminal(outcome):
            return outcome
        case let .resolved(resolvedPID, resolvedApp, resolvedRefs, path):
            pid = resolvedPID
            appName = resolvedApp
            refs = resolvedRefs
            sessionPath = path
        }

        // Runtime (exit 1): the target process is gone.
        guard isRunning(pid, appName) else {
            return .failed(stderr: notRunningDiagnostic(app: appName, pid: pid), code: .runtimeFailure)
        }

        // Pre-action walk, retaining handles. The SAME walk resolves the criteria
        // AND provides the diff baseline, so the element acted on is one the
        // baseline provably contains. A bounded timeout on a wedged target
        // surfaces as an explicit exit-1 diagnostic, never a hang.
        guard let liveTree = walkLive(pid) else {
            return .failed(stderr: inputTimeoutDiagnostic(app: appName, pid: pid), code: .runtimeFailure)
        }

        let match: ActCriteriaSelection.Match
        switch ActCriteriaSelection.select(criteria, in: liveTree.nodes) {
        case let .one(selected):
            match = selected
        case let .ambiguous(matches):
            return .failed(
                stderr: ambiguousCriteriaDiagnostic(criteria, app: appName, matches: matches),
                code: .runtimeFailure
            )
        case let .none(nonActionable):
            return .failed(
                stderr: noCriteriaMatchDiagnostic(
                    criteria, app: appName, roots: liveTree.nodes, nonActionable: nonActionable
                ),
                code: .runtimeFailure
            )
        }
        guard let element = liveTree.elementsByPath[match.path] else {
            // Every walked node records its handle, so this is unreachable in
            // production; mapped for totality so a fixture gap cannot trap.
            return .failed(
                stderr: "mtouch: the element matching \(criteria.description) could not be reached; "
                    + "nothing was acted on.",
                code: .runtimeFailure
            )
        }

        // Same back half as the ref verbs, including the menu-settle rule keyed
        // off the MATCHED element's role.
        let preSnapshot = Snapshot(roots: ScrollEnrichment.enrich(liveTree.nodes), refs: refs)
        let expectsMenu = verb == .showMenu
            || (verb == .press && MenuDescent.ownsSubmenu(ownerRole: match.node.role))
        return runInputVerb(
            pid: pid, app: appName, sessionPath: sessionPath,
            preSnapshot: preSnapshot, expectsMenu: expectsMenu, json: json,
            rewalk: rewalk, persist: persist, now: now, sleep: sleep
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

    /// Resolve the app a menu-path verb targets: the explicit `--app`, else the
    /// current session's app. Same resolution as the keyboard/coordinate verbs (so
    /// the pinned precedence is identical); only the exit-3 no-target message
    /// differs ("no app whose menus to drive").
    static func resolveMenuTarget(
        appOverride: String?,
        environment: [String: String],
        permissions: PermissionProvider,
        loadSession: (String) -> Session?,
        resolvePID: (String) throws -> pid_t
    ) -> KeyboardTarget {
        resolveAppTarget(
            appOverride: appOverride, environment: environment, permissions: permissions,
            loadSession: loadSession, resolvePID: resolvePID,
            noTargetDiagnostic: noMenuTargetDiagnostic
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
            } catch let error as MTouchDiagnosticError {
                // Each resolution failure carries its own exit code: 1 for a
                // missing/ambiguous target, 64 for a `--pid` contradicting `--app`.
                return .terminal(.failed(stderr: error.message, code: error.exitCode))
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
    /// because it can neither fail nor change anything. `noVerify` does not change
    /// that: nothing is delivered, so there is no unverified delivery to report.
    ///
    /// `noVerify` skips BOTH walks and the session write, delivering the keystrokes
    /// and reporting that nothing was verified (see `UnverifiedDelivery`). Every
    /// guard that does NOT depend on the tree still applies in the same order —
    /// permission (2), target resolution (3), liveness (1), and the secure-input
    /// refusal (5), which is owned by the delivery seam itself.
    public static func runKeyboard(
        action: KeyboardAction,
        appOverride: String?,
        json: Bool,
        noVerify: Bool = false,
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
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
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

        // Deliver the keystrokes. Secure input active -> exit 5, ZERO events, and a
        // payload-free diagnostic (both from `SecureInputActive`). The seam also
        // owns the activate-before-post and post-then-flush invariants, so both
        // paths below activate AND wait for delivery.
        func deliverKeystrokes() -> ActOutcome? {
            do {
                try deliver(pid, action)
            } catch let error as SecureInputActive {
                return .failed(stderr: error.diagnostic, code: error.exitCode)
            } catch is DeliveryUnconfirmed {
                // Posted, but unacknowledged: short-circuit with the stronger
                // notice instead of walking a tree we cannot attribute.
                return .deliveredUnconfirmed(UnconfirmedDelivery.rendered(json: json))
            } catch {
                return .failed(stderr: "mtouch: failed to deliver keystrokes: \(error)", code: .runtimeFailure)
            }
            return nil
        }

        // Unverified delivery: no baseline, no settle, no session write — the
        // session keeps describing the last tree that was actually READ, so a later
        // ref still means what it meant. Only the notice is reported. The delivery
        // is still FLUSHED: skipping verification is not licence to skip waiting for
        // the input to land, which is the whole reason this mode was unreliable.
        if noVerify {
            if let terminal = deliverKeystrokes() { return terminal }
            return .deliveredUnverified(UnverifiedDelivery.rendered(json: json))
        }

        // Pre-action walk for the diff baseline. A wedged target -> bounded exit 1.
        guard let preWalk = rewalk(pid) else {
            return .failed(stderr: inputTimeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }
        // Carry the session's refs onto the pre tree so a changed focused element
        // keeps its ref in the diff (matching the ref verbs' pre snapshot).
        let preSnapshot = Snapshot(roots: ScrollEnrichment.enrich(preWalk.nodes), refs: refs)

        return runInputVerb(
            pid: pid, app: app, sessionPath: sessionPath,
            preSnapshot: preSnapshot, expectsMenu: false, json: json,
            rewalk: rewalk, persist: persist, now: now, sleep: sleep,
            act: deliverKeystrokes
        )
    }

    // MARK: - Coordinate verbs (click / rightclick / doubleclick / drag / scroll)

    /// Compose a coordinate `act` verb end-to-end, reusing the SAME back half as
    /// the ref and keyboard verbs (pre-walk → act → bounded settle → diff →
    /// persist). The only differences are the "act" step — a mouse gesture at
    /// screen points delivered via `deliver` (activate + post) — and an off-screen
    /// guard: any target point outside every display is rejected (exit 1) BEFORE a
    /// single event is posted, so a bad coordinate never delivers input anywhere.
    ///
    /// `noVerify` skips BOTH walks and the session write, delivering the gesture and
    /// reporting that nothing was verified (see `UnverifiedDelivery`). Every guard
    /// that does NOT depend on the tree still applies in the same order —
    /// permission (2), target resolution (3), the off-screen guard (1), and
    /// liveness (1).
    public static func runCoordinate(
        action: PointerAction,
        appOverride: String?,
        json: Bool,
        noVerify: Bool = false,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider(),
        loadSession: (String) -> Session? = { SessionStore.load(from: $0) },
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        isRunning: (pid_t, String) -> Bool = { ActProcess.isRunning(pid: $0, bundleId: $1) },
        onScreen: (ScreenPoint) -> Bool = { ScreenBounds.isOnScreen($0) },
        rewalk: (pid_t) -> WalkResult? = { pid in BoundedWalk.run { AXTreeWalker.walk(pid: pid) } },
        deliver: (pid_t, PointerAction) throws -> Void = { pid, action in
            try LivePointerDelivery.deliver(pid: pid, action: action)
        },
        persist: (Snapshot, String, pid_t, String) throws -> Void = { snapshot, app, pid, path in
            try SessionStore.save(snapshot, app: app, pid: pid, to: path)
        },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
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

        // Deliver the gesture. Any delivery failure is a runtime error (exit 1). The
        // seam owns the activate-before-post and post-then-flush invariants, so both
        // paths below activate AND wait for delivery.
        func deliverGesture() -> ActOutcome? {
            do {
                try deliver(pid, action)
            } catch is DeliveryUnconfirmed {
                // Posted, but unacknowledged: short-circuit with the stronger
                // notice instead of walking a tree we cannot attribute.
                return .deliveredUnconfirmed(UnconfirmedDelivery.rendered(json: json))
            } catch {
                return .failed(stderr: "mtouch: failed to deliver pointer event: \(error)", code: .runtimeFailure)
            }
            return nil
        }

        // Unverified delivery: no baseline, no settle, no session write — the
        // session keeps describing the last tree that was actually READ, so a later
        // ref still means what it meant. Only the notice is reported. The delivery
        // is still FLUSHED: skipping verification is not licence to skip waiting for
        // the input to land, which is the whole reason this mode was unreliable.
        if noVerify {
            if let terminal = deliverGesture() { return terminal }
            return .deliveredUnverified(UnverifiedDelivery.rendered(json: json))
        }

        // Pre-action walk for the diff baseline. A wedged target -> bounded exit 1.
        guard let preWalk = rewalk(pid) else {
            return .failed(stderr: inputTimeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }
        // Carry the session's refs onto the pre tree so a changed element keeps its
        // ref in the diff (matching the ref/keyboard verbs' pre snapshot).
        let preSnapshot = Snapshot(roots: ScrollEnrichment.enrich(preWalk.nodes), refs: refs)

        // A right-click opens a context menu, so use the longer menu settle to let
        // its items become walkable.
        return runInputVerb(
            pid: pid, app: app, sessionPath: sessionPath,
            preSnapshot: preSnapshot, expectsMenu: action.opensMenu, json: json,
            rewalk: rewalk, persist: persist, now: now, sleep: sleep,
            act: deliverGesture
        )
    }

    // MARK: - Shared back half (act -> settle -> persist -> render)

    /// The tail every `act` verb shares once its target is resolved and its
    /// pre-action baseline (`preSnapshot`) is taken: perform the verb-specific
    /// input, bounded-settle into a diff, persist the new session BEFORE rendering,
    /// then render. `act` runs the input and returns a TERMINAL outcome to
    /// short-circuit — an AX refusal, secure input, a delivery error, or a delivery
    /// that was posted but could not be confirmed — or nil on success, so each verb
    /// keeps its own outcome mapping while the settle/persist/render invariants
    /// (persist-before-render; an unwritable path is exit 1) live in exactly one
    /// place.
    ///
    /// The settle below is a re-walk loop, never the wait for the input to arrive:
    /// by the time `act` returns nil the delivery seam has already flushed, so the
    /// walk observes a UI that has genuinely received the input rather than
    /// doubling as an accidental timer for it.
    ///
    /// Internal (not private) so the menu-path verb, which lives in its own file,
    /// composes the SAME back half instead of restating these invariants.
    static func runInputVerb(
        pid: pid_t,
        app: String,
        sessionPath: String,
        preSnapshot: Snapshot,
        expectsMenu: Bool,
        json: Bool,
        rewalk: (pid_t) -> WalkResult?,
        persist: (Snapshot, String, pid_t, String) throws -> Void,
        now: () -> TimeInterval,
        sleep: (TimeInterval) -> Void,
        act: () -> ActOutcome?
    ) -> ActOutcome {
        if let terminal = act() { return terminal }

        // Bounded re-walk until the reading is STABLE, diff against the pre tree,
        // persist the new session, then render.
        let settle = settledDiff(
            pre: preSnapshot, pid: pid, expectsMenu: expectsMenu, rewalk: rewalk, now: now, sleep: sleep
        )

        // Persist the new session BEFORE printing act-able refs: an unwritable path
        // is a failure (exit 1 naming it); we never advertise refs we could not save.
        // The persisted snapshot comes from the SAME walk as the reported diff, so a
        // ref an agent reads about is a ref it can act on.
        do {
            try persist(settle.reading.newSnapshot, app, pid, sessionPath)
        } catch {
            return .failed(stderr: saveDiagnostic(error, path: sessionPath), code: .runtimeFailure)
        }

        let rendered = json
            ? renderDiffJSON(settle.reading.diff, settled: settle.settled)
            : renderDiffText(settle.reading.diff, settled: settle.settled)
        return settle.settled ? .acted(rendered) : .actedUnsettled(rendered)
    }

    // MARK: - Post-action settle

    /// Re-walk and diff until the action's effect has STOPPED CHANGING, or the
    /// budget is spent.
    ///
    /// Returning the first NON-EMPTY diff — which is what this used to do — reads a
    /// UI mid-render and reports it as the action's effect. Measured over repeated
    /// identical runs against a real application, that surfaced diffs holding only
    /// the first character of a typed string, and diffs holding no trace of the
    /// typed text at all (one showed nothing but an unrelated toolbar element, i.e.
    /// it read as "nothing was typed" when text HAD been typed). A wrong diff is
    /// worse than no diff: it is the evidence an agent decides its next action from.
    ///
    /// So the loop settles on a reading that REPEATS instead. Each walk's tree is
    /// digested with the same `WaitDigest` helper `wait --stable` uses and folded
    /// into a `QuiescenceTracker` whose quiet window is shorter than the poll
    /// interval — so "quiet" means the digest was identical on two consecutive
    /// walks. Because the PRE tree is fixed, an unchanged post tree is an unchanged
    /// diff, which is the property that actually matters here.
    ///
    /// Three rules make the loop terminate honestly:
    ///   - It returns EARLY only on a stable, non-empty reading. An empty diff never
    ///     ends the loop, because "nothing has changed yet" is exactly the state a
    ///     slow menu, sheet, or window is in on its way to appearing.
    ///   - It is bounded by `SettleBudget.deadline` on the monotonic clock, so a UI
    ///     that never sits still (an animation, a spinner) costs a bounded amount of
    ///     time rather than blocking.
    ///   - On expiry it returns the most recent reading — the closest thing to the
    ///     truth it has, and the one whose snapshot is persisted — and says whether
    ///     that reading had settled. An all-empty run expires SETTLED: every walk
    ///     agreed the tree still equals the pre tree, which is a proven "(no
    ///     changes)", not a guess.
    ///
    /// A failed walk (the bounded walk timed out) observes nothing, so it is not
    /// evidence of a settled tree: it clears the quiet window, exactly as it does
    /// for `wait --stable`.
    static func settledDiff(
        pre: Snapshot,
        pid: pid_t,
        expectsMenu: Bool,
        rewalk: (pid_t) -> WalkResult?,
        now: () -> TimeInterval,
        sleep: (TimeInterval) -> Void
    ) -> SettleResult {
        let budget = SettleBudget.forVerb(expectsMenu: expectsMenu)
        var tracker = QuiescenceTracker(window: budget.window)

        // Baseline: identical-to-pre ⇒ "(no changes)" if every re-walk fails. It is
        // never `settled` on its own — nothing was read, so nothing was established.
        var reading = DiffEngine.diff(pre: pre, post: pre.roots)
        var stable = false

        _ = WaitPoll.poll(
            timeout: budget.deadline, interval: budget.interval, now: now, sleep: sleep
        ) {
            guard let walk = rewalk(pid) else {
                stable = tracker.observe(digest: nil, at: now())
                return false
            }
            // Thread the post walk's per-root window ids so the reconcile can detect
            // a ref whose owning window vanished/changed and let it go stale instead
            // of re-homing it onto a same-hint impostor.
            let post = ScrollEnrichment.enrich(walk.nodes)
            reading = DiffEngine.diff(pre: pre, post: post, postWindowIDsByPath: walk.windowIDsByPath)
            stable = tracker.observe(digest: WaitDigest.digest(of: post, scopedTo: nil), at: now())
            return stable && !reading.diff.isEmpty
        }

        return SettleResult(reading: reading, settled: stable)
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

    static func noMenuTargetDiagnostic() -> String {
        "mtouch: no active snapshot session, so there is no app whose menus to drive. "
            + "Run 'mtouch snapshot --app <bundleId>' first, or pass '--app <bundleId>'."
    }

    /// Unreachable from the CLI/MCP surfaces (`--of` requires `--app` before the
    /// pipeline runs); kept total so the shared app resolver never traps.
    static func noCriteriaTargetDiagnostic() -> String {
        "mtouch: --of requires --app <bundleId> to name the application whose tree the criteria "
            + "is matched in."
    }

    /// How many ambiguous matches the refusal lists before eliding the rest: enough
    /// to disambiguate a keypad, few enough that a bare-role criteria over a busy
    /// window cannot flood stderr.
    static let maxListedMatches = 8

    /// Exit 1 when the criteria matched SEVERAL actionable elements. The refusal
    /// lists each match on its snapshot-text line (role, label with its @desc/@id
    /// provenance, [disabled] where it applies) — exactly the strings a narrower
    /// criteria would quote — and says how to narrow. Nothing is acted on.
    static func ambiguousCriteriaDiagnostic(
        _ criteria: WaitCriteria, app: String, matches: [ActCriteriaSelection.Match]
    ) -> String {
        let listed = matches.prefix(maxListedMatches).map { SnapshotText.line(for: $0.node, ref: nil, indent: 0) }
        var message = "mtouch: \(criteria.description) matches \(matches.count) actionable elements in "
            + "'\(app)'; acting on one of them would be a guess, so nothing was acted on. Matches: "
            + listed.joined(separator: "; ")
        if matches.count > listed.count {
            message += "; ... and \(matches.count - listed.count) more"
        }
        return message + ". Narrow the criteria — quote a longer label, or the element's @id "
            + "identifier — so exactly one element matches."
    }

    /// Exit 1 when no ACTIONABLE element matched. Echoes the criteria, summarizes
    /// what WAS seen (the same summary a wait timeout reports), and advises the
    /// same next steps as `read --of`'s zero-match diagnostic. A criteria that
    /// matched only non-actionable elements (a static text, an inert group) says
    /// so — that is a different correction than "no such element".
    static func noCriteriaMatchDiagnostic(
        _ criteria: WaitCriteria, app: String, roots: [AXNode], nonActionable: Int
    ) -> String {
        var message = "mtouch: no actionable element matching \(criteria.description) in '\(app)'."
        if nonActionable > 0 {
            message += " The criteria matched \(nonActionable) non-actionable element(s), which the "
                + "act verbs cannot target."
        }
        return message + " Last seen: \(WaitPipeline.lastSeenSummary(roots)). "
            + "Check the criteria against 'mtouch snapshot --app \(app)', or wait for the element "
            + "first with 'mtouch wait --app \(app) --appears <criteria>'. Nothing was acted on."
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

    /// The same bounded-timeout report, plus the way FORWARD — which is the whole
    /// difference between an agent that self-corrects and one that gives up.
    ///
    /// The commonest cause is not a hung application but a modal panel: its nested
    /// event loop blocks the owning process's accessibility server, so every read
    /// of the tree times out while the panel itself is perfectly responsive to
    /// input. CGEvent delivery needs no tree, so the input verbs can still drive it
    /// under `--no-verify`. Every verb that DELIVERS input reports this form; a
    /// read reports the plain one, since it has no input to fall back to.
    static func inputTimeoutDiagnostic(app: String, pid: pid_t) -> String {
        timeoutDiagnostic(app: app, pid: pid)
            + " If the target is showing a modal panel, retry with --no-verify on an input verb ("
            + UnverifiedDelivery.verbs.joined(separator: ", ")
            + ") to deliver input without an accessibility diff."
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
