import Foundation

/// A wait duration parsed from the pinned grammar shared by `--timeout` and
/// `--interval`: `5s` (seconds), `500ms` (milliseconds), or a BARE number
/// (`5` / `2.5`) which is also seconds. Whitespace around the token is
/// tolerated; the unit suffix is case-insensitive.
///
/// Malformed input (`abc`, `5sx`, a bare `s`/`ms`) and NEGATIVE values return
/// nil so the CLI reports a usage error (exit 64) BEFORE any AX call. Zero is
/// valid: `--timeout 0` means a single immediate check then a verdict.
///
/// This replaces the M1 plain-seconds placeholder while keeping back-compat for
/// bare seconds (the M1 form).
public struct WaitDuration: Equatable, Sendable {
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public init?(parsing string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let seconds: Double
        if trimmed.hasSuffix("ms") {
            // Check "ms" before "s": "500ms" ends with "s" too.
            guard let value = Double(trimmed.dropLast(2)) else { return nil }
            seconds = value / 1000
        } else if trimmed.hasSuffix("s") {
            guard let value = Double(trimmed.dropLast(1)) else { return nil }
            seconds = value
        } else {
            guard let value = Double(trimmed) else { return nil }
            seconds = value
        }

        guard seconds >= 0 else { return nil }
        self.init(seconds: seconds)
    }
}
