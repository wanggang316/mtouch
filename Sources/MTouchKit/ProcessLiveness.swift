import Darwin
import Foundation

/// Answers "is pid N still running?" directly from the kernel, via `kill(pid, 0)`.
///
/// This exists because "your target application DIED" and "that element went
/// away" demand opposite recoveries — relaunch versus re-snapshot — and the AX
/// layer cannot tell them apart: a dead process and a wedged one both read as
/// timeouts, empty trees, and `cannotComplete` errors. The pipelines consult this
/// probe ONLY when a read has already failed, so the happy path never pays for
/// it, and a failure can finally say which of the two situations it is.
///
/// `kill(pid, 0)` rather than an NSWorkspace lookup, deliberately:
///   - it is a single non-blocking syscall (never a `waitpid`, which could block
///     or reap), safe against any foreign pid;
///   - it has no bookkeeping lag: the workspace's running-application list is
///     updated asynchronously, so for a few moments after an exit it can still
///     report the dead process as alive — exactly the window in which this
///     probe is consulted.
public enum ProcessLiveness {
    /// Whether a process with `pid` exists right now.
    ///
    /// `kill(pid, 0)` delivers no signal; it only performs the existence and
    /// permission checks. Three outcomes:
    ///   - `0`      — the process exists and is signalable: ALIVE (unless it is
    ///     a zombie — see below).
    ///   - `EPERM`  — the process exists but belongs to another user: ALIVE.
    ///     (Treating this as dead would misdiagnose every root-owned target.)
    ///   - `ESRCH`  — no such process: GONE.
    ///
    /// A ZOMBIE — exited but not yet reaped — counts as GONE despite answering
    /// `kill` with 0: it has no threads and no accessibility server, so for
    /// every question this probe serves it is already dead. The refinement is
    /// measured, not theoretical: a SIGKILLed app lingers as a zombie for tens
    /// of milliseconds, which is precisely the window in which a mid-command
    /// failure path consults this probe.
    ///
    /// KNOWN LIMIT: for the first ~15–50ms after a SIGKILL the kernel's proc
    /// entry can still read as RUNNING (teardown precedes the zombie state), so
    /// a consult landing inside that window reports alive and the caller keeps
    /// its ordinary diagnostic. A polling caller (`wait`) self-heals on its next
    /// poll; a one-shot caller simply misses the nicety for that one race. The
    /// alternative — sleeping and re-probing — would put a delay inside a probe
    /// that pollers rely on being instant, so the window is accepted instead.
    ///
    /// Non-positive pids are refused as "not alive" rather than probed: with
    /// `pid <= 0`, `kill` addresses a process GROUP, which would answer a
    /// different question entirely.
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return !isZombie(pid) }
        return errno == EPERM
    }

    /// Whether the (existing) process is a zombie, read from the kernel's proc
    /// table via `sysctl` — a single non-blocking call, and NEVER `waitpid`
    /// (which could block, or worse, reap a child that is not ours to reap).
    /// An unreadable entry defaults to "not a zombie": the conservative answer,
    /// which leaves the caller's existing (alive-shaped) diagnostic in place.
    static func isZombie(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride else {
            return false
        }
        return Int32(info.kp_proc.p_stat) == SZOMB
    }
}

/// The app-gone diagnosis: one pinned message and one trajectory class for
/// "the target process is no longer running", shared by every surface that can
/// discover it (act, read, wait, snapshot, windows).
///
/// Pinned taxonomy: app-gone is exit 1 (`runtimeFailure`), consistent with
/// `AppNotRunningError` at resolution time — never exit 3, which tells an agent
/// a re-snapshot would help (it will not: the refs died with the process), and
/// never exit 4, which tells it waiting longer would.
public enum AppGone {
    /// The distinct trajectory `errorClass` for an app-gone failure, so records
    /// are machine-distinguishable from the generic `runtime` class (an agent
    /// replaying a trajectory can tell "relaunch" from "retry"). Same style as
    /// the exit-code vocabulary in `MTouchExitCode.trajectoryErrorClass`.
    public static let errorClass = "app-gone"

    /// The pinned stderr message: names the pid and bundle id, states the
    /// process is no longer running, and gives the only recovery that can work —
    /// relaunching, then re-snapshotting (the old session's refs are dead).
    public static func diagnostic(app: String, pid: pid_t) -> String {
        "mtouch: application '\(app)' (pid \(pid)) is no longer running. "
            + "Relaunch it with 'mtouch app launch --app \(app)' and re-run "
            + "'mtouch snapshot' to get fresh references."
    }

    /// Whether `stderr` is the app-gone diagnosis. Used by the trajectory
    /// mapping, which sees only `(stderr, exit code)` and must not classify the
    /// resolution-time "is not running" refusal (a different, pre-launch fact)
    /// as a mid-command death.
    public static func describes(_ stderr: String) -> Bool {
        stderr.hasPrefix("mtouch: application '") && stderr.contains(") is no longer running.")
    }
}
