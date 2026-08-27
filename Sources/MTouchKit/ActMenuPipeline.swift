import Foundation

/// The `act menu` verb: invoke a menu-bar command by title path.
///
/// It is composed from the SAME parts as every other act verb — resolve target →
/// pre-walk → act → bounded settle → diff → persist — so its output, exit codes,
/// and session behaviour are indistinguishable from `press`/`type`/`click`. Only
/// the "act" step differs: a `MenuPathResolver` walk down the application's menu
/// bar instead of one action on one element.
public extension ActPipeline {
    /// Drive `path` through the target application's menu bar and report the
    /// resulting diff.
    ///
    /// The target is brought frontmost BEFORE the pre-action walk, for two reasons:
    /// only the frontmost application's menu bar is actually drawn (a background
    /// app's menu may refuse to open), and taking the baseline afterwards keeps the
    /// diff about the menu COMMAND rather than about the activation.
    static func runMenu(
        path: MenuPath,
        appOverride: String?,
        json: Bool,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider(),
        loadSession: (String) -> Session? = { SessionStore.load(from: $0) },
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        isRunning: (pid_t, String) -> Bool = { ActProcess.isRunning(pid: $0, bundleId: $1) },
        activate: (pid_t) -> Void = { FrontmostActivation.bringToFront(pid: $0) },
        rewalk: (pid_t) -> WalkResult? = { pid in BoundedWalk.run { AXTreeWalker.walk(pid: pid) } },
        invoke: (pid_t, MenuPath) -> Result<Void, MenuPathError> = { pid, path in
            MenuPathResolver.invokeLive(pid: pid, path: path)
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
        switch resolveMenuTarget(
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

        activate(pid)

        // Pre-action walk for the diff baseline. A wedged target -> bounded exit 1.
        guard let preWalk = rewalk(pid) else {
            return .failed(stderr: inputTimeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }
        // Carry the session's refs onto the pre tree so a surviving element keeps its
        // ref in the diff (matching the other verbs' pre snapshot).
        let preSnapshot = Snapshot(roots: ScrollEnrichment.enrich(preWalk.nodes), refs: refs)

        return runInputVerb(
            pid: pid, app: app, sessionPath: sessionPath,
            // A menu command routinely opens a window, sheet, or dialog, which takes
            // longer to appear than an in-place change: use the longer menu settle so
            // the diff reports what the command actually did.
            preSnapshot: preSnapshot, expectsMenu: true, json: json,
            rewalk: rewalk, persist: persist, now: now, sleep: sleep
        ) {
            guard case let .failure(error) = invoke(pid, path) else { return nil }
            // The unreadable-menu-bar case is the one failure the resolver cannot
            // describe on its own — it has no idea which application it was given —
            // so it is named here, where the app and pid are known.
            if error.reason == .menuBarUnreadable {
                return .failed(stderr: menuBarDiagnostic(app: app, pid: pid), code: .runtimeFailure)
            }
            return .failed(stderr: error.message, code: error.exitCode)
        }
    }

    static func menuBarDiagnostic(app: String, pid: pid_t) -> String {
        "mtouch: could not read the menu bar of '\(app)' (pid \(pid)). The application may expose no "
            + "menu bar, or its accessibility interface may be unavailable — 'mtouch doctor' checks "
            + "the permission, and 'mtouch snapshot' shows what it does expose."
    }
}
