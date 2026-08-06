import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MTouchKit

// MARK: - Stubs & fixtures (zero SCK/TCC dependency)

private struct StubPermissionProvider: PermissionProvider {
    var accessibilityGranted: Bool = true
    var screenRecordingGranted: Bool
}

/// A solid-colour `CGImage` for the black-capture and encoding tests.
private func solidImage(
    width: Int, height: Int,
    r: UInt8, g: UInt8, b: UInt8, a: UInt8
) -> CGImage {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    var i = 0
    while i < pixels.count {
        pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = a
        i += 4
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

/// A fresh, unique temp directory removed at the end of the closure. Tests write
/// ONLY here — never the real filesystem elsewhere.
private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-screenshot-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

/// The 8-byte PNG signature. Used to prove the bytes are PNG regardless of the
/// destination extension.
private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

private func isPNG(_ data: Data) -> Bool {
    data.count >= 8 && Array(data.prefix(8)) == pngSignature
}

private func isSuccess<Success, Failure>(_ result: Result<Success, Failure>) -> Bool {
    if case .success = result { return true }
    return false
}

// MARK: - Path resolution (VAL-SHOT-005, VAL-SHOT-008)

@Suite struct ScreenCapturePathTests {
    @Test func explicitOutIsHonouredVerbatimRegardlessOfExtension() {
        #expect(ScreenCapturePath.resolve(out: "/x/shot.jpg", directory: "/tmp") == "/x/shot.jpg")
        #expect(ScreenCapturePath.resolve(out: "/x/noext", directory: "/tmp") == "/x/noext")
        #expect(ScreenCapturePath.resolve(out: "relative.png", directory: "/tmp") == "relative.png")
    }

    @Test func emptyOutFallsBackToTheDefaultName() {
        let path = ScreenCapturePath.resolve(out: "", directory: "/tmp")
        #expect(path.hasPrefix("/tmp/"))
        #expect(path.hasSuffix(".png"))
    }

    @Test func defaultNameIsTimestampedPNGInTheGivenDirectory() {
        let path = ScreenCapturePath.resolve(out: nil, directory: "/tmp")
        #expect(path.hasPrefix("/tmp/mtouch-screenshot-"))
        #expect(path.hasSuffix(".png"))
    }

    @Test func backToBackSameSecondCapturesNeverCollide() {
        // Same clock instant ⇒ the uniqueness suffix must still separate them.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ScreenCapturePath.resolve(out: nil, directory: "/tmp", now: now)
        let second = ScreenCapturePath.resolve(out: nil, directory: "/tmp", now: now)
        #expect(first != second)
    }

    @Test func timestampIsFixedWidthAndSortable() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 9
        components.hour = 4; components.minute = 5; components.second = 6
        let date = calendar.date(from: components)!
        #expect(ScreenCapturePath.timestamp(date, calendar: calendar) == "20260309-040506")
    }
}

// MARK: - Image ops: PNG encode + black backstop (VAL-SHOT-003, VAL-SHOT-004)

@Suite struct ScreenCaptureImageTests {
    @Test func pngDataCarriesTheSignatureAndDecodesToSameDimensions() throws {
        let image = solidImage(width: 12, height: 7, r: 200, g: 40, b: 40, a: 255)
        let data = try #require(ScreenCaptureImage.pngData(image))
        #expect(isPNG(data))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 12)
        #expect(decoded.height == 7)
    }

    @Test func allBlackImageIsBlank() {
        let image = solidImage(width: 20, height: 12, r: 0, g: 0, b: 0, a: 255)
        #expect(ScreenCaptureImage.isEffectivelyBlank(image))
    }

    @Test func fullyTransparentImageIsBlank() {
        let image = solidImage(width: 20, height: 12, r: 0, g: 0, b: 0, a: 0)
        #expect(ScreenCaptureImage.isEffectivelyBlank(image))
    }

    @Test func imageWithColourIsNotBlank() {
        let image = solidImage(width: 20, height: 12, r: 255, g: 255, b: 255, a: 255)
        #expect(!ScreenCaptureImage.isEffectivelyBlank(image))
    }
}

// MARK: - Atomic write (VAL-SHOT-003, VAL-SHOT-009)

@Suite struct ScreenCaptureWriterTests {
    @Test func writesBytesThenOverwritesInPlace() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("shot.png").path
            #expect(isSuccess(ScreenCaptureWriter.write(Data([1, 2, 3]), to: path)))
            #expect(FileManager.default.fileExists(atPath: path))
            let firstBytes = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(firstBytes == Data([1, 2, 3]))

            // A second write to the SAME path overwrites cleanly.
            #expect(isSuccess(ScreenCaptureWriter.write(Data([9, 9]), to: path)))
            let secondBytes = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(secondBytes == Data([9, 9]))
        }
    }

    @Test func createsMissingParentDirectories() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("newdir/nested/x.png").path
            #expect(isSuccess(ScreenCaptureWriter.write(Data([7]), to: path)))
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func directoryPathFailsWithoutDebris() throws {
        try withTempDir { dir in
            let result = ScreenCaptureWriter.write(Data([1]), to: dir.path)
            guard case let .failure(error) = result else {
                Issue.record("expected a failure writing to a directory")
                return
            }
            #expect(error == .pathIsDirectory(dir.path))
            // The directory is untouched — still a directory, no file smuggled in.
            #expect(ScreenCaptureWriter.isDirectory(dir.path))
        }
    }

    @Test func unwritableParentFailsWithoutDebris() throws {
        try withTempDir { dir in
            // Parent component is a regular FILE, so createDirectory cannot make it.
            let blocker = dir.appendingPathComponent("blocker")
            try Data([0]).write(to: blocker)
            let path = blocker.appendingPathComponent("x.png").path

            let result = ScreenCaptureWriter.write(Data([1]), to: path)
            guard case let .failure(error) = result else {
                Issue.record("expected a failure with a file as the parent")
                return
            }
            if case .notWritable = error {} else {
                Issue.record("expected .notWritable, got \(error)")
            }
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }
}

// MARK: - Pipeline orchestration (VAL-SHOT-001, -002, -004, -005, -009)

@Suite struct ScreenshotPipelineTests {
    /// A capture stub that records whether it ran and returns a fixed result.
    private final class CaptureSpy {
        private(set) var called = false
        private let result: Result<CapturedImage, ScreenCaptureError>
        init(_ result: Result<CapturedImage, ScreenCaptureError>) { self.result = result }
        func capture(_: CaptureTarget) -> Result<CapturedImage, ScreenCaptureError> {
            called = true
            return result
        }
    }

    private func nonBlankCapture(width: Int = 20, height: Int = 10, scale: Double = 2) -> CapturedImage {
        CapturedImage(
            cgImage: solidImage(width: width, height: height, r: 255, g: 255, b: 255, a: 255),
            displayName: "main", scale: scale
        )
    }

    // VAL-SHOT-004 primary guard: no grant ⇒ exit 2, and NOTHING is captured or written.
    @Test func notGrantedFailsFastAtExitTwoWithoutCaptureOrWrite() {
        let spy = CaptureSpy(.success(nonBlankCapture()))
        var wrote = false
        let outcome = ScreenshotPipeline.run(
            window: nil, out: "/tmp/should-not-write.png", directory: "/tmp",
            permissions: StubPermissionProvider(screenRecordingGranted: false),
            capture: spy.capture,
            write: { _, _ in wrote = true; return .success(()) }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(code == .permissionMissing)
        #expect(stderr.contains("Screen Recording permission is not granted"))
        #expect(stderr.contains("mtouch doctor"))
        #expect(spy.called == false)
        #expect(wrote == false)
    }

    @Test func invalidWindowIDFailsAtExitOneBeforeCapture() {
        let spy = CaptureSpy(.success(nonBlankCapture()))
        let outcome = ScreenshotPipeline.run(
            window: "not-a-number", out: nil, directory: "/tmp",
            permissions: StubPermissionProvider(screenRecordingGranted: true),
            capture: spy.capture
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("not-a-number"))
        #expect(spy.called == false)
    }

    @Test func closedOrMissingWindowFailsAtExitOneWithoutWrite() {
        let spy = CaptureSpy(.failure(.windowNotFound(999_999_999)))
        var wrote = false
        let outcome = ScreenshotPipeline.run(
            window: "999999999", out: nil, directory: "/tmp",
            permissions: StubPermissionProvider(screenRecordingGranted: true),
            capture: spy.capture,
            write: { _, _ in wrote = true; return .success(()) }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("999999999"))
        #expect(wrote == false)
    }

    // VAL-SHOT-004 backstop: an all-black capture is refused, never written as success.
    @Test func blankCaptureFailsAtExitOneWithoutWrite() {
        let black = CapturedImage(
            cgImage: solidImage(width: 20, height: 10, r: 0, g: 0, b: 0, a: 255),
            displayName: "main", scale: 2
        )
        var wrote = false
        let outcome = ScreenshotPipeline.run(
            window: nil, out: nil, directory: "/tmp",
            permissions: StubPermissionProvider(screenRecordingGranted: true),
            capture: { _ in .success(black) },
            write: { _, _ in wrote = true; return .success(()) }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("all-black"))
        #expect(wrote == false)
    }

    @Test func existingDirectoryOutFailsAtExitOneBeforeCapture() throws {
        try withTempDir { dir in
            let spy = CaptureSpy(.success(nonBlankCapture()))
            let outcome = ScreenshotPipeline.run(
                window: nil, out: dir.path, directory: "/tmp",
                permissions: StubPermissionProvider(screenRecordingGranted: true),
                capture: spy.capture
            )
            guard case let .failed(stderr, code) = outcome else {
                Issue.record("expected a failure, got \(outcome)")
                return
            }
            #expect(code == .runtimeFailure)
            #expect(stderr.contains(dir.path))
            #expect(spy.called == false)
        }
    }

    // VAL-SHOT-001/-002: success writes PNG bytes and the line reports px + scale.
    @Test func successWritesPNGBytesAndReportsPixelsAndScale() throws {
        var captured: Data?
        let outcome = ScreenshotPipeline.run(
            window: nil, out: "/tmp/report.png", directory: "/tmp",
            permissions: StubPermissionProvider(screenRecordingGranted: true),
            capture: { _ in .success(self.nonBlankCapture(width: 20, height: 10, scale: 2)) },
            write: { data, _ in captured = data; return .success(()) }
        )
        guard case let .written(path, message) = outcome else {
            Issue.record("expected a written outcome, got \(outcome)")
            return
        }
        #expect(path == "/tmp/report.png")
        #expect(message == #"wrote /tmp/report.png (20x10 px, display "main", scale 2)"#)
        #expect(isPNG(try #require(captured)))
    }

    // VAL-SHOT-003: PNG bytes regardless of extension, written through the real writer.
    @Test func extensionIndependentPNGBytesThroughRealWriter() throws {
        try withTempDir { dir in
            let jpgPath = dir.appendingPathComponent("shot.jpg").path
            let outcome = ScreenshotPipeline.run(
                window: nil, out: jpgPath, directory: dir.path,
                permissions: StubPermissionProvider(screenRecordingGranted: true),
                capture: { _ in .success(self.nonBlankCapture()) }
            )
            guard case .written = outcome else {
                Issue.record("expected a written outcome, got \(outcome)")
                return
            }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: jpgPath))
            #expect(isPNG(bytes))
        }
    }

    @Test func writeFailurePropagatesExitOneNamingThePath() {
        let outcome = ScreenshotPipeline.run(
            window: nil, out: "/ro/x.png", directory: "/tmp",
            permissions: StubPermissionProvider(screenRecordingGranted: true),
            capture: { _ in .success(self.nonBlankCapture()) },
            write: { _, _ in .failure(.notWritable(path: "/ro/x.png", reason: "denied")) }
        )
        guard case let .failed(stderr, code) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(code == .runtimeFailure)
        #expect(stderr.contains("/ro/x.png"))
    }
}

// MARK: - Target parsing & error taxonomy (failure classification)

@Suite struct CaptureTargetTests {
    @Test func parsesWellFormedIDs() {
        #expect(CaptureTarget.parseWindowID("42") == 42)
        #expect(CaptureTarget.parseWindowID("  42  ") == 42)
        #expect(CaptureTarget.parseWindowID("999999999") == 999_999_999)
    }

    @Test func rejectsMalformedIDs() {
        #expect(CaptureTarget.parseWindowID("abc") == nil)
        #expect(CaptureTarget.parseWindowID("-1") == nil)
        #expect(CaptureTarget.parseWindowID("12.5") == nil)
        #expect(CaptureTarget.parseWindowID("") == nil)
        // Beyond CGWindowID (UInt32) range.
        #expect(CaptureTarget.parseWindowID("4294967296") == nil)
    }

    @Test func everyCaptureFailureMapsToExitOne() {
        let errors: [ScreenCaptureError] = [
            .invalidWindowID("x"), .windowNotFound(1), .pathIsDirectory("/d"),
            .notWritable(path: "/p", reason: "r"), .blankCapture,
            .encodingFailed(path: "/p"), .captureFailed(reason: "r"),
        ]
        for error in errors {
            #expect(error.exitCode == .runtimeFailure)
            #expect(!error.diagnostic.isEmpty)
        }
    }
}
