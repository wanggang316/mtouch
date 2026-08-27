import Foundation

/// The observable outcome of a `wait` invocation, kept SEPARATE from the side
/// effects (stderr, exit) so the exit-code mapping is unit-testable. Success is
/// silent (no stdout): the exit code IS the signal an agent scripts against.
public enum WaitOutcome: Equatable, Sendable {
    /// The condition held within the timeout; exit 0.
    case satisfied
    /// A stderr diagnostic paired with its non-zero exit code.
    case failed(stderr: String, code: MTouchExitCode)
}

/// Composes `wait` end-to-end: accessibility preflight → resolve bundle id to a
/// running pid → bounded poll of the AX tree until the condition holds or the
/// timeout expires → verdict. Wait only OBSERVES; it never delivers input, so it
/// is unaffected by the frontmost-contention issue that degrades act probes.
///
/// Precedence is encoded by ORDER, matching the rest of the CLI: the usage-error
/// grammar (exit 64) is rejected by the command layer BEFORE this runs; here the
/// permission gate (exit 2) precedes app resolution (exit 1), which precedes the
/// poll (exit 0 on success, exit 4 on timeout). App-not-running and a missing
/// grant both fail FAST — neither ever burns the timeout or masquerades as one.
///
/// Each collaborator is injectable so the whole flow — including the timing
/// bounds — is exercised without any AX/TCC access; the live defaults wire the
/// real ones (a `GuardedWalk` so a hung target cannot leak threads across polls).
public enum WaitPipeline {
    public static func run(
        bundleId: String,
        condition: WaitCondition,
        timeout: TimeInterval,
        interval: TimeInterval,
        permissions: PermissionProvider = LivePermissionProvider(),
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        makeProbe: (pid_t, TimeInterval) -> () -> [AXNode]? = { pid, deadline in
            let guarded = GuardedWalk(deadline: deadline, work: { AXTreeWalker.walk(pid: pid).nodes })
            return { guarded.sample() }
        }
    ) -> WaitOutcome {
        // 1. Preflight FIRST (exit 2): a missing grant fails fast with the
        //    doctor-pointing diagnostic, never masquerading as a timeout.
        guard permissions.accessibilityGranted else {
            return .failed(
                stderr: PermissionError(permission: .accessibility).diagnostic,
                code: .permissionMissing
            )
        }

        // 2. Resolve the bundle id to a running pid. A non-running, ambiguous, or
        //    self-contradictory target is not wait-able: fail immediately rather
        //    than burning the timeout, with the exit code the failure carries (1 for
        //    a missing/ambiguous target, 64 for a `--pid` that contradicts `--app`).
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

        // 3. Poll the tree. The probe walks (guarded, single-flight) and evaluates
        //    the condition; the last successful walk is retained for a rich timeout
        //    diagnostic. A failed/hung walk counts as "not met" and keeps polling.
        //
        //    Cap the guarded walk's per-sample deadline to the wait's OWN budget.
        //    `GuardedWalk.sample()` BLOCKS the first poll up to `deadline`, so the
        //    stock 8s ceiling would let a hung/SIGSTOPped target overshoot a short
        //    `--timeout 1s` by ~8× before the poll can observe its own timeout.
        //    - `min(defaultDeadline, …)` keeps the 8s ceiling for long waits.
        //    - `max(timeout, 1.0)` floors it so a healthy walk (tens of ms) still
        //      gets a fair ≥1s window; without the floor a `--timeout 0` (or
        //      sub-100ms) wait would starve even a healthy walk and regress the
        //      "timeout 0 yields exactly one satisfiable check" behavior.
        let walkDeadline = min(BoundedWalk.defaultDeadline, max(timeout, 1.0))
        let probe = makeProbe(pid, walkDeadline)
        var lastSeen: [AXNode]?
        let result = WaitPoll.poll(timeout: timeout, interval: interval, now: now, sleep: sleep) {
            guard let nodes = probe() else { return false }
            lastSeen = nodes
            return WaitEvaluator.evaluate(condition, in: nodes)
        }

        if result.met { return .satisfied }
        return .failed(
            stderr: timeoutDiagnostic(condition: condition, timeout: timeout, lastSeen: lastSeen),
            code: .waitTimeout
        )
    }

    // MARK: - Diagnostics

    /// The exit-4 timeout message: echoes the criteria, the timeout used, and a
    /// short summary of what WAS visible — rich enough to correct the criteria
    /// without a blind retry.
    static func timeoutDiagnostic(condition: WaitCondition, timeout: TimeInterval, lastSeen: [AXNode]?) -> String {
        "mtouch: wait timed out after \(formatDuration(timeout)) waiting for \(condition.description). "
            + "Last seen: \(lastSeenSummary(lastSeen))."
    }

    /// Compact description of the most recently walked tree: element count, the
    /// most common roles, and any window titles — the correction hints an agent
    /// needs. Nothing walked ⇒ says so explicitly.
    static func lastSeenSummary(_ roots: [AXNode]?) -> String {
        guard let roots, !roots.isEmpty else {
            return "nothing (no elements were read from the application)"
        }
        let all = roots.flatMap(\.flattened)
        let roleCounts = Dictionary(grouping: all, by: \.role).mapValues(\.count)
        let topRoles = roleCounts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6)
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: ", ")

        var parts = ["\(all.count) element(s)", "roles: \(topRoles)"]
        let titles = roots.compactMap { $0.title }.filter { !$0.isEmpty }.prefix(4)
        if !titles.isEmpty {
            parts.append("window titles: " + titles.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }

    /// Render a duration back to its friendliest form for diagnostics: whole
    /// seconds as `2s`, sub-second as `500ms`, else the decimal seconds.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds == seconds.rounded() { return "\(Int(seconds))s" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        return "\(seconds)s"
    }
}
