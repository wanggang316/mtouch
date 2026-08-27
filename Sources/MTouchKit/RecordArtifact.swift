import AVFoundation
import CoreMedia
import Foundation

/// What a movie file actually contains, as read back from the finished file.
public struct RecordMovieFacts: Sendable, Equatable {
    public let byteCount: Int
    public let durationSeconds: Double
    public let videoTrackCount: Int

    public init(byteCount: Int, durationSeconds: Double, videoTrackCount: Int) {
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
        self.videoTrackCount = videoTrackCount
    }
}

/// What a container probe could read out of a file. Separate from
/// `RecordMovieFacts` so the byte count (a filesystem fact) and the media facts
/// (a container fact) come from independent sources and can be stubbed apart.
public struct RecordMovieProbe: Sendable, Equatable {
    public let durationSeconds: Double
    public let videoTrackCount: Int

    public init(durationSeconds: Double, videoTrackCount: Int) {
        self.durationSeconds = durationSeconds
        self.videoTrackCount = videoTrackCount
    }
}

/// The verdict on a finished recording.
///
/// Every non-`verified` case is an EXIT-1 FAILURE naming the reason. A movie is
/// reported as a successful recording only when the file exists, is non-empty,
/// parses as a container, carries at least one video track, and has a positive
/// duration. That conjunction is what catches a recorder that was SIGKILLed:
/// nothing finalized the container, so it fails to parse and is refused instead
/// of being handed back as evidence.
public enum RecordArtifactVerdict: Sendable, Equatable {
    case verified(RecordMovieFacts)
    /// No file at the recorded path.
    case missing(path: String)
    /// The file exists but has zero bytes.
    case empty(path: String)
    /// The bytes are not a readable movie container (truncated, unfinalized,
    /// or never a movie at all). `reason` carries what the parser said.
    case unreadable(path: String, reason: String)
    /// A readable container that carries no video track.
    case noVideoTrack(path: String)
    /// A readable container whose duration is zero or unusable.
    case zeroDuration(path: String)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    public var facts: RecordMovieFacts? {
        if case let .verified(facts) = self { return facts }
        return nil
    }

    /// Stderr diagnostic in the project's `mtouch: …` voice, always naming the
    /// file and what is wrong with it.
    public var diagnostic: String {
        switch self {
        case let .verified(facts):
            return "mtouch: \(RecordArtifactVerdict.factsText(facts))"
        case let .missing(path):
            return "mtouch: the recording was not written: no file at \(path)."
        case let .empty(path):
            return "mtouch: the recording at \(path) is empty (0 bytes); nothing was captured."
        case let .unreadable(path, reason):
            return "mtouch: the recording at \(path) is not a readable movie: \(reason). "
                + "A recorder that was killed rather than stopped leaves the file unfinalized."
        case let .noVideoTrack(path):
            return "mtouch: the recording at \(path) carries no video track."
        case let .zeroDuration(path):
            return "mtouch: the recording at \(path) has no duration; nothing was captured."
        }
    }

    /// The human summary of a verified movie, shared by the stdout line and the
    /// diagnostic above.
    static func factsText(_ facts: RecordMovieFacts) -> String {
        let tracks = facts.videoTrackCount == 1 ? "1 video track" : "\(facts.videoTrackCount) video tracks"
        return "\(facts.byteCount) bytes, \(JSONText.number((facts.durationSeconds * 1000).rounded() / 1000)) s, \(tracks)"
    }
}

/// Verifies a finished recording. Pure over its two injected sources — the
/// file's byte count and a container probe — so every classification is testable
/// against real files without any capture.
public enum RecordArtifact {
    public static func verify(
        path: String,
        byteCount: (String) -> Int? = RecordArtifact.fileByteCount,
        probe: (String) -> Result<RecordMovieProbe, RecordFailure> = LiveMovieProbe.probe
    ) -> RecordArtifactVerdict {
        guard let bytes = byteCount(path) else { return .missing(path: path) }
        guard bytes > 0 else { return .empty(path: path) }

        let facts: RecordMovieProbe
        switch probe(path) {
        case let .success(value): facts = value
        case let .failure(failure): return .unreadable(path: path, reason: failure.reason)
        }

        guard facts.videoTrackCount > 0 else { return .noVideoTrack(path: path) }
        guard facts.durationSeconds.isFinite, facts.durationSeconds > 0 else {
            return .zeroDuration(path: path)
        }
        return .verified(RecordMovieFacts(
            byteCount: bytes,
            durationSeconds: facts.durationSeconds,
            videoTrackCount: facts.videoTrackCount
        ))
    }

    /// Size of a regular file, or nil when the path is absent or is a directory
    /// (a directory is "no recording here", not a zero-byte one).
    public static func fileByteCount(_ path: String) -> Int? {
        var status = stat()
        guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(status.st_size)
    }
}

/// The live container probe: `AVAsset` duration + video-track count.
///
/// The asset is built and loaded INSIDE the task so no non-`Sendable`
/// AVFoundation object crosses the concurrency boundary. The calling thread
/// blocks on a semaphore, which is safe here (unlike the ScreenCaptureKit path)
/// because asset loading never needs the caller's run loop. A deadline keeps a
/// pathological file from hanging `record stop`.
public enum LiveMovieProbe {
    static let probeDeadline: TimeInterval = 15

    public static func probe(path: String) -> Result<RecordMovieProbe, RecordFailure> {
        let box = ProbeBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            do {
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let seconds = duration.isValid && !duration.isIndefinite ? CMTimeGetSeconds(duration) : 0
                box.set(.success(RecordMovieProbe(
                    durationSeconds: seconds.isFinite ? seconds : 0,
                    videoTrackCount: tracks.count
                )))
            } catch {
                box.set(.failure(RecordFailure((error as NSError).localizedDescription)))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + probeDeadline) == .success else {
            return .failure(RecordFailure("timed out reading the file after \(Int(probeDeadline))s"))
        }
        return box.get()
    }

    /// Lock-protected one-shot cell carrying the probe result off the task
    /// (mirrors `LiveScreenCapture.ResultBox`).
    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<RecordMovieProbe, RecordFailure>?
        func set(_ newValue: Result<RecordMovieProbe, RecordFailure>) {
            lock.lock(); value = newValue; lock.unlock()
        }
        func get() -> Result<RecordMovieProbe, RecordFailure> {
            lock.lock(); defer { lock.unlock() }
            return value ?? .failure(RecordFailure("the file could not be read"))
        }
    }
}
