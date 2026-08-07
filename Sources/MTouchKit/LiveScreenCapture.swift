import AppKit
import CoreGraphics
import Foundation
// @preconcurrency downgrades ScreenCaptureKit's Sendable-related errors to
// warnings. On the Xcode 16.4 / macOS 15.5 SDK (CI), SCK types like
// SCShareableContent are not Sendable, so passing their results across the
// nonisolated/main-actor boundary is a hard Swift 6 error; on newer SDKs those
// types are Sendable and this attribute is a no-op. Keeps the build portable
// across SDK versions without changing runtime behavior.
@preconcurrency import ScreenCaptureKit

/// The live ScreenCaptureKit seam behind `ScreenshotPipeline`'s injectable
/// `capture` closure. It enumerates shareable content, builds a per-display or
/// per-window `SCContentFilter`, and captures one image via
/// `SCScreenshotManager` (macOS 14+). SCK composites per-window, so an occluded
/// window still yields its OWN content, not the occluder.
///
/// `SCScreenshotManager.captureImage` is async; this is a one-shot synchronous
/// CLI. We kick the async work off on a main-actor task and, on the calling
/// (main) thread, PUMP the run loop until it completes rather than blocking on a
/// semaphore: ScreenCaptureKit's per-window path depends on the main-thread
/// window-server connection, so a blocked main thread starves it (a
/// `CGS_REQUIRE_INIT` assertion). Pumping keeps that connection live and drives
/// the main-actor task's continuations. A hard deadline guards against a capture
/// that never completes, so the command can never hang.
public enum LiveScreenCapture {
    /// Wall-clock ceiling for a single capture; on expiry we return a failure
    /// (exit 1) rather than pump forever.
    static let captureDeadline: TimeInterval = 15

    public static func capture(_ target: CaptureTarget) -> Result<CapturedImage, ScreenCaptureError> {
        // The run-loop pump below and SCK's window-server (CGS) calls both require
        // the main thread; an off-main caller would starve the pump and hang to the
        // 15s deadline. Fail loud instead. Both current callers are main-correct.
        assert(Thread.isMainThread, "LiveScreenCapture.capture must run on the main thread")
        let box = ResultBox()
        // The SCK window path issues synchronous window-server (CGS) calls that
        // MUST run on the main thread; isolate the capture to the main actor and
        // let the run-loop pump below drive it.
        Task { @MainActor in
            let outcome = await performCapture(target)
            box.set(outcome)
        }
        let deadline = Date(timeIntervalSinceNow: captureDeadline)
        while !box.isDone, Date() < deadline {
            // Service the main run loop (and the main dispatch queue SCK uses) in
            // short windows; times out without busy-spinning when idle.
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
        return box.get()
    }

    // MARK: - Async capture

    @MainActor
    private static func performCapture(
        _ target: CaptureTarget
    ) async -> Result<CapturedImage, ScreenCaptureError> {
        // A bare CLI never connects to the window server, so SCK's per-window
        // path would assert (`CGS_REQUIRE_INIT`). Instantiating the shared
        // NSApplication on the main thread establishes that connection; it is a
        // singleton, so this is idempotent across captures.
        _ = NSApplication.shared

        let content: SCShareableContent
        do {
            // onScreenWindowsOnly: false so an occluded or minimized window can
            // still be located by id rather than silently missing.
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            return .failure(.captureFailed(reason: (error as NSError).localizedDescription))
        }

        switch target {
        case .fullScreen:
            // v1 captures the MAIN display.
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
            else {
                return .failure(.captureFailed(reason: "no display available to capture"))
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return await capture(filter: filter, displayName: name(for: display.displayID))

        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                return .failure(.windowNotFound(id))
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let displayID = bestDisplay(for: window.frame, in: content.displays)?.displayID
                ?? CGMainDisplayID()
            return await capture(filter: filter, displayName: name(for: displayID))
        }
    }

    /// Captures `filter` at its native pixel size. `pointPixelScale` and
    /// `contentRect` come straight from the filter, so the image is exactly
    /// `contentRect × scale` pixels and the reported scale is the source
    /// display's — keeping `pixels == points × scale` true by construction.
    @MainActor
    private static func capture(
        filter: SCContentFilter,
        displayName: String
    ) async -> Result<CapturedImage, ScreenCaptureError> {
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.showsCursor = false

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
            return .success(CapturedImage(cgImage: image, displayName: displayName, scale: Double(scale)))
        } catch {
            return .failure(.captureFailed(reason: (error as NSError).localizedDescription))
        }
    }

    // MARK: - Display helpers

    /// The display a window most plausibly lives on: the one whose bounds
    /// contain the window's centre, else the first available.
    private static func bestDisplay(for frame: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.first(where: { $0.frame.contains(center) }) ?? displays.first
    }

    /// A stable, deterministic display name for the stdout line: `"main"` for
    /// the primary display, else `display <id>`.
    private static func name(for displayID: CGDirectDisplayID) -> String {
        displayID == CGMainDisplayID() ? "main" : "display \(displayID)"
    }

    /// Lock-protected one-shot cell carrying the capture result across the task
    /// boundary (mirrors `BoundedWalk.Box`). The run-loop pump polls `isDone`;
    /// `get()` yields the stored result, or a timeout failure if the deadline
    /// elapsed before the capture completed.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<CapturedImage, ScreenCaptureError>?
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
        func set(_ newValue: Result<CapturedImage, ScreenCaptureError>) {
            lock.lock(); value = newValue; lock.unlock()
        }
        func get() -> Result<CapturedImage, ScreenCaptureError> {
            lock.lock(); defer { lock.unlock() }
            return value ?? .failure(.captureFailed(reason: "capture timed out"))
        }
    }
}
