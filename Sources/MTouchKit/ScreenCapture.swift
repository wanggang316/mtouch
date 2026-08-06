import CoreGraphics

/// What a `screenshot` invocation captures: the whole main display, or one
/// window addressed by its `CGWindowID` — the SAME id space `mtouch windows`
/// prints (via `_AXUIElementGetWindow`/`AXSupport.windowID`), so an id from a
/// window listing matches an `SCWindow.windowID` directly.
public enum CaptureTarget: Equatable, Sendable {
    case fullScreen
    case window(CGWindowID)

    /// Parses a raw `--window` argument into a `CGWindowID`. Nil when the token
    /// is not a plain non-negative integer in the `CGWindowID` (`UInt32`) range —
    /// a syntactically invalid id, distinct from a well-formed id that no window
    /// currently owns.
    public static func parseWindowID(_ raw: String) -> CGWindowID? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = UInt32(trimmed) else { return nil }
        return CGWindowID(value)
    }
}

/// A completed capture: the image plus the geometry reported on stdout.
///
/// `cgImage.width`/`.height` are the PIXEL dimensions written to the PNG;
/// `scale` is the source display's backing scale, so point dimensions are
/// `pixels / scale` and the reported relation `pixels == points × scale` holds.
///
/// `@unchecked Sendable`: `CGImage` is immutable once created, and this value
/// only crosses the capture bridge inside `LiveScreenCapture.ResultBox`, whose
/// `NSLock` establishes the happens-before ordering between the writing task and
/// the reading pump.
public struct CapturedImage: @unchecked Sendable {
    public let cgImage: CGImage
    /// Human name of the captured display for the stdout line's `display "…"`
    /// slot (`"main"` for the primary display, else `display <id>`).
    public let displayName: String
    public let scale: Double

    public init(cgImage: CGImage, displayName: String, scale: Double) {
        self.cgImage = cgImage
        self.displayName = displayName
        self.scale = scale
    }
}

/// The runtime failures of a capture, each mapping to exit 1 (`runtimeFailure`)
/// with a diagnostic that names the offender so a caller can act. Missing
/// Screen Recording is NOT here — that is a preflight concern (exit 2) surfaced
/// via `PermissionError` before any capture is attempted.
public enum ScreenCaptureError: Error, Equatable, Sendable {
    /// `--window <raw>` was not a well-formed `CGWindowID`.
    case invalidWindowID(String)
    /// A well-formed id that no current window owns (closed / minimized / gone).
    case windowNotFound(CGWindowID)
    /// The resolved output path is an existing directory.
    case pathIsDirectory(String)
    /// The output could not be written (parent unwritable, read-only location…).
    case notWritable(path: String, reason: String)
    /// The capture came back all-black/empty — refused rather than written as a
    /// false success (the black-capture backstop behind the preflight guard).
    case blankCapture
    /// The captured image could not be encoded as PNG.
    case encodingFailed(path: String)
    /// ScreenCaptureKit itself failed (no display, capture error…).
    case captureFailed(reason: String)

    /// Every capture failure is a runtime failure.
    public var exitCode: MTouchExitCode { .runtimeFailure }

    /// Actionable stderr line, always naming the offending id/path/reason.
    public var diagnostic: String {
        switch self {
        case let .invalidWindowID(raw):
            return "mtouch: invalid window id '\(raw)'; expected a numeric CGWindowID from 'mtouch windows'."
        case let .windowNotFound(id):
            return "mtouch: window \(id) not found; it may be closed or minimized. "
                + "Run 'mtouch windows --app <bundleId>' to list current window ids."
        case let .pathIsDirectory(path):
            return "mtouch: cannot write screenshot: path is a directory: \(path)"
        case let .notWritable(path, reason):
            return "mtouch: cannot write screenshot to \(path): \(reason)"
        case .blankCapture:
            return "mtouch: capture produced an empty (all-black) image; refusing to write it. "
                + "Ensure Screen Recording is granted (run 'mtouch doctor')."
        case let .encodingFailed(path):
            return "mtouch: failed to encode the capture as PNG for \(path)."
        case let .captureFailed(reason):
            return "mtouch: screen capture failed: \(reason)"
        }
    }
}
