import AppKit

/// Brings a target application frontmost. CGEvents are delivered to whichever
/// app is frontmost, so synthesis MUST activate the target first — otherwise a
/// click or keystroke lands in the invoking terminal instead of the app under
/// test. Wrapped behind a protocol so unit tests can assert "activation
/// happened before delivery" without a real app.
public protocol Activator {
    func activate(pid: pid_t)
}

/// Live activation via `NSRunningApplication`. A pid with no running process
/// resolves to nil and is a no-op (the caller has already resolved the pid via
/// enumeration, so this is defensive only).
public struct FrontmostActivator: Activator {
    public init() {}

    public func activate(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
