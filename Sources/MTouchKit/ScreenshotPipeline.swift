import CoreGraphics
import Foundation

/// The observable outcome of a `screenshot` invocation, kept SEPARATE from the
/// side effects (printing, exiting) so the whole flow is unit-testable.
///
/// `.written` carries the human stdout line and the resolved path; `.failed`
/// carries a stderr diagnostic and its non-zero exit code. A failure never
/// carries stdout and never leaves a file — no black/partial PNG is ever a
/// success.
public enum ScreenshotOutcome: Equatable, Sendable {
    case written(path: String, message: String)
    case failed(stderr: String, code: MTouchExitCode)
}

/// Composes the `screenshot` command end-to-end: Screen Recording preflight →
/// resolve target → resolve path → capture (SCK) → black-capture backstop →
/// PNG encode → atomic write → stdout line. Each collaborator is injectable so
/// the flow can be exercised without any SCK/TCC access; the live defaults wire
/// the real ones.
public enum ScreenshotPipeline {
    public static func run(
        window: String?,
        out: String?,
        directory: String = FileManager.default.currentDirectoryPath,
        now: Date = Date(),
        permissions: PermissionProvider = LivePermissionProvider(),
        capture: (CaptureTarget) -> Result<CapturedImage, ScreenCaptureError> = LiveScreenCapture.capture,
        isBlank: (CGImage) -> Bool = { ScreenCaptureImage.isEffectivelyBlank($0) },
        encode: (CGImage) -> Data? = ScreenCaptureImage.pngData,
        write: (Data, String) -> Result<Void, ScreenCaptureError> = ScreenCaptureWriter.write
    ) -> ScreenshotOutcome {
        // 1. Preflight Screen Recording FIRST. Without the grant, fail fast with
        //    the doctor-pointing diagnostic (exit 2) and produce NO file — the
        //    primary guard against a black/empty capture ever being written.
        guard permissions.screenRecordingGranted else {
            return .failed(
                stderr: PermissionError(permission: .screenRecording).diagnostic,
                code: .permissionMissing
            )
        }

        // 2. Resolve the capture target. A syntactically invalid --window id is a
        //    runtime failure BEFORE any capture or write (no debris).
        let target: CaptureTarget
        if let window {
            guard let id = CaptureTarget.parseWindowID(window) else {
                return .failed(stderr: ScreenCaptureError.invalidWindowID(window).diagnostic, code: .runtimeFailure)
            }
            target = .window(id)
        } else {
            target = .fullScreen
        }

        // 3. Resolve the output path (verbatim --out, else timestamped in CWD).
        let path = ScreenCapturePath.resolve(out: out, directory: directory, now: now)

        // 4. Reject an existing directory up front, so we never do capture work
        //    toward a doomed write (deterministic, side-effect-free).
        if ScreenCaptureWriter.isDirectory(path) {
            return .failed(stderr: ScreenCaptureError.pathIsDirectory(path).diagnostic, code: .runtimeFailure)
        }

        // 5. Capture. A closed/missing --window id fails here (exit 1) before any
        //    write.
        let captured: CapturedImage
        switch capture(target) {
        case let .success(image):
            captured = image
        case let .failure(error):
            return .failed(stderr: error.diagnostic, code: error.exitCode)
        }

        // 6. Black-capture backstop: never write an all-black/empty frame as a
        //    success. The preflight is the primary guard; this catches the rest.
        if isBlank(captured.cgImage) {
            return .failed(stderr: ScreenCaptureError.blankCapture.diagnostic, code: .runtimeFailure)
        }

        // 7. Encode PNG bytes — always PNG, regardless of the --out extension.
        guard let data = encode(captured.cgImage) else {
            return .failed(stderr: ScreenCaptureError.encodingFailed(path: path).diagnostic, code: .runtimeFailure)
        }

        // 8. Write atomically (create parents, overwrite existing, no debris on
        //    failure).
        if case let .failure(error) = write(data, path) {
            return .failed(stderr: error.diagnostic, code: error.exitCode)
        }

        return .written(path: path, message: message(path: path, captured: captured))
    }

    /// The pinned human line: `wrote <path> (<W>x<H> px, display "<name>", scale <s>)`
    /// where W×H are the PNG's pixel dimensions and `<s>` the display scale, so
    /// the point dimensions (pixels / scale) are recoverable and the relation
    /// `pixels == points × scale` is reported and checkable.
    static func message(path: String, captured: CapturedImage) -> String {
        "wrote \(path) (\(captured.cgImage.width)x\(captured.cgImage.height) px, "
            + "display \(JSONText.string(captured.displayName)), scale \(JSONText.number(captured.scale)))"
    }
}
