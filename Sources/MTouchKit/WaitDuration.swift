import Foundation

/// A wait duration parsed from the pinned grammar shared by `--timeout` and
/// `--interval`: `5s` (seconds), `500ms` (milliseconds), or a BARE number
/// (`5` / `2.5`) which is also seconds. Whitespace around the token is
/// tolerated; the unit suffix is case-insensitive.
///
/// Malformed input (`abc`, `5sx`, a bare `s`/`ms`), NEGATIVE values, and
/// NON-FINITE values (`inf`/`nan`) return nil so the CLI reports a usage error
/// (exit 64) BEFORE any AX call — a non-finite timeout must not poll unbounded.
/// Zero is valid: `--timeout 0` means a single immediate check then a verdict.
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

        // Reject non-finite (`inf`/`nan`) as well as negatives: a non-finite
        // timeout would otherwise poll unbounded instead of erroring (exit 64).
        guard seconds.isFinite, seconds >= 0 else { return nil }
        self.init(seconds: seconds)
    }
}
