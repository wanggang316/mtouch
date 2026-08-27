import AVFoundation
import CoreMedia
import Foundation

/// What became of one step's frame marker once `mtouch report` tried to
/// materialize it.
///
/// Both cases RENDER. A frame that could not be produced is stated on the step it
/// belongs to, with the reason, because the alternative — a broken image or a
/// silently absent one — would let a report under-describe the run it exists to
/// describe.
public enum RunFrameOutcome: Sendable, Equatable {
    /// A PNG now exists at this run-root-relative path.
    case extracted(relative: String)
    /// No PNG, and why.
    case unavailable(reason: String)
}

/// The seam a report cuts stills out of a movie through.
///
/// It returns a `Result` and NEVER throws: a movie that cannot be decoded must
/// degrade to a note on one step, not to a failed render of the whole bundle.
/// Being a seam is also what makes the report tests hermetic — they assert the
/// OFFSETS a bundle asks for without decoding anything.
public protocol RunFrameExtracting: Sendable {
    /// PNG bytes of the frame at `offset` seconds into `movie`, or a short
    /// diagnostic explaining why there are none.
    func extractPNG(movie: String, atOffset offset: Double) -> Result<Data, RunCaptureFailure>
}

/// The live extractor: `AVAssetImageGenerator` over the finished movie.
///
/// The asset, the generator and the decoded image are all built and consumed
/// INSIDE the task, so no non-`Sendable` AVFoundation object crosses the
/// concurrency boundary — only PNG bytes come back. The calling thread blocks on
/// a semaphore, which is safe here (unlike the ScreenCaptureKit paths) because
/// image generation never needs the caller's run loop. This mirrors
/// `LiveMovieProbe` exactly.
public struct LiveFrameExtractor: RunFrameExtracting {
    /// How far from the requested instant the generator may look for a frame.
    ///
    /// Non-zero, because the recorder emits a frame only when the screen changes:
    /// the effective rate is VARIABLE — measured between 0.74 and 9.68 fps on
    /// real runs — so an exact frame at an arbitrary instant is not something the
    /// file can be assumed to hold. Nothing anywhere may assume a fixed rate.
    ///
    /// But deliberately not large, which is the failure that matters more. The
    /// window is the range the generator may snap within, so a wide one collapses
    /// steps that are seconds apart onto ONE frame — a page that shows the same
    /// picture for four different moments while captioning them differently. That
    /// is silently wrong evidence, whereas a window that is occasionally too
    /// narrow degrades to a visible "frame unavailable" and costs only that step.
    /// Measured on an 85 s recording of seven steps: at 2 s, eight stills
    /// collapsed to four distinct frames; at 0.75 s, all eight were distinct and
    /// none was unavailable.
    public static let toleranceSeconds: Double = 0.75
    /// Ceiling on one extraction, so a pathological file cannot hang `report`.
    static let deadline: TimeInterval = 20
    static let timescale: CMTimeScale = 600

    public init() {}

    public func extractPNG(movie: String, atOffset offset: Double) -> Result<Data, RunCaptureFailure> {
        let box = FrameBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.set(await LiveFrameExtractor.frame(movie: movie, offset: offset))
            done.signal()
        }
        guard done.wait(timeout: .now() + LiveFrameExtractor.deadline) == .success else {
            return .failure(RunCaptureFailure(
                "mtouch: timed out reading a frame from \(movie) after \(Int(LiveFrameExtractor.deadline))s."
            ))
        }
        return box.get()
    }

    private static func frame(movie: String, offset: Double) async -> Result<Data, RunCaptureFailure> {
        guard offset.isFinite, offset >= 0 else {
            return .failure(RunCaptureFailure(
                "mtouch: the recorded frame offset (\(JSONText.number(offset)) s) is not a position in a movie."
            ))
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: movie))
        do {
            let duration = try await asset.load(.duration)
            let seconds = duration.isValid && !duration.isIndefinite ? CMTimeGetSeconds(duration) : 0
            guard seconds.isFinite, seconds > 0 else {
                return .failure(RunCaptureFailure(
                    "mtouch: the recording \(movie) has no readable duration, so no frame could be taken from it."
                ))
            }
            // Out of range is REPORTED, never clamped: a still silently taken from
            // the end of the movie would claim to show a moment it does not.
            guard offset <= seconds else {
                return .failure(RunCaptureFailure(
                    "mtouch: this step is \(secondsText(offset)) into the recording, but \(movie) is only "
                        + "\(secondsText(seconds)) long; the recording ended before this step."
                ))
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: timescale)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let (image, _) = try await generator.image(at: CMTime(seconds: offset, preferredTimescale: timescale))
            guard let data = ScreenCaptureImage.pngData(image) else {
                return .failure(RunCaptureFailure(
                    "mtouch: the frame taken from \(movie) could not be encoded as PNG."
                ))
            }
            return .success(data)
        } catch {
            return .failure(RunCaptureFailure(
                "mtouch: could not read a frame from \(movie) at \(secondsText(offset)): "
                    + "\((error as NSError).localizedDescription)"
            ))
        }
    }

    private static func secondsText(_ seconds: Double) -> String {
        JSONText.number((seconds * 1000).rounded() / 1000) + " s"
    }

    /// Lock-protected one-shot cell carrying the bytes off the task (mirrors
    /// `LiveMovieProbe.ProbeBox`).
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Data, RunCaptureFailure>?
        func set(_ newValue: Result<Data, RunCaptureFailure>) {
            lock.lock(); value = newValue; lock.unlock()
        }
        func get() -> Result<Data, RunCaptureFailure> {
            lock.lock(); defer { lock.unlock() }
            return value ?? .failure(RunCaptureFailure("mtouch: the frame could not be read."))
        }
    }
}

/// Turns each step's frame marker into an actual PNG in `steps/`, so the renderer
/// only ever deals with files and the page shows a still for a step whether or
/// not a screenshot was taken for it.
///
/// This runs BEFORE rendering and hands back an updated bundle, which keeps
/// `RunReportHTML.render` a pure function of its input — the property the
/// determinism tests rest on.
///
/// Materialization is IDEMPOTENT: a PNG that is already there is reused, never
/// re-extracted. That is what keeps `report` byte-identical across renders even
/// though it writes files, and it means a second render costs no decoding.
public enum RunFrameMaterializer {
    public static func materialize(
        _ bundle: RunReportBundle,
        extractor: RunFrameExtracting = LiveFrameExtractor()
    ) -> RunReportBundle {
        RunReportBundle(
            root: bundle.root,
            metadata: bundle.metadata,
            trajectoryPresent: bundle.trajectoryPresent,
            entries: bundle.entries.map { entry in
                guard case let .record(record) = entry, !record.evidence.frames.isEmpty else { return entry }
                var materialized = record
                materialized.extractedFrames = outcomes(for: record, root: bundle.root, extractor: extractor)
                return .record(materialized)
            },
            videoFiles: bundle.videoFiles
        )
    }

    private static func outcomes(
        for record: RunReportRecord,
        root: String,
        extractor: RunFrameExtracting
    ) -> [RunStepSlot: RunFrameOutcome] {
        // Without an ordinal there is no filename to write, and guessing one by
        // position would collide with a concurrent writer's evidence.
        guard let index = record.step else {
            return record.evidence.frames.mapValues { _ in
                .unavailable(reason: "this record carries no step number, so its frame has no place in steps/")
            }
        }
        let bundle = RunBundle(root: root)
        let step = RunStep(index: index, command: record.command)
        var outcomes: [RunStepSlot: RunFrameOutcome] = [:]
        for (slot, frame) in record.evidence.frames {
            outcomes[slot] = materialize(frame, slot: slot, step: step, bundle: bundle, extractor: extractor)
        }
        return outcomes
    }

    private static func materialize(
        _ frame: RunStepFrame,
        slot: RunStepSlot,
        step: RunStep,
        bundle: RunBundle,
        extractor: RunFrameExtracting
    ) -> RunFrameOutcome {
        let relative = step.relativePath(slot)
        let existing = try? Data(contentsOf: URL(fileURLWithPath: bundle.absolutePath(forRelative: relative)))
        if let existing, !existing.isEmpty { return .extracted(relative: relative) }

        guard let movie = resolveMovie(frame.movie, root: bundle.root) else {
            return .unavailable(reason: "the recording \(frame.movie) is not inside this run bundle")
        }
        guard RecordArtifact.fileByteCount(movie) ?? 0 > 0 else {
            return .unavailable(reason: "the recording \(frame.movie) is missing or empty")
        }
        switch extractor.extractPNG(movie: movie, atOffset: frame.offset) {
        case let .success(data):
            switch bundle.writeStepImage(data, step: step, slot: slot) {
            case let .success(written): return .extracted(relative: written)
            case let .failure(failure): return .unavailable(reason: failure.diagnostic)
            }
        case let .failure(failure):
            return .unavailable(reason: failure.diagnostic)
        }
    }

    /// The movie's absolute path. A RELATIVE marker is resolved against the run
    /// root and must stay inside it — the same containment rule the renderer
    /// applies before inlining a file, so a doctored bundle cannot turn `report`
    /// into a way to read `../../somewhere`. An ABSOLUTE one is a path this tool
    /// itself recorded from the recorder's control file (`record start --out`
    /// outside the bundle) and is taken as given.
    private static func resolveMovie(_ path: String, root: String) -> String? {
        guard !path.hasPrefix("/") else { return path }
        let base = URL(fileURLWithPath: root).standardized.path
        let absolute = URL(fileURLWithPath: root).appendingPathComponent(path).standardized.path
        return absolute.hasPrefix(base + "/") ? absolute : nil
    }
}
