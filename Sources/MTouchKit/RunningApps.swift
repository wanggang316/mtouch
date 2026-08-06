import AppKit

/// One running application with a regular activation policy (ordinary
/// Dock-visible apps). Apps without a bundle identifier (rare helper
/// processes) are skipped entirely so every emitted row carries a usable id.
public struct RunningAppInfo: Equatable, Sendable {
    public let bundleId: String
    public let pid: pid_t
    public let name: String

    public init(bundleId: String, pid: pid_t, name: String) {
        self.bundleId = bundleId
        self.pid = pid
        self.name = name
    }

    /// Greppable text row: bundle id as a bare leading token, then pid, then
    /// the localized name, tab-separated.
    public var textLine: String {
        "\(bundleId)\t\(pid)\t\(name)"
    }

    /// Stable jq-parseable shape: `{"bundleId":..,"pid":..,"name":..}`.
    public var jsonObject: String {
        "{\"bundleId\":\(JSONText.string(bundleId)),\"pid\":\(pid),\"name\":\(JSONText.string(name))}"
    }

    public static func jsonArray(_ apps: [RunningAppInfo]) -> String {
        "[" + apps.map(\.jsonObject).joined(separator: ",") + "]"
    }

    /// Deterministic display order: bundle id, then pid for multi-instance apps.
    public static func displayOrder(_ apps: [RunningAppInfo]) -> [RunningAppInfo] {
        apps.sorted {
            if $0.bundleId != $1.bundleId { return $0.bundleId < $1.bundleId }
            return $0.pid < $1.pid
        }
    }

    /// Live snapshot via NSWorkspace. Process enumeration is not TCC-gated,
    /// so this works without any permission grant.
    public static func currentRegularApps() -> [RunningAppInfo] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppInfo? in
                guard let bundleId = app.bundleIdentifier else { return nil }
                return RunningAppInfo(
                    bundleId: bundleId,
                    pid: app.processIdentifier,
                    name: app.localizedName ?? bundleId
                )
            }
        return displayOrder(apps)
    }
}
