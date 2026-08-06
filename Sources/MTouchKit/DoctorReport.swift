/// Verdict model behind `mtouch doctor`. Snapshots the provider once so text
/// and JSON renderings always agree, and keeps the exit mapping unit-testable
/// with a stubbed provider.
public struct DoctorReport: Sendable, Equatable {
    public let accessibilityGranted: Bool
    public let screenRecordingGranted: Bool

    public init(provider: PermissionProvider) {
        self.accessibilityGranted = provider.accessibilityGranted
        self.screenRecordingGranted = provider.screenRecordingGranted
    }

    public func granted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility: accessibilityGranted
        case .screenRecording: screenRecordingGranted
        }
    }

    /// Accessibility is the only required permission: its absence alone drives
    /// exit 2; a missing Screen Recording never affects the exit code.
    public var exitCode: MTouchExitCode {
        accessibilityGranted ? .success : .permissionMissing
    }

    /// One status line per permission, each reported independently, followed by
    /// the shared guidance block for any missing permission.
    public func textLines() -> [String] {
        var lines: [String] = []
        for permission in Permission.allCases {
            let status = granted(permission) ? "granted" : "missing"
            let requirement = permission.isRequired ? "required" : "optional"
            lines.append("\(permission.displayName): \(status) (\(requirement))")
            if !granted(permission) {
                lines.append(contentsOf: permission.guidanceLines.map { "  \($0)" })
            }
        }
        return lines
    }

    /// Stable jq-parseable shape:
    /// `{"permissions":{"accessibility":{"granted":bool,"required":true},"screenRecording":{"granted":bool,"required":false}}}`.
    /// Hand-built (not JSONEncoder) so key order is byte-stable across runs.
    public func jsonString() -> String {
        let entries = Permission.allCases
            .map { permission in
                "\"\(permission.rawValue)\":{\"granted\":\(granted(permission)),\"required\":\(permission.isRequired)}"
            }
            .joined(separator: ",")
        return "{\"permissions\":{\(entries)}}"
    }
}
