import Foundation

/// Resolves the destination path for a capture. Pure over its inputs (the raw
/// `--out`, a directory, a clock, and a uniqueness source), so the default-name
/// and collision-freedom rules are unit-testable without touching the clock or
/// the filesystem.
public enum ScreenCapturePath {
    /// The path to write to.
    ///
    /// A non-empty `--out` is honoured VERBATIM (the extension is irrelevant —
    /// the bytes are always PNG). Otherwise a timestamped, collision-proof name
    /// lands in `directory`: `mtouch-screenshot-<yyyyMMdd-HHmmss>-<suffix>.png`.
    /// The `unique` suffix guarantees two captures in the same second never
    /// collide.
    public static func resolve(
        out: String?,
        directory: String,
        now: Date = Date(),
        unique: () -> String = { String(UUID().uuidString.prefix(8)) }
    ) -> String {
        if let out, !out.isEmpty { return out }
        let name = "mtouch-screenshot-\(timestamp(now))-\(unique()).png"
        return URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(name).path
    }

    /// Locale-/timezone-independent, sortable `yyyyMMdd-HHmmss` stamp built from
    /// the Gregorian calendar so the default name reads naturally and orders by
    /// capture time.
    static func timestamp(_ date: Date, calendar: Calendar = defaultCalendar) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    private static let defaultCalendar = Calendar(identifier: .gregorian)
}
