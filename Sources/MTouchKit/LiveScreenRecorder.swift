import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
// Same rationale as `LiveScreenCapture`: on the Xcode 16.4 / macOS 15.5 SDK the
// ScreenCaptureKit types are not Sendable, so carrying them across the
// nonisolated/main-actor boundary is a hard Swift 6 error; on newer SDKs the
// attribute is a no-op.
@preconcurrency import ScreenCaptureKit

/// The whole recorder: one BLOCKING capture of a display to an H.264 movie,
/// finalized on SIGINT/SIGTERM or at `--max-duration`, whichever comes first.
///
/// Everything else in the `record` feature is process management around this.
/// Keeping the recorder blocking means it can be driven straight from a shell,
/// and it keeps FINALIZATION — the step that decides whether the file is
/// playable — off the detached/spawn path entirely.
///
/// Ordering is load-bearing:
///
///   1. Refuse on macOS 14 with an explicit diagnostic. `SCRecordingOutput` is
///      macOS 15+, and the one thing a recorder must never do is exit 0 having
///      written nothing.
///   2. Preflight Screen Recording (exit 2), exactly as `screenshot` does.
///   3. Prove the destination is writable, before capturing a single frame.
///   4. Publish the control file only once the recording output's BYTE COUNT has
///      left zero, so the handshake means bytes are on disk — not merely that a
///      stream was accepted.
///   5. On signal or ceiling: stop, wait for the container to finish writing,
///      verify the file, and only then countersign the control file as a
///      deliberate finish.
public enum LiveScreenRecorder {
    /// How long to wait for ScreenCaptureKit to confirm capture started.
    static let startDeadline: TimeInterval = 20
    /// How long to wait for the recording output's byte count to leave zero —
    /// the proof that samples are reaching the file rather than merely that a
    /// stream was accepted. Generous: on a completely static screen the first
    /// frame still arrives, but the encoder may hold it briefly.
    static let firstBytesDeadline: TimeInterval = 15
    /// How long to wait for the container to finish writing after stopping. A
    /// multi-minute movie takes a moment to close out.
    static let finishDeadline: TimeInterval = 30
    /// How long to wait for the display list.
    static let contentDeadline: TimeInterval = 15
    /// Frames per second. Ten is ample for UI evidence and keeps a ten-minute
    /// capture small enough to live inside a run bundle.
    static let framesPerSecond: Int32 = 10

    public static func run(
        output: String,
        controlPath: String,
        display requestedDisplay: UInt32?,
        maxDuration: RecordDuration,
        permissions: PermissionProvider = LivePermissionProvider()
    ) -> RecordOutcome {
        guard #available(macOS 15.0, *) else {
            return .failed(
                stderr: "mtouch: recording to video requires macOS 15 or later "
                    + "(this machine runs \(RunMetadata.systemVersionText())). "
                    + "'mtouch screenshot' works on macOS 14.",
                code: .runtimeFailure
            )
        }
        guard permissions.screenRecordingGranted else {
            return .failed(
                stderr: PermissionError(permission: .screenRecording).diagnostic,
                code: .permissionMissing
            )
        }
        // Refuse a doomed destination before capturing anything, so a bad --out
        // costs no capture time and leaves no debris.
        if case let .failure(failure) = prepareDestination(output) {
            return .failed(stderr: failure.reason, code: .runtimeFailure)
        }
        return capture(
            output: output,
            controlPath: controlPath,
            requestedDisplay: requestedDisplay,
            maxDuration: maxDuration
        )
    }

    // MARK: - Destination

    /// Prove the destination is writable BEFORE any capture starts, by actually
    /// creating the file and removing it again.
    ///
    /// This is not belt-and-braces. ScreenCaptureKit reports that recording
    /// STARTED before its writer has touched the file: pointed at a read-only
    /// volume it happily announces success and only fails when the first sample
    /// buffer arrives, seconds later. Without this probe `record start` returns
    /// 0 for a recording that can never produce a single byte — precisely the
    /// silent failure this feature exists to prevent.
    ///
    /// Missing parents are created and an existing file is removed, matching the
    /// pinned `--out` rules `screenshot` follows.
    static func prepareDestination(_ path: String) -> Result<Void, RecordFailure> {
        if ScreenCaptureWriter.isDirectory(path) {
            return .failure(RecordFailure("mtouch: cannot write recording: path is a directory: \(path)"))
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            return .failure(RecordFailure(
                "mtouch: cannot write recording to \(path): \((error as NSError).localizedDescription)"
            ))
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            return .failure(RecordFailure(
                "mtouch: cannot write recording to \(path): \(String(cString: strerror(errno)))"
            ))
        }
        close(descriptor)
        // Hand ScreenCaptureKit a clean slate; the probe has served its purpose.
        unlink(path)
        return .success(())
    }

    // MARK: - Capture

    @available(macOS 15.0, *)
    private static func capture(
        output: String,
        controlPath: String,
        requestedDisplay: UInt32?,
        maxDuration: RecordDuration
    ) -> RecordOutcome {
        // The run-loop pump below and ScreenCaptureKit's window-server calls both
        // need the main thread; an off-main caller would starve the pump and hang
        // to a deadline. Fail loud instead — the one caller is main-correct.
        assert(Thread.isMainThread, "LiveScreenRecorder must run on the main thread")
        // A bare CLI never connects to the window server; instantiating the
        // shared application establishes that connection (idempotent), mirroring
        // `LiveScreenCapture`.
        MainActor.assumeIsolated { _ = NSApplication.shared }

        let content: SCShareableContent
        switch shareableContent() {
        case let .success(value): content = value
        case let .failure(failure): return .failed(stderr: failure.reason, code: .runtimeFailure)
        }

        let display: SCDisplay
        switch resolveDisplay(requestedDisplay, in: content.displays) {
        case let .success(value): display = value
        case let .failure(failure): return .failed(stderr: failure.reason, code: .runtimeFailure)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = streamConfiguration(for: filter)
        let events = RecordingEvents()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: events)

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = URL(fileURLWithPath: output)
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: events)

        do {
            // Added BEFORE startCapture so the first captured sample is in the
            // file; ScreenCaptureKit documents that ordering.
            try stream.addRecordingOutput(recordingOutput)
        } catch {
            return .failed(
                stderr: "mtouch: could not attach the recording output: \((error as NSError).localizedDescription)",
                code: .runtimeFailure
            )
        }

        let started = Completion()
        stream.startCapture { error in started.finish(error) }
        guard pump(until: { started.isDone || events.failure != nil },
                   deadline: Date(timeIntervalSinceNow: startDeadline))
        else {
            stopQuietly(stream)
            return .failed(
                stderr: "mtouch: the capture did not start within \(Int(startDeadline))s.",
                code: .runtimeFailure
            )
        }
        if let reason = started.error {
            stopQuietly(stream)
            return .failed(stderr: "mtouch: screen capture failed to start: \(reason)", code: .runtimeFailure)
        }
        if let reason = events.failure {
            stopQuietly(stream)
            return .failed(stderr: "mtouch: recording failed to start: \(reason)", code: .runtimeFailure)
        }
        // `startCapture` returning is not proof that BYTES are being written;
        // the recording output's own callback is. Wait for it.
        guard pump(until: { events.didStart || events.failure != nil },
                   deadline: Date(timeIntervalSinceNow: startDeadline))
        else {
            stopQuietly(stream)
            return .failed(
                stderr: "mtouch: the recording did not begin writing within \(Int(startDeadline))s.",
                code: .runtimeFailure
            )
        }
        if let reason = events.failure {
            stopQuietly(stream)
            return .failed(stderr: "mtouch: recording failed to start: \(reason)", code: .runtimeFailure)
        }
        // And neither is `didStartRecording`: ScreenCaptureKit announces it
        // before a single sample has been written. The last unfakeable proof is
        // the output's own byte count moving off zero, so the handshake waits for
        // THAT — "start succeeded" then means bytes are on disk.
        guard pump(
            until: { recordingOutput.recordedFileSize > 0 || events.failure != nil },
            deadline: Date(timeIntervalSinceNow: firstBytesDeadline)
        ) else {
            stopQuietly(stream)
            return .failed(
                stderr: "mtouch: the recording at \(output) produced no bytes within "
                    + "\(Int(firstBytesDeadline))s; refusing to report it as started.",
                code: .runtimeFailure
            )
        }
        if let reason = events.failure {
            stopQuietly(stream)
            return .failed(stderr: "mtouch: recording failed to start: \(reason)", code: .runtimeFailure)
        }

        // Capture is genuinely live: publish the handshake so `record start` can
        // return, and only now.
        let control = RecordControl(
            pid: getpid(),
            output: output,
            startedAt: Date().timeIntervalSince1970,
            display: display.displayID,
            executable: LiveProcessProbe.executablePath(of: getpid()) ?? ""
        )
        if case let .failure(failure) = RecordControlStore.write(control, to: controlPath) {
            stopQuietly(stream)
            return .failed(
                stderr: "mtouch: could not publish the recording control file: \(failure.reason)",
                code: .runtimeFailure
            )
        }
        print("recording \(output) (pid \(control.pid), display \(control.display), max \(maxDuration.text))")

        let signals = RecordSignalWatch(signals: [SIGINT, SIGTERM])
        defer { signals.cancel() }
        // The ceiling is measured on the MONOTONIC clock: a wall-clock
        // adjustment must not cut a recording short or let it overrun its bound,
        // and time the machine spends asleep — during which no frame is written —
        // must not count against it.
        let startedAt = ProcessInfo.processInfo.systemUptime
        pump(until: {
            signals.isTriggered || events.failure != nil
                || maxDuration.isExpired(startedAt: startedAt, now: ProcessInfo.processInfo.systemUptime)
        })
        let reachedLimit = !signals.isTriggered && events.failure == nil

        if let reason = events.failure {
            stopQuietly(stream)
            return .failed(stderr: "mtouch: recording failed: \(reason)", code: .runtimeFailure)
        }

        // Finalize. `stopCapture` closes the recording output; the file is only
        // playable once the output reports it has finished writing.
        let stopped = Completion()
        stream.stopCapture { error in stopped.finish(error) }
        let finished = pump(
            until: { events.didFinish || events.failure != nil },
            deadline: Date(timeIntervalSinceNow: finishDeadline)
        )
        if let reason = events.failure {
            return .failed(stderr: "mtouch: the recording could not be finalized: \(reason)", code: .runtimeFailure)
        }
        if let reason = stopped.error {
            return .failed(stderr: "mtouch: the capture could not be stopped cleanly: \(reason)", code: .runtimeFailure)
        }
        guard finished else {
            return .failed(
                stderr: "mtouch: the recording at \(output) was not finalized within \(Int(finishDeadline))s.",
                code: .runtimeFailure
            )
        }

        // The recorder verifies its OWN artifact too, so `__record-run` is
        // trustworthy on its own and never exits 0 over an unplayable file.
        let verdict = RecordArtifact.verify(path: output)
        guard let facts = verdict.facts else {
            return .failed(stderr: verdict.diagnostic, code: .runtimeFailure)
        }

        // Countersign the control file: this recording ended ON PURPOSE. Only
        // this line can distinguish a deliberate finish from a killed recorder,
        // because ScreenCaptureKit's fragments make a killed capture just as
        // readable as a finished one. Reached only after finalization AND
        // verification succeeded, so it can never be an optimistic claim.
        var countersigned = control
        countersigned.finishedAt = Date().timeIntervalSince1970
        if case let .failure(failure) = RecordControlStore.write(countersigned, to: controlPath) {
            // Fail-closed: without the countersignature `record stop` reports the
            // recording as interrupted, which is the safe direction to be wrong in.
            print("mtouch: could not record the clean finish in \(controlPath): \(failure.reason)")
        }

        let ending = reachedLimit ? " (reached --max-duration \(maxDuration.text))" : ""
        return .reported("wrote \(output) (\(RecordArtifactVerdict.factsText(facts)))\(ending)")
    }

    // MARK: - Collaborators

    @available(macOS 15.0, *)
    private static func shareableContent() -> Result<SCShareableContent, RecordFailure> {
        let box = Box<Result<SCShareableContent, RecordFailure>>()
        Task { @MainActor in
            do {
                box.set(.success(try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )))
            } catch {
                box.set(.failure(RecordFailure(
                    "mtouch: screen capture failed: \((error as NSError).localizedDescription)"
                )))
            }
        }
        guard pump(until: { box.isSet }, deadline: Date(timeIntervalSinceNow: contentDeadline)),
              let result = box.value
        else {
            return .failure(RecordFailure("mtouch: timed out enumerating displays after \(Int(contentDeadline))s."))
        }
        return result
    }

    @available(macOS 15.0, *)
    static func resolveDisplay(_ requested: UInt32?, in displays: [SCDisplay]) -> Result<SCDisplay, RecordFailure> {
        guard let requested else {
            guard let display = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays.first else {
                return .failure(RecordFailure("mtouch: no display available to record."))
            }
            return .success(display)
        }
        guard let display = displays.first(where: { $0.displayID == requested }) else {
            let available = displays.map { String($0.displayID) }.sorted().joined(separator: ", ")
            return .failure(RecordFailure(
                "mtouch: no display with id \(requested)."
                    + (available.isEmpty ? "" : " Available display ids: \(available).")
            ))
        }
        return .success(display)
    }

    @available(macOS 15.0, *)
    private static func streamConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        // H.264 wants even dimensions; rounding down keeps the frame inside the
        // captured rect.
        configuration.width = even(Int((filter.contentRect.width * scale).rounded()))
        configuration.height = even(Int((filter.contentRect.height * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        // The pointer is evidence: it shows where a synthesized click landed.
        configuration.showsCursor = true
        // Audio would capture whatever the machine is playing — a privacy hazard
        // the operator never asked for.
        configuration.capturesAudio = false
        configuration.queueDepth = 6
        return configuration
    }

    private static func even(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }

    @available(macOS 15.0, *)
    private static func stopQuietly(_ stream: SCStream) {
        // Best effort teardown on a failure path: the outcome is already decided,
        // and a stream left running would keep capturing after we exit.
        let done = Completion()
        stream.stopCapture { error in done.finish(error) }
        _ = pump(until: { done.isDone }, deadline: Date(timeIntervalSinceNow: 5))
    }

    /// Services the main run loop until `condition` holds or `deadline` passes.
    ///
    /// ScreenCaptureKit's window-server work needs a live main thread, so this
    /// PUMPS rather than blocking on a semaphore — the same reason
    /// `LiveScreenCapture` does. It is also what makes the recorder responsive to
    /// the signal watch while it is otherwise idle for minutes.
    @discardableResult
    static func pump(until condition: () -> Bool, deadline: Date) -> Bool {
        while !condition(), Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
        return condition()
    }

    /// Pumps with no deadline of its own: the recording's own bound lives in
    /// `condition`, which is the only place that knows about signals, stream
    /// failures, and the monotonic ceiling together.
    static func pump(until condition: () -> Bool) {
        while !condition() {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
    }

    /// Lock-protected one-shot cell for carrying a callback's result back to the
    /// pumping thread (mirrors `LiveScreenCapture.ResultBox`).
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return stored != nil }
        var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ newValue: Value) { lock.lock(); stored = newValue; lock.unlock() }
    }

    /// A ScreenCaptureKit completion handler's `(Error?) -> Void` result, made
    /// observable from the pumping thread. Distinguishes "not called yet" from
    /// "called with no error", which one optional cannot.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var failure: String?
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
        var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
        func finish(_ error: (any Error)?) {
            lock.lock()
            done = true
            failure = error.map { ($0 as NSError).localizedDescription }
            lock.unlock()
        }
    }
}

/// Collects the stream's and the recording output's callbacks, which arrive on
/// ScreenCaptureKit's own queues, behind a lock so the pumping thread can read
/// them safely.
@available(macOS 15.0, *)
private final class RecordingEvents: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var startedFlag = false
    private var finishedFlag = false
    private var failureReason: String?

    var didStart: Bool { lock.lock(); defer { lock.unlock() }; return startedFlag }
    var didFinish: Bool { lock.lock(); defer { lock.unlock() }; return finishedFlag }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return failureReason }

    private func fail(_ reason: String) {
        lock.lock()
        // Keep the FIRST failure: it is the one that explains the rest.
        if failureReason == nil { failureReason = reason }
        lock.unlock()
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock(); startedFlag = true; lock.unlock()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock(); finishedFlag = true; lock.unlock()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        fail((error as NSError).localizedDescription)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        fail((error as NSError).localizedDescription)
    }
}

/// Turns SIGINT/SIGTERM into a flag the recorder's pump can observe.
///
/// The default disposition is ignored and the signals are delivered through
/// `DispatchSourceSignal` instead, so nothing runs inside an actual signal
/// handler — finalizing a movie is far beyond what is async-signal-safe. SIGKILL
/// cannot be caught at all; that case is deliberately left to `record stop`'s
/// artifact verification, which refuses the unfinalized file.
final class RecordSignalWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var triggered = false
    private var sources: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "com.mtouch.record.signals")

    init(signals: [Int32]) {
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                lock.lock(); triggered = true; lock.unlock()
            }
            source.resume()
            sources.append(source)
        }
    }

    var isTriggered: Bool { lock.lock(); defer { lock.unlock() }; return triggered }

    func cancel() {
        for source in sources { source.cancel() }
        sources.removeAll()
    }
}
