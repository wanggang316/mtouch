import Foundation

/// Why a step's evidence is missing. It is an `Error` only so it can ride a
/// `Result`; it is never thrown, because collecting evidence must not be able to
/// fail the operation being documented.
public struct RunCaptureFailure: Error, Equatable, Sendable {
    public let diagnostic: String

    public init(_ diagnostic: String) {
        self.diagnostic = diagnostic
    }
}

/// The seam a run bundle captures its per-step screenshots through.
///
/// It returns a `Result` and NEVER throws: a capture failure — Screen Recording
/// not granted, a capture timeout, an unwritable disk — is recorded into the step
/// and the documented operation proceeds at its normal exit code. An evidence
/// system that can fail the run it is documenting is worse than none.
public protocol RunCapturing: Sendable {
    /// PNG bytes of the current screen, or a short diagnostic explaining why the
    /// evidence is missing.
    func capturePNG() -> Result<Data, RunCaptureFailure>
}

/// The live capture: the same full-screen ScreenCaptureKit path `mtouch
/// screenshot` uses, with two extra refusals that keep it from ever hanging or
/// tripping the operation it documents.
public struct LiveRunCapture: RunCapturing {
    private let permissions: PermissionProvider

    public init(permissions: PermissionProvider = LivePermissionProvider()) {
        self.permissions = permissions
    }

    public func capturePNG() -> Result<Data, RunCaptureFailure> {
        // Off the main thread ScreenCaptureKit's window-server calls cannot be
        // driven and the capture would burn its full deadline before failing. The
        // MCP `wait` tool runs off-main by design, so refuse immediately rather
        // than stalling the very command we are documenting.
        guard Thread.isMainThread else {
            return .failure(RunCaptureFailure("evidence capture skipped: screen capture requires the main thread"))
        }
        // Preflight so a run without the Screen Recording grant costs nothing per
        // step and says exactly what is missing.
        guard permissions.screenRecordingGranted else {
            return .failure(RunCaptureFailure(PermissionError(permission: .screenRecording).diagnostic))
        }
        switch LiveScreenCapture.capture(.fullScreen) {
        case let .success(image):
            guard let data = ScreenCaptureImage.pngData(image.cgImage) else {
                return .failure(RunCaptureFailure("mtouch: failed to encode the evidence capture as PNG."))
            }
            return .success(data)
        case let .failure(error):
            return .failure(RunCaptureFailure(error.diagnostic))
        }
    }
}
