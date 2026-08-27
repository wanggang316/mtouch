import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Everything the `app` lifecycle commands need from the system, behind ONE seam
/// so launch/activate/quit are unit-testable without launching or killing a real
/// application. Every method is a single, narrow question or request; no method
/// blocks or sleeps — the pipeline owns all waiting (via `WaitPoll`), so timing is
/// deterministic under a fake clock.
public protocol WorkspaceControl {
    /// Filesystem location of the INSTALLED application, nil when the bundle id
    /// resolves to nothing (never installed / removed).
    func applicationURL(bundleId: String) -> URL?

    /// Pids of every running instance of the bundle id, ascending. Several
    /// instances can share a bundle id, so the caller refuses rather than guesses.
    func runningPIDs(bundleId: String) -> [pid_t]

    /// Bundle id of a running process, nil when it has none or is gone. Used only
    /// to make a diagnostic name the process that actually holds the foreground.
    func bundleId(ofPID pid: pid_t) -> String?

    /// Ask the system to launch the application at `url`. Returns a probe that
    /// reports the launch failure reason once the system reports one (nil while the
    /// launch is still in flight, or when it succeeded) — the caller polls it
    /// alongside `runningPIDs`, so a launch that CANNOT complete fails fast with the
    /// system's reason instead of burning the whole budget and blaming a timeout.
    func requestLaunch(at url: URL) -> () -> String?

    /// Ask the window server to bring `pid` frontmost. Asynchronous by nature: the
    /// caller VERIFIES the effect via `frontmostPID()` rather than trusting it.
    func activate(pid: pid_t)

    /// Pid of the application that currently has the foreground — i.e. the one an
    /// unqualified keystroke would reach. nil when it cannot be determined.
    func frontmostPID() -> pid_t?

    /// Number of windows the process reports over the accessibility API; nil when
    /// the read was REFUSED (a hung/opaque process), which is not "zero windows".
    func axWindowCount(pid: pid_t) -> Int?

    /// Whether the pid still belongs to a live (non-terminated) application.
    func isRunning(pid: pid_t) -> Bool

    /// Ask the application to quit (`force: false`) or kill it (`force: true`).
    /// Returns whether the REQUEST was accepted — never whether the process is
    /// gone, which the caller establishes by polling `isRunning`.
    func terminate(pid: pid_t, force: Bool) -> Bool
}

/// Live `WorkspaceControl` over LaunchServices / NSRunningApplication / the
/// accessibility API.
///
/// Every observation here must be a FRESH query, because this seam is POLLED.
/// `NSWorkspace`'s `runningApplications` and `frontmostApplication` properties are
/// snapshots refreshed by notifications delivered to the MAIN RUN LOOP, which a
/// one-shot CLI never runs: measured on this machine, a launched process never
/// appeared in `runningApplications`, and an application switch was never observed
/// through `frontmostApplication`, no matter how long the loop polled. Both would
/// have failed CLOSED — reporting a healthy launch as a timeout and a successful
/// activation as a lost race — so neither is used. The replacements below query
/// their source directly on every call.
public struct LiveWorkspaceControl: WorkspaceControl {
    public init() {}

    public func applicationURL(bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    /// Asks LaunchServices directly (rather than reading NSWorkspace's cached
    /// list), so a process that appeared MID-POLL is actually seen.
    public func runningPIDs(bundleId: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .map(\.processIdentifier)
            .sorted()
    }

    public func bundleId(ofPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func requestLaunch(at url: URL) -> () -> String? {
        let box = LaunchFailureBox()
        let configuration = NSWorkspace.OpenConfiguration()
        // Launching implies wanting the app usable, so let LaunchServices bring it
        // forward; `app activate` remains the VERIFIED way to take the foreground.
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            // Only the reason is retained: `NSRunningApplication` is not Sendable and
            // the pid is discovered by polling anyway.
            if let error { box.set(error.localizedDescription) }
        }
        return { box.get() }
    }

    public func activate(pid: pid_t) {
        // Reuses the two-mechanism activation the input verbs rely on (AX frontmost
        // write + forceful activate), with its internal settle disabled: the caller
        // polls for the effect instead of sleeping a fixed amount.
        FrontmostActivation.bringToFront(pid: pid, settle: 0)
    }

    /// The FOCUSED application according to the accessibility system — a live
    /// query, and the precise question an activation check is asking: which
    /// application would receive a keystroke right now. Requires the Accessibility
    /// grant (the callers preflight it), which mtouch already requires to activate
    /// anything in the first place.
    public func frontmostPID() -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value
        ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }

    public func axWindowCount(pid: pid_t) -> Int? {
        switch AXWindowEnumerator.windows(ofPID: pid) {
        case let .success(windows): return windows.count
        case .failure: return nil
        }
    }

    public func isRunning(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    public func terminate(pid: pid_t, force: Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return force ? app.forceTerminate() : app.terminate()
    }

    /// One-shot cell for the launch completion's failure reason, crossing from
    /// LaunchServices' callback queue to the polling thread under a lock.
    private final class LaunchFailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reason: String?
        func set(_ value: String) { lock.lock(); reason = value; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return reason }
    }
}

/// Whether a pid is THIS process or one of its ancestors — the guard that stops a
/// destructive `app quit` from killing mtouch itself or the terminal that invoked
/// it (which would take mtouch down with it, mid-command).
///
/// The walk is pure over an injected `parentOf`, so every case (self, parent,
/// grandparent, unrelated, and a malformed parent CYCLE) is table-testable without
/// spawning processes.
public enum ProcessAncestry {
    /// Ceiling on the walk. A real process chain is a handful of hops; the cap
    /// makes a malformed/cyclic parent chain terminate instead of spinning.
    static let maxHops = 64

    public static func isSelfOrAncestor(
        _ candidate: pid_t,
        of start: pid_t,
        parentOf: (pid_t) -> pid_t?
    ) -> Bool {
        var current = start
        for _ in 0...maxHops {
            if current == candidate { return true }
            guard let parent = parentOf(current), parent > 0, parent != current else { return false }
            current = parent
        }
        return false
    }

    /// Live parent pid via `sysctl(KERN_PROC_PID)`; nil when the process is gone or
    /// has no parent (pid 1). Read-only and not TCC-gated.
    public static func liveParent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
