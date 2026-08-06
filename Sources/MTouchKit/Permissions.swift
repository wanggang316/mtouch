import ApplicationServices
import CoreGraphics

/// TCC permissions that mtouch depends on.
public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording

    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    /// System Settings pane where the permission is granted.
    public var settingsPane: String {
        switch self {
        case .accessibility: "Privacy & Security → Accessibility"
        case .screenRecording: "Privacy & Security → Screen & System Audio Recording"
        }
    }

    /// Whether `mtouch doctor` treats absence as a failure (exit 2).
    /// Accessibility is the only required permission; Screen Recording is
    /// needed only by `screenshot`.
    public var isRequired: Bool { self == .accessibility }

    /// Guidance emitted whenever the permission is missing. Shared verbatim by
    /// `mtouch doctor` output and the fail-fast preflight diagnostics so every
    /// command reports missing permissions the same way.
    public var guidanceLines: [String] {
        [
            "Grant \(displayName) in System Settings → \(settingsPane).",
            "The grant applies to the invoking terminal application (the app that launched mtouch), not to the mtouch binary.",
            "Run 'mtouch doctor' to re-check permission status.",
        ]
    }
}

/// Non-prompting checks for the TCC permissions mtouch depends on.
/// Implementations must never trigger a permission dialog or mutate TCC state.
public protocol PermissionProvider: Sendable {
    var accessibilityGranted: Bool { get }
    var screenRecordingGranted: Bool { get }
}

/// Live TCC checks. Both calls are read-only and non-prompting:
/// - `AXIsProcessTrusted()` — never `AXIsProcessTrustedWithOptions` with prompt=true.
/// - `CGPreflightScreenCaptureAccess()` — the only sanctioned non-prompting
///   Screen Recording check; ScreenCaptureKit alternatives and
///   `CGRequestScreenCaptureAccess` can trigger a TCC dialog. If a future SDK
///   deprecates it, silence the warning here rather than switching APIs.
public struct LivePermissionProvider: PermissionProvider {
    public init() {}

    public var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    public var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }
}

/// Typed error thrown by `Preflight` when a required permission is missing.
public struct PermissionError: Error, Equatable, Sendable {
    public let permission: Permission

    public init(permission: Permission) {
        self.permission = permission
    }

    /// Full stderr diagnostic: names the missing permission, the System
    /// Settings pane, the invoking-terminal caveat, and the `mtouch doctor`
    /// pointer. Callers pair it with exit code 2 (`.permissionMissing`).
    public var diagnostic: String {
        (["mtouch: \(permission.displayName) permission is not granted."] + permission.guidanceLines)
            .joined(separator: "\n")
    }
}

/// Fail-fast permission requirements for permission-gated commands.
/// AX-gated commands (windows, snapshot, act, wait) call
/// `requireAccessibility` before touching AX APIs; `screenshot` calls
/// `requireScreenRecording`.
public enum Preflight {
    public static func requireAccessibility(provider: PermissionProvider = LivePermissionProvider()) throws {
        guard provider.accessibilityGranted else {
            throw PermissionError(permission: .accessibility)
        }
    }

    public static func requireScreenRecording(provider: PermissionProvider = LivePermissionProvider()) throws {
        guard provider.screenRecordingGranted else {
            throw PermissionError(permission: .screenRecording)
        }
    }
}
