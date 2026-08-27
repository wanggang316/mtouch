import Foundation

/// The observable outcome of an `app` invocation, kept SEPARATE from the side
/// effects (printing, exiting) so every exit-code mapping is unit-testable.
/// `.reported` carries the stdout line (the pid, or the JSON object); `.failed`
/// carries the stderr diagnostic and its exit code. A failure NEVER carries
/// stdout, so `--json` stays clean on every error path.
public enum AppOutcome: Equatable, Sendable {
    case reported(String)
    case failed(stderr: String, code: MTouchExitCode)
}

/// Composes the three `app` lifecycle verbs — launch, activate, quit — on top of
/// the `WorkspaceControl` seam and the shared `WaitPoll` engine.
///
/// Two rules shape the whole surface:
///
///   1. NOTHING IS REPORTED UNVERIFIED. An activation request is asynchronous and
///      routinely lost when the caller's own terminal is foreground, so `activate`
///      polls `frontmostPID()` until the target really holds the foreground and
///      fails (exit 1) if it never does — a silent "activated" that did not take
///      the foreground is exactly what makes later keyboard delivery land in the
///      wrong app. `quit` likewise polls the process away rather than trusting
///      `terminate()`, and `launch --wait-ready` polls until the app reports a
///      window rather than assuming a launched process is usable.
///   2. EVERY WAIT IS A POLL, never a sleep: each verb drives `WaitPoll` over an
///      injected clock, so the timing bounds are asserted under a fake clock and
///      no fixed delay is baked into any path.
public enum AppLifecycle {
    /// An intermediate step's result: the value it produced, or a terminal outcome
    /// the caller returns as-is. Mirrors `ActPipeline`'s `Target`/`KeyboardTarget`
    /// split so a failing step short-circuits without an error type that would have
    /// to be invented for a value that is already a complete outcome.
    enum Step<Value> {
        case value(Value)
        case terminal(AppOutcome)
    }

    /// How long a launch may take to produce a process when `--wait-ready` is not
    /// given. A pid must be reported, so the launch is bounded even without an
    /// explicit readiness budget.
    public static let launchBudget: TimeInterval = 10
    /// How long `activate` waits for the target to actually become frontmost.
    public static let activateBudget: TimeInterval = 2
    /// Default graceful-quit budget.
    public static let quitBudget: TimeInterval = 10
    /// Extra budget granted to the FORCED kill after a graceful quit expired. A
    /// forced termination is immediate, so this only covers process teardown.
    public static let forceBudget: TimeInterval = 2
    /// Poll interval shared by every lifecycle wait.
    static let pollInterval: TimeInterval = 0.05

    // MARK: - launch

    /// Launch (or adopt) an application and report its pid.
    ///
    /// An ALREADY-RUNNING instance is never relaunched: it is activated and its pid
    /// reported with `launched: false`, so re-running a launch step is idempotent
    /// rather than spawning a second instance. `waitReady`, when present, additionally
    /// polls until the process both is running and reports at least one accessibility
    /// window — the point at which a snapshot can actually see something — and
    /// expires as a wait timeout (exit 4), matching `mtouch wait`.
    public static func launch(
        bundleId: String,
        waitReady: TimeInterval?,
        json: Bool,
        workspace: WorkspaceControl = LiveWorkspaceControl(),
        permissions: PermissionProvider = LivePermissionProvider(),
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> AppOutcome {
        // Readiness is judged by an ACCESSIBILITY read, so `--wait-ready` needs the
        // grant. Check it first (exit 2) — without it every readiness probe would
        // fail and the command would blame a timeout for a permission problem.
        if waitReady != nil, !permissions.accessibilityGranted {
            return .failed(
                stderr: PermissionError(permission: .accessibility).diagnostic,
                code: .permissionMissing
            )
        }

        let deadline = now() + (waitReady ?? launchBudget)
        let running = workspace.runningPIDs(bundleId: bundleId)
        if running.count > 1 {
            // Several live instances: which one "the" app is, is undefined, so refuse
            // and name the candidates — the same "refuse, do not guess" rule target
            // resolution applies, with the recovery this verb actually supports
            // (launch takes no --pid; activate does).
            return .failed(
                stderr: ambiguousInstanceDiagnostic(bundleId: bundleId, pids: running),
                code: .runtimeFailure
            )
        }

        let pid: pid_t
        let launched: Bool
        if let existing = running.first {
            pid = existing
            launched = false
        } else {
            switch start(bundleId: bundleId, deadline: deadline, workspace: workspace, now: now, sleep: sleep) {
            case let .terminal(outcome): return outcome
            case let .value(started): pid = started
            }
            launched = true
        }

        // Best effort: bring the app forward so a following step acts on a visible
        // window. Deliberately NOT verified here — `app activate` is the verified
        // path, and failing a successful launch over a lost focus race would be worse
        // than reporting the pid the caller asked for.
        workspace.activate(pid: pid)

        if let waitReady {
            let ready = WaitPoll.poll(
                timeout: max(0, deadline - now()), interval: pollInterval, now: now, sleep: sleep
            ) {
                workspace.isRunning(pid: pid) && (workspace.axWindowCount(pid: pid) ?? 0) >= 1
            }
            guard ready.met else {
                return .failed(
                    stderr: notReadyDiagnostic(bundleId: bundleId, pid: pid, timeout: waitReady),
                    code: .waitTimeout
                )
            }
        }

        return .reported(launchOutput(pid: pid, bundleId: bundleId, launched: launched, json: json))
    }

    /// Request the launch and poll until the process exists. Split out so `launch`
    /// reads as the policy it is. Returns the new pid, or the terminal outcome.
    private static func start(
        bundleId: String,
        deadline: TimeInterval,
        workspace: WorkspaceControl,
        now: () -> TimeInterval,
        sleep: (TimeInterval) -> Void
    ) -> Step<pid_t> {
        guard let url = workspace.applicationURL(bundleId: bundleId) else {
            return .terminal(.failed(stderr: notInstalledDiagnostic(bundleId: bundleId), code: .runtimeFailure))
        }

        let launchFailure = workspace.requestLaunch(at: url)
        var reportedFailure: String?
        // Reported as the BUDGET, not the elapsed time: a caller can act on "15s was
        // not enough", while a raw elapsed reading is just noise.
        let budget = max(0, deadline - now())
        let appeared = WaitPoll.poll(
            timeout: budget, interval: pollInterval, now: now, sleep: sleep
        ) {
            // A reported launch failure ends the poll immediately: waiting out the
            // budget would report a timeout for a launch the system already refused.
            if let reason = launchFailure() {
                reportedFailure = reason
                return true
            }
            return !workspace.runningPIDs(bundleId: bundleId).isEmpty
        }

        if let reportedFailure {
            return .terminal(.failed(
                stderr: launchFailedDiagnostic(bundleId: bundleId, reason: reportedFailure),
                code: .runtimeFailure
            ))
        }
        guard appeared.met, let started = workspace.runningPIDs(bundleId: bundleId).first else {
            return .terminal(.failed(
                stderr: didNotStartDiagnostic(bundleId: bundleId, budget: budget),
                code: .waitTimeout
            ))
        }
        return .value(started)
    }

    // MARK: - activate

    /// Bring an application frontmost and VERIFY it got there.
    ///
    /// The request is asynchronous and is regularly lost to the invoking terminal,
    /// so success is defined as `frontmostPID()` actually reporting the target
    /// within `timeout`; otherwise this is exit 1 naming whatever holds the
    /// foreground instead. Reporting an unverified activation would leave the caller
    /// believing keystrokes will land in this app when they will not.
    ///
    /// Both halves — the activation itself and the check that it took — go through
    /// the accessibility API, so the grant is required (exit 2). Without it the
    /// check could only ever fail, and blaming that on a lost focus race would send
    /// the caller looking in entirely the wrong place.
    public static func activate(
        bundleId: String,
        json: Bool,
        timeout: TimeInterval = activateBudget,
        workspace: WorkspaceControl = LiveWorkspaceControl(),
        permissions: PermissionProvider = LivePermissionProvider(),
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> AppOutcome {
        guard permissions.accessibilityGranted else {
            return .failed(
                stderr: PermissionError(permission: .accessibility).diagnostic,
                code: .permissionMissing
            )
        }

        let pid: pid_t
        switch resolve(bundleId: bundleId, resolvePID: resolvePID) {
        case let .terminal(outcome): return outcome
        case let .value(resolved): pid = resolved
        }

        workspace.activate(pid: pid)
        let result = WaitPoll.poll(timeout: timeout, interval: pollInterval, now: now, sleep: sleep) {
            workspace.frontmostPID() == pid
        }
        guard result.met else {
            let holder = workspace.frontmostPID()
            return .failed(
                stderr: notFrontmostDiagnostic(
                    bundleId: bundleId, pid: pid, timeout: timeout,
                    holder: holder, holderBundleId: holder.flatMap { workspace.bundleId(ofPID: $0) }
                ),
                code: .runtimeFailure
            )
        }

        return .reported(activateOutput(pid: pid, bundleId: bundleId, json: json))
    }

    // MARK: - quit

    /// Quit an application, polling until its process is actually gone.
    ///
    /// DESTRUCTIVE: quitting discards unsaved work. Two guards bound the damage —
    /// mtouch refuses to target its OWN process or any ancestor (the terminal that
    /// invoked it), which would kill the command mid-run; and a forced kill NEVER
    /// happens implicitly: `force` only escalates AFTER a graceful quit has been
    /// asked for and the process outlived `timeout`.
    public static func quit(
        bundleId: String,
        force: Bool,
        timeout: TimeInterval = quitBudget,
        json: Bool,
        workspace: WorkspaceControl = LiveWorkspaceControl(),
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        selfPID: pid_t = getpid(),
        parentOf: (pid_t) -> pid_t? = { ProcessAncestry.liveParent(of: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> AppOutcome {
        let pid: pid_t
        switch resolve(bundleId: bundleId, resolvePID: resolvePID) {
        case let .terminal(outcome): return outcome
        case let .value(resolved): pid = resolved
        }

        guard !ProcessAncestry.isSelfOrAncestor(pid, of: selfPID, parentOf: parentOf) else {
            return .failed(stderr: selfTargetDiagnostic(bundleId: bundleId, pid: pid), code: .runtimeFailure)
        }

        // Ask politely first, ALWAYS — even with --force, so the app gets its chance
        // to save. A refused request without --force is reported rather than escalated.
        let asked = workspace.terminate(pid: pid, force: false)
        if !asked, !force {
            return .failed(stderr: quitRefusedDiagnostic(bundleId: bundleId, pid: pid), code: .runtimeFailure)
        }

        var gone = WaitPoll.poll(timeout: timeout, interval: pollInterval, now: now, sleep: sleep) {
            !workspace.isRunning(pid: pid)
        }.met

        var forced = false
        if !gone, force {
            forced = true
            _ = workspace.terminate(pid: pid, force: true)
            gone = WaitPoll.poll(timeout: forceBudget, interval: pollInterval, now: now, sleep: sleep) {
                !workspace.isRunning(pid: pid)
            }.met
        }

        guard gone else {
            return forced
                ? .failed(stderr: forceFailedDiagnostic(bundleId: bundleId, pid: pid), code: .runtimeFailure)
                : .failed(
                    stderr: stillRunningDiagnostic(bundleId: bundleId, pid: pid, timeout: timeout),
                    code: .waitTimeout
                )
        }
        return .reported(quitOutput(pid: pid, bundleId: bundleId, forced: forced, json: json))
    }

    // MARK: - Shared target resolution

    /// Resolve the bundle id (honoring an explicit `--pid` through the same seam
    /// every other command uses), mapping each failure to its own exit code.
    private static func resolve(
        bundleId: String, resolvePID: (String) throws -> pid_t
    ) -> Step<pid_t> {
        do {
            return .value(try resolvePID(bundleId))
        } catch let error as MTouchDiagnosticError {
            return .terminal(.failed(stderr: error.message, code: error.exitCode))
        } catch {
            return .terminal(.failed(
                stderr: "mtouch: could not resolve application '\(bundleId)': \(error)",
                code: .runtimeFailure
            ))
        }
    }

    // MARK: - Rendering

    static func launchOutput(pid: pid_t, bundleId: String, launched: Bool, json: Bool) -> String {
        guard json else { return "\(pid)" }
        return "{\"pid\":\(pid),\"bundleId\":\(JSONText.string(bundleId)),\"launched\":\(launched)}"
    }

    static func activateOutput(pid: pid_t, bundleId: String, json: Bool) -> String {
        guard json else { return "\(pid)" }
        return "{\"pid\":\(pid),\"bundleId\":\(JSONText.string(bundleId)),\"frontmost\":true}"
    }

    static func quitOutput(pid: pid_t, bundleId: String, forced: Bool, json: Bool) -> String {
        guard json else { return "\(pid)" }
        return "{\"pid\":\(pid),\"bundleId\":\(JSONText.string(bundleId)),"
            + "\"terminated\":true,\"forced\":\(forced)}"
    }

    // MARK: - Diagnostics

    static func notInstalledDiagnostic(bundleId: String) -> String {
        "mtouch: no application with bundle identifier '\(bundleId)' is installed. "
            + "Check the identifier ('mtouch apps' lists the running ones)."
    }

    static func ambiguousInstanceDiagnostic(bundleId: String, pids: [pid_t]) -> String {
        let candidates = pids.map(String.init).joined(separator: ", ")
        return "mtouch: '\(bundleId)' is already running as \(pids.count) processes (\(candidates)); "
            + "mtouch will not choose between them. Bring one forward with "
            + "'mtouch app activate --app \(bundleId) --pid <pid>'; 'mtouch apps' lists them."
    }

    static func launchFailedDiagnostic(bundleId: String, reason: String) -> String {
        "mtouch: could not launch '\(bundleId)': \(reason)"
    }

    static func didNotStartDiagnostic(bundleId: String, budget: TimeInterval) -> String {
        "mtouch: '\(bundleId)' was asked to launch but no process appeared within "
            + "\(WaitPipeline.formatDuration(budget)). The application may have failed to start; "
            + "check it manually or retry with a longer --wait-ready."
    }

    static func notReadyDiagnostic(bundleId: String, pid: pid_t, timeout: TimeInterval) -> String {
        "mtouch: '\(bundleId)' (pid \(pid)) did not report a window within "
            + "\(WaitPipeline.formatDuration(timeout)). It may still be starting up, or it may not "
            + "expose its windows over the accessibility API. Retry with a longer --wait-ready."
    }

    static func notFrontmostDiagnostic(
        bundleId: String, pid: pid_t, timeout: TimeInterval, holder: pid_t?, holderBundleId: String?
    ) -> String {
        let foreground: String
        switch (holder, holderBundleId) {
        case let (pid?, id?): foreground = "pid \(pid) ('\(id)') holds it"
        case let (pid?, nil): foreground = "pid \(pid) holds it"
        default: foreground = "no application reports holding it"
        }
        return "mtouch: '\(bundleId)' (pid \(pid)) did not become frontmost within "
            + "\(WaitPipeline.formatDuration(timeout)); \(foreground). Another application may be "
            + "holding focus (a modal dialog, or the invoking terminal). Nothing was typed or clicked."
    }

    static func selfTargetDiagnostic(bundleId: String, pid: pid_t) -> String {
        "mtouch: refusing to quit '\(bundleId)' (pid \(pid)): it is this mtouch process or one of its "
            + "ancestors (the terminal it was invoked from), so quitting it would kill this command. "
            + "Quit it from outside mtouch if that is really what you want."
    }

    static func quitRefusedDiagnostic(bundleId: String, pid: pid_t) -> String {
        "mtouch: '\(bundleId)' (pid \(pid)) refused the quit request. Pass --force to terminate it "
            + "(unsaved work will be lost)."
    }

    static func stillRunningDiagnostic(bundleId: String, pid: pid_t, timeout: TimeInterval) -> String {
        "mtouch: '\(bundleId)' (pid \(pid)) was asked to quit but was still running after "
            + "\(WaitPipeline.formatDuration(timeout)). It may be showing a save/confirm dialog — "
            + "handle it, or pass --force to terminate it (unsaved work will be lost)."
    }

    static func forceFailedDiagnostic(bundleId: String, pid: pid_t) -> String {
        "mtouch: '\(bundleId)' (pid \(pid)) survived a forced termination. The process may be "
            + "unkillable from this session; inspect it with 'mtouch apps'."
    }
}
