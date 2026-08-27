import Darwin
import Foundation

/// A short, already-phrased reason a recording step could not be carried out.
/// Mirrors `RunCaptureFailure`: the `Result` failure types in this feature carry
/// a diagnostic string, not a taxonomy, because the caller's only job is to
/// print it.
public struct RecordFailure: Error, Equatable, Sendable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// The handshake artifact a running recorder publishes: `<record-dir>/record.json`.
///
/// It is written by the RECORDER — not by the process that spawned it — and only
/// AFTER ScreenCaptureKit has confirmed that capture actually started. That
/// ordering is the whole point: `record start` returns successfully because this
/// file appeared, so "start succeeded" means bytes are being written, not that a
/// process was launched.
///
/// `executable` carries the recorder's own resolved binary path. A pid alone
/// cannot be trusted after a crash — the number is recycled — so liveness is
/// "this pid is alive AND it is still running that binary".
public struct RecordControl: Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var pid: pid_t
    /// Absolute path of the movie being written.
    public var output: String
    /// Absolute epoch seconds at which capture was confirmed live.
    public var startedAt: Double
    /// `CGDirectDisplayID` being captured.
    public var display: UInt32
    /// Resolved path of the recorder's own binary, used to reject a recycled pid.
    public var executable: String
    /// Epoch seconds at which the recorder FINALIZED the movie and verified it —
    /// absent for as long as the recording is running, and forever if it never
    /// got that far.
    ///
    /// This exists because artifact verification alone cannot catch a killed
    /// recorder. ScreenCaptureKit flushes playable fragments as it goes, so a
    /// SIGKILLed capture leaves a movie that is short but perfectly readable —
    /// it would pass every check and be reported as a complete recording of the
    /// run. Only the recorder can say it finished on purpose, so it says so
    /// here, and nothing else may claim it on its behalf.
    public var finishedAt: Double?

    public init(
        schemaVersion: Int = RecordControl.currentSchemaVersion,
        pid: pid_t,
        output: String,
        startedAt: Double,
        display: UInt32,
        executable: String,
        finishedAt: Double? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.pid = pid
        self.output = output
        self.startedAt = startedAt
        self.display = display
        self.executable = executable
        self.finishedAt = finishedAt
    }

    /// Whether the recorder finalized on purpose. A recording whose recorder
    /// vanished without stamping this is PARTIAL, however playable its file is.
    public var finishedCleanly: Bool { finishedAt != nil }

    /// Compact JSON with sorted keys (project pattern), so the file is stable
    /// byte-for-byte for a given set of facts.
    public func jsonText() -> String {
        var fields = [
            "\"display\":\(display)",
            "\"executable\":\(JSONText.string(executable))",
        ]
        if let finishedAt { fields.append("\"finishedAt\":\(JSONText.number(finishedAt))") }
        fields.append(contentsOf: [
            "\"output\":\(JSONText.string(output))",
            "\"pid\":\(pid)",
            "\"schemaVersion\":\(schemaVersion)",
            "\"startedAt\":\(JSONText.number(startedAt))",
        ])
        return "{" + fields.joined(separator: ",") + "}\n"
    }

    /// Parse control bytes. Returns nil when the bytes are not JSON, are missing
    /// the two fields that make a control file actionable (`pid`, `output`), or
    /// carry a schema version this binary does not understand — a version gate
    /// mirroring `SessionStore.load`, so a future v2 file is reported as damaged
    /// rather than mis-read as a live recording.
    public static func parse(_ data: Data) -> RecordControl? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int, version == currentSchemaVersion,
              let pid = object["pid"] as? Int, pid > 0,
              let output = object["output"] as? String, !output.isEmpty
        else { return nil }
        return RecordControl(
            schemaVersion: version,
            pid: pid_t(clamping: pid),
            output: output,
            startedAt: object["startedAt"] as? Double ?? 0,
            display: UInt32(clamping: object["display"] as? Int ?? 0),
            executable: object["executable"] as? String ?? "",
            // Absent is MEANINGFUL — "this recording never finalized" — so it is
            // read as nil rather than defaulted to anything.
            finishedAt: object["finishedAt"] as? Double
        )
    }
}

/// What the operating system says about the pid a control file names.
public enum RecordProcessIdentity: Sendable, Equatable {
    /// No such process.
    case gone
    /// Alive and signalable by us. `executable` is its resolved binary path, or
    /// nil when it could not be read (then identity cannot be disproved).
    case alive(executable: String?)
    /// Alive but owned by another user, so it cannot be a recorder we spawned.
    case foreign
}

/// What a control file means right now.
public enum RecordControlState: Sendable, Equatable {
    /// No control file: nothing is recording here.
    case absent
    /// A recorder is running and is the one this file names.
    case live(RecordControl)
    /// A control file survived its recorder (crash, kill, or a finished
    /// self-terminated capture). Recoverable: the reason names why.
    case stale(RecordControl, reason: String)
    /// A control file exists but says nothing usable. Also recoverable — the
    /// alternative would be refusing to record on this directory forever.
    case damaged(path: String, reason: String)

    /// The recording a caller can act on, live or not.
    public var control: RecordControl? {
        switch self {
        case let .live(control): return control
        case let .stale(control, _): return control
        case .absent, .damaged: return nil
        }
    }

    /// Why this state is not `.live`, phrased for a diagnostic. Nil when live.
    public var staleReason: String? {
        switch self {
        case let .stale(_, reason): return reason
        case let .damaged(_, reason): return reason
        case .absent, .live: return nil
        }
    }
}

/// Classifies a control file. Pure over `data` and the process probe, so every
/// branch (absent / live / stale pid / recycled pid / foreign pid / damaged) is
/// unit-testable without spawning anything.
public enum RecordControlStateMachine {
    public static func state(
        path: String,
        data: Data?,
        identity: (pid_t) -> RecordProcessIdentity
    ) -> RecordControlState {
        guard let data else { return .absent }
        guard let control = RecordControl.parse(data) else {
            return .damaged(
                path: path,
                reason: "the control file is not a readable mtouch recording record"
            )
        }
        switch identity(control.pid) {
        case .gone:
            return .stale(control, reason: "its recorder (pid \(control.pid)) is no longer running")
        case .foreign:
            return .stale(control, reason: "pid \(control.pid) now belongs to another user, so it is not the recorder")
        case let .alive(executable):
            // An unreadable path, or a control file written without one, cannot
            // DISPROVE identity — and refusing to overwrite a possibly-live
            // capture is the safer of the two errors, so both read as live.
            if let executable, !control.executable.isEmpty, executable != control.executable {
                return .stale(
                    control,
                    reason: "pid \(control.pid) is now running \(executable), not the recorder"
                )
            }
            return .live(control)
        }
    }
}

/// Live process identity via `kill(pid, 0)` + `proc_pidpath`. Neither call
/// signals or otherwise disturbs the target.
public enum LiveProcessProbe {
    public static func identity(of pid: pid_t) -> RecordProcessIdentity {
        guard pid > 0 else { return .gone }
        if kill(pid, 0) != 0 {
            // EPERM means the process exists but is not ours to signal.
            return errno == EPERM ? .foreign : .gone
        }
        return .alive(executable: executablePath(of: pid))
    }

    /// Resolved binary path of `pid`, or nil when it cannot be read.
    public static func executablePath(of pid: pid_t) -> String? {
        // Decoded from the RETURNED LENGTH rather than via `String(cString:)`,
        // which the array overload deprecates on newer toolchains.
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).prefix(while: { $0 != 0 })
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}

/// Reads/writes/removes the control file. The write is ATOMIC (temp + rename),
/// so `record start`'s poll never observes a half-written handshake and mistakes
/// it for a damaged one.
public enum RecordControlStore {
    public static func read(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    public static func write(_ control: RecordControl, to path: String) -> Result<Void, RecordFailure> {
        switch ScreenCaptureWriter.write(Data(control.jsonText().utf8), to: path) {
        case .success:
            return .success(())
        case let .failure(error):
            return .failure(RecordFailure(error.diagnostic))
        }
    }

    public static func clear(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
