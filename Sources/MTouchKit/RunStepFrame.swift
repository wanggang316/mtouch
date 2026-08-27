import Darwin
import Foundation

/// A moment located INSIDE a screen recording, recorded in a step's evidence in
/// place of a screenshot.
///
/// It exists because a second capture session opened by the SAME client
/// application invalidates a recording that application is already running —
/// measured, and reproduced every time. So while our own recording is live we do
/// not open one: the moment is marked here and `mtouch report` cuts the still out
/// of the movie afterwards. The still is then provably from the same capture as
/// the video, which is strictly better evidence than a second one taken alongside
/// it.
///
/// `offset` is carried rather than derived at render time because the control
/// file the recording start time comes from is CLEARED by `record stop` — by the
/// time a report is rendered there is nothing left to subtract from.
public struct RunStepFrame: Sendable, Equatable {
    /// The movie this frame lives in: run-root-relative when it sits inside the
    /// bundle (so the bundle stays movable), absolute when `--out` put it
    /// elsewhere.
    public let movie: String
    /// Seconds from the start of the recording to this moment — where in the
    /// movie the still is cut from.
    public let offset: Double
    /// Epoch seconds at which the recording was confirmed live.
    public let recordingStartedAt: Double
    /// Epoch seconds of the moment itself, so `offset` is arithmetic a reader can
    /// check rather than a number to be taken on trust.
    public let wallClock: Double

    public init(movie: String, offset: Double, recordingStartedAt: Double, wallClock: Double) {
        self.movie = movie
        self.offset = offset
        self.recordingStartedAt = recordingStartedAt
        self.wallClock = wallClock
    }

    /// Compact JSON object with sorted keys, matching the hand-rolled rendering
    /// the rest of the record uses.
    func jsonObject() -> String {
        "{"
            + "\"movie\":\(JSONText.string(movie)),"
            + "\"offset\":\(JSONText.number(offset)),"
            + "\"recordingStartedAt\":\(JSONText.number(recordingStartedAt)),"
            + "\"wallClock\":\(JSONText.number(wallClock))"
            + "}"
    }

    /// Parse one marker, or nil when the object is missing the two fields that
    /// make it actionable (`movie`, `offset`). A damaged marker degrades to
    /// absence — the report then says the step has no imagery, never crashes.
    static func parse(_ object: [String: Any]) -> RunStepFrame? {
        guard let movie = object["movie"] as? String, !movie.isEmpty,
              let offset = object["offset"] as? Double, offset.isFinite
        else { return nil }
        return RunStepFrame(
            movie: movie,
            offset: offset,
            recordingStartedAt: object["recordingStartedAt"] as? Double ?? 0,
            wallClock: object["wallClock"] as? Double ?? 0
        )
    }
}

/// The facts a live recording offers the rest of the tool: what it is writing,
/// when it started, and who is doing it.
public struct RunRecordingFacts: Sendable, Equatable {
    /// Absolute path of the movie being written, as the recorder published it.
    public let movie: String
    /// Epoch seconds at which capture was confirmed live.
    public let startedAt: Double
    public let pid: pid_t

    public init(movie: String, startedAt: Double, pid: pid_t) {
        self.movie = movie
        self.startedAt = startedAt
        self.pid = pid
    }
}

/// The seam through which everything that would otherwise open a capture session
/// asks "is one of our own recordings running right now?".
///
/// It is a seam so the answer can be stubbed: the tests that pin "a live
/// recording means NO capture is attempted" must be able to assert that without
/// a display, a grant, or a recorder process.
public protocol RunRecordingProbing: Sendable {
    /// The recording live for `run`, or nil when none is.
    func liveRecording(for run: RunBundle) -> RunRecordingFacts?
}

/// The live answer, read from the SAME control file and classified by the SAME
/// state machine `record status` uses — so "live" means exactly what `record
/// status` prints, and there is only one definition of it.
///
/// It only ever READS. Asking whether something is recording must not create the
/// bundle, the directory, or a second control file.
public struct LiveRunRecordingProbe: RunRecordingProbing {
    private let read: @Sendable (String) -> Data?
    private let identity: @Sendable (pid_t) -> RecordProcessIdentity

    public init(
        read: @escaping @Sendable (String) -> Data? = RecordControlStore.read,
        identity: @escaping @Sendable (pid_t) -> RecordProcessIdentity = LiveProcessProbe.identity(of:)
    ) {
        self.read = read
        self.identity = identity
    }

    public func liveRecording(for run: RunBundle) -> RunRecordingFacts? {
        let path = run.recordControlPath
        // A stale or damaged control file is NOT live: its recorder is gone, so
        // nothing can be invalidated and an ordinary capture is safe again.
        guard case let .live(control) = RecordControlStateMachine.state(
            path: path, data: read(path), identity: identity
        ) else { return nil }
        return RunRecordingFacts(movie: control.output, startedAt: control.startedAt, pid: control.pid)
    }
}

/// The guard standalone `mtouch screenshot` applies before it captures anything.
///
/// Refusing is the whole point. A screenshot taken during our own recording
/// succeeds and silently kills the recording — the operator learns about it much
/// later, from a `record stop` that fails. An exit-1 refusal is recoverable; a
/// destroyed recording is not.
public enum RunRecordingGuard {
    /// The recording live for the run `environment` selects, or nil when no run
    /// directory is in force.
    ///
    /// Deliberately scoped to the ACTIVE RUN: a recording somewhere else on the
    /// machine — including one this tool did not start — is none of this
    /// command's business, and guessing at one would refuse work for no reason.
    public static func liveRecording(
        environment: [String: String],
        probe: RunRecordingProbing = LiveRunRecordingProbe()
    ) -> RunRecordingFacts? {
        guard let path = environment[MTouchEnvironment.runDirKey], !path.isEmpty else { return nil }
        // `RunBundle(root:)` is a pure path value — unlike `resolve`, it creates
        // nothing, so a question never has a side effect.
        return probe.liveRecording(for: RunBundle(root: URL(fileURLWithPath: path).path))
    }

    /// The stderr diagnostic for the refusal, naming the recording at risk and
    /// both ways forward.
    public static func refusal(_ facts: RunRecordingFacts) -> String {
        "mtouch: a recording is in progress for this run (\(facts.movie), pid \(facts.pid)); "
            + "capturing a screenshot now would invalidate it. Stop it first with 'mtouch record stop', "
            + "or take the still from the recording — run the command with --capture "
            + "(MTOUCH_RUN_CAPTURE=1) and 'mtouch report' cuts each step's frame out of the movie."
    }
}
