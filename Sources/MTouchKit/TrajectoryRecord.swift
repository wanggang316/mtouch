import Foundation

/// The four record classes, keyed off the command/tool that produced the record.
/// The class decides which digest fields a record carries (see `TrajectoryRecord`):
///
///   - `.snapshot` — carries the tree `digest` (no pre/post pair).
///   - `.action`   — a MUTATING command (any `act …` verb, and the `app` /
///     `clipboard` write verbs); carries `preDigest`/`postDigest` (the
///     `Session.digest` before/after) plus the emitted `diff` when it has one.
///   - `.read`     — a read-only command (`apps`/`windows`/`doctor`/`wait`); no
///     digests (the documented absent form).
///   - `.screenshot` — references the written PNG path, NEVER image bytes.
public enum TrajectoryKind: Sendable, Equatable {
    case snapshot
    case action
    case read
    case screenshot
}

/// A tool/command's arguments as recorded in a trajectory line. Values keep their
/// natural JSON type (string/int/double/bool) so they round-trip; keys render in
/// sorted order so a given call shapes byte-identically regardless of surface
/// (CLI vs MCP). Any user-controlled string is escaped via `JSONText`, so unicode
/// survives a `jq` round-trip.
public struct TrajectoryArgs: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
    }

    private var values: [String: Value]

    public init(_ values: [String: Value] = [:]) {
        self.values = values
    }

    /// Build args from optional pairs, dropping any whose value is nil — so an
    /// absent flag/option simply does not appear (matching the MCP surface, which
    /// only records keys the client actually sent).
    public static func build(_ pairs: [String: Value?]) -> TrajectoryArgs {
        var kept: [String: Value] = [:]
        for (key, value) in pairs {
            if let value { kept[key] = value }
        }
        return TrajectoryArgs(kept)
    }

    /// A copy with `keys` removed. Used to strip a payload-bearing key (`text`,
    /// `combo`) from a refused/failed keyboard record so a secret never persists.
    public func removing(_ keys: Set<String>) -> TrajectoryArgs {
        var copy = values
        for key in keys { copy.removeValue(forKey: key) }
        return TrajectoryArgs(copy)
    }

    /// Compact JSON object with sorted keys.
    func jsonObject() -> String {
        let body = values.keys.sorted().map { key in
            "\(JSONText.string(key)):\(render(values[key]!))"
        }.joined(separator: ",")
        return "{\(body)}"
    }

    private func render(_ value: Value) -> String {
        switch value {
        case let .string(string): return JSONText.string(string)
        case let .int(int): return String(int)
        case let .double(double): return JSONText.number(double)
        case let .bool(bool): return bool ? "true" : "false"
        }
    }
}

/// The outcome-facing facts a recorder needs, mapped from each surface's native
/// result (a pipeline `Outcome` for the CLI, a `ToolResult` for MCP) so the record
/// shape is identical across surfaces. `exit` is the CLI exit code (nil for MCP,
/// which has no exit code); `errorClass` is a short class on failure; `diff` and
/// `screenshotPath` are the class-specific payloads.
public struct TrajectoryOutcomeInfo: Sendable, Equatable {
    public let ok: Bool
    public let exit: Int32?
    public let errorClass: String?
    public let diff: String?
    public let screenshotPath: String?
    /// `false` when the action DELIVERED input without reading the accessibility
    /// tree — either because `--no-verify` asked for that, or because delivery
    /// itself could not be confirmed and there was nothing left to verify against.
    /// nil means the ordinary contract held: the action was verified against a
    /// post-action walk, or the record is not an action at all.
    public let verified: Bool?
    /// `false` when the action's events were POSTED but the bounded flush could not
    /// establish that the window server processed them. Distinct from `verified`
    /// and strictly stronger: `verified == false` alone says the EFFECT went
    /// unchecked, this says the DELIVERY did. nil means the question does not
    /// arise — nothing was posted, or the posted events were confirmed.
    public let deliveryConfirmed: Bool?
    /// `false` when the action's post-action diff was taken but never stopped
    /// changing before the settle budget expired (see `SettleBudget`). Unlike the
    /// two fields above, the record still carries its `diff`: there IS a reading,
    /// it is simply provisional. nil means the reading settled, or the record is
    /// not an action at all.
    public let settled: Bool?

    public init(
        ok: Bool,
        exit: Int32?,
        errorClass: String?,
        diff: String? = nil,
        screenshotPath: String? = nil,
        verified: Bool? = nil,
        deliveryConfirmed: Bool? = nil,
        settled: Bool? = nil
    ) {
        self.ok = ok
        self.exit = exit
        self.errorClass = errorClass
        self.diff = diff
        self.screenshotPath = screenshotPath
        self.verified = verified
        self.deliveryConfirmed = deliveryConfirmed
        self.settled = settled
    }
}

/// One JSONL trajectory record. Rendered by hand (project pattern: byte-stable key
/// order via `JSONText`, mirroring `DiffJSON`/`SnapshotJSON`) so the line is a
/// single compact object the crash/concurrency guarantees can rely on. Every
/// record carries `command`, a monotonic `timestamp` (for ordering and the digest
/// chain), an absolute `wallClock` (epoch seconds, recoverable as wall time), `args`,
/// and an `outcome` object; the digest/diff/screenshot fields are present only for
/// the classes that define them, so a reader distinguishes classes by field presence.
struct TrajectoryRecord {
    let command: String
    /// Monotonic clock (systemUptime), used for ordering and the digest chain.
    /// Correct for ordering but NOT an absolute time and resets across reboot.
    let timestamp: Double
    /// Absolute wall-clock time as epoch seconds (`Date().timeIntervalSince1970`),
    /// so a record is recoverable to a real point in time; distinct from the
    /// monotonic `timestamp` and never used for ordering.
    let wallClock: Double
    let args: TrajectoryArgs
    let ok: Bool
    let exit: Int32?
    let errorClass: String?
    let preDigest: String?
    let postDigest: String?
    let digest: String?
    let diff: String?
    let screenshotPath: String?
    /// Present — and only ever `false` — when the action delivered input WITHOUT
    /// reading the accessibility tree (`--no-verify`, or a delivery too doubtful to
    /// be worth verifying). Such a record also carries no `diff`, because none was
    /// taken. Its ABSENCE is the ordinary case: the action was verified against a
    /// post-action walk, and the `diff` is that verification.
    let verified: Bool?
    /// Present — and only ever `false` — when the action's events were posted but
    /// the bounded flush could not confirm the window server processed them. It
    /// always accompanies `verified: false` and says strictly more: not merely that
    /// the effect went unchecked, but that the input's ARRIVAL is unestablished.
    let deliveryConfirmed: Bool?
    /// Present — and only ever `false` — when the action's post-action diff never
    /// stopped changing within the settle budget. Such a record DOES carry its
    /// `diff`; the field says that diff is the best reading available rather than a
    /// finished one. Its absence is the ordinary case: the reading repeated across
    /// two consecutive walks.
    let settled: Bool?
    /// The run bundle's step ordinal for this record; present only when a run
    /// directory is active. It is what joins a record to its `steps/NNNN-…png`
    /// files, so the report never has to guess by position — which concurrent
    /// writers would break.
    let step: Int?
    /// The step images this record collected (and any capture failure). Absent
    /// when captures are off, which is the default.
    let evidence: RunEvidence?

    init(
        command: String,
        timestamp: Double,
        wallClock: Double,
        args: TrajectoryArgs,
        ok: Bool,
        exit: Int32?,
        errorClass: String?,
        preDigest: String?,
        postDigest: String?,
        digest: String?,
        diff: String?,
        screenshotPath: String?,
        verified: Bool? = nil,
        deliveryConfirmed: Bool? = nil,
        settled: Bool? = nil,
        step: Int? = nil,
        evidence: RunEvidence? = nil
    ) {
        self.command = command
        self.timestamp = timestamp
        self.wallClock = wallClock
        self.args = args
        self.ok = ok
        self.exit = exit
        self.errorClass = errorClass
        self.preDigest = preDigest
        self.postDigest = postDigest
        self.digest = digest
        self.diff = diff
        self.screenshotPath = screenshotPath
        self.verified = verified
        self.deliveryConfirmed = deliveryConfirmed
        self.settled = settled
        self.step = step
        self.evidence = evidence
    }

    /// The full `<json>\n` line. The trailing newline is part of the returned
    /// string so the whole record — line + terminator — is written in ONE atomic
    /// append (never a line without its newline).
    func jsonLine() -> String {
        var fields: [String] = [
            "\"command\":\(JSONText.string(command))",
            "\"timestamp\":\(JSONText.number(timestamp))",
            "\"wallClock\":\(JSONText.number(wallClock))",
            "\"args\":\(args.jsonObject())",
            "\"outcome\":\(outcomeObject())",
        ]
        if let digest { fields.append("\"digest\":\(JSONText.string(digest))") }
        if let preDigest { fields.append("\"preDigest\":\(JSONText.string(preDigest))") }
        if let postDigest { fields.append("\"postDigest\":\(JSONText.string(postDigest))") }
        if let verified { fields.append("\"verified\":\(verified ? "true" : "false")") }
        if let deliveryConfirmed {
            fields.append("\"deliveryConfirmed\":\(deliveryConfirmed ? "true" : "false")")
        }
        if let settled { fields.append("\"settled\":\(settled ? "true" : "false")") }
        if let diff { fields.append("\"diff\":\(JSONText.string(diff))") }
        if let screenshotPath { fields.append("\"screenshotPath\":\(JSONText.string(screenshotPath))") }
        if let step { fields.append("\"step\":\(step)") }
        if let evidence, !evidence.isEmpty { fields.append("\"evidence\":\(evidence.jsonObject())") }
        return "{" + fields.joined(separator: ",") + "}\n"
    }

    private func outcomeObject() -> String {
        let exitField = exit.map { String($0) } ?? "null"
        let classField = errorClass.map(JSONText.string) ?? "null"
        return "{\"ok\":\(ok ? "true" : "false"),\"exit\":\(exitField),\"errorClass\":\(classField)}"
    }

    /// Recover the written PNG path from a screenshot's human line
    /// (`wrote <path> (<W>x<H> px, …)`) so an MCP screenshot record can reference
    /// the path WITHOUT touching image bytes. Returns nil if the line is not the
    /// pinned form.
    static func screenshotPath(fromMessage message: String?) -> String? {
        guard let message, message.hasPrefix("wrote ") else { return nil }
        let rest = message.dropFirst("wrote ".count)
        if let range = rest.range(of: " (") {
            return String(rest[..<range.lowerBound])
        }
        return String(rest)
    }
}

// MARK: - Exit-code → error class

public extension MTouchExitCode {
    /// A short, stable error class for a failing outcome, or nil for success.
    var trajectoryErrorClass: String? {
        switch self {
        case .success: return nil
        case .runtimeFailure: return "runtime"
        case .permissionMissing: return "permission"
        case .refError: return "ref"
        case .waitTimeout: return "wait-timeout"
        case .secureInput: return "secure-input"
        case .usageError: return "usage"
        }
    }
}

// MARK: - Native outcome → TrajectoryOutcomeInfo (one mapping per surface)

public extension SnapshotOutcome {
    var trajectoryInfo: TrajectoryOutcomeInfo {
        switch self {
        case .rendered:
            return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil)
        case let .failed(_, code):
            return TrajectoryOutcomeInfo(ok: false, exit: code.rawValue, errorClass: code.trajectoryErrorClass)
        }
    }
}

public extension ActOutcome {
    var trajectoryInfo: TrajectoryOutcomeInfo {
        switch self {
        case let .acted(output):
            return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil, diff: output)
        case let .actedUnsettled(output):
            // The diff IS recorded — a provisional reading is still the only
            // evidence there is — but `settled: false` says not to trust it as the
            // action's finished effect.
            return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil, diff: output, settled: false)
        case .deliveredUnverified:
            // No `diff`: none was taken, and the stdout notice must never be
            // recorded as if it were one. `verified: false` carries the fact.
            return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil, verified: false)
        case .deliveredUnconfirmed:
            // Also no `diff`, and BOTH fields: nothing was verified (no walk was
            // taken) and, the stronger fact, delivery itself is unestablished.
            return TrajectoryOutcomeInfo(
                ok: true, exit: 0, errorClass: nil, verified: false, deliveryConfirmed: false
            )
        case let .failed(_, code):
            return TrajectoryOutcomeInfo(ok: false, exit: code.rawValue, errorClass: code.trajectoryErrorClass)
        }
    }
}

public extension ScreenshotOutcome {
    var trajectoryInfo: TrajectoryOutcomeInfo {
        switch self {
        case let .written(path, _):
            return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil, screenshotPath: path)
        case let .failed(_, code):
            return TrajectoryOutcomeInfo(ok: false, exit: code.rawValue, errorClass: code.trajectoryErrorClass)
        }
    }
}

public extension AppOutcome {
    var trajectoryInfo: TrajectoryOutcomeInfo {
        switch self {
        case .reported:
            return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil)
        case let .failed(_, code):
            return TrajectoryOutcomeInfo(ok: false, exit: code.rawValue, errorClass: code.trajectoryErrorClass)
        }
    }
}

public extension ClipboardOutcome {
    var trajectoryInfo: TrajectoryOutcomeInfo {
        switch self {
        case .rendered:
            return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil)
        case let .failed(_, code):
            return TrajectoryOutcomeInfo(ok: false, exit: code.rawValue, errorClass: code.trajectoryErrorClass)
        }
    }
}

public extension ReadOutcome {
    /// `read` is a READ record: the element's text is never carried into the
    /// trajectory (only `.action` records carry a payload), so a long answer — or a
    /// masked secure value — is not duplicated into the log.
    var trajectoryInfo: TrajectoryOutcomeInfo {
        switch self {
        case .read:
            return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil)
        case let .failed(_, code):
            return TrajectoryOutcomeInfo(ok: false, exit: code.rawValue, errorClass: code.trajectoryErrorClass)
        }
    }
}

public extension WaitOutcome {
    var trajectoryInfo: TrajectoryOutcomeInfo {
        switch self {
        case .satisfied:
            return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil)
        case let .failed(_, code):
            return TrajectoryOutcomeInfo(ok: false, exit: code.rawValue, errorClass: code.trajectoryErrorClass)
        }
    }
}

public extension ToolResult {
    /// The MCP surface has no exit code, so `exit` is nil and a domain failure maps
    /// to a generic `error` class. `diff` (for `.action`) is the tool's text
    /// payload — the SAME diff the CLI prints — and `screenshotPath` (for
    /// `.screenshot`) is recovered from the text line, never the image payload, so
    /// no bytes are embedded.
    ///
    /// `unverified` is the MCP analogue of the CLI's `--no-verify`: a tool result
    /// is just text, so the caller — which knows what the client asked for — has to
    /// say whether the action was verified. It suppresses the `diff`, because the
    /// payload is the "nothing was verified" notice rather than a diff, and marks
    /// the record with the same dedicated field the CLI writes.
    ///
    /// An UNCONFIRMED delivery comes from the result itself (`deliveryConfirmed`),
    /// not the request: no client asks for it. It implies the unverified treatment —
    /// no walk was taken, so the payload is a notice and not a diff — and adds the
    /// stronger field on top.
    func trajectoryInfo(kind: TrajectoryKind, unverified: Bool = false) -> TrajectoryOutcomeInfo {
        let ok = !isError
        let text: String? = payloads.compactMap {
            if case let .text(value) = $0 { return value }
            return nil
        }.first
        let unconfirmed = deliveryConfirmed == false
        var diff: String?
        var screenshotPath: String?
        var verified: Bool?
        var confirmed: Bool?
        var stable: Bool?
        if ok {
            if kind == .action { diff = (unverified || unconfirmed) ? nil : text }
            if kind == .action, unverified || unconfirmed { verified = false }
            if kind == .action, unconfirmed { confirmed = false }
            // An unsettled reading also comes from the result rather than the
            // request, and — unlike the two above — keeps its `diff`: it is a real
            // reading, just not a finished one.
            if kind == .action, settled == false { stable = false }
            if kind == .screenshot { screenshotPath = TrajectoryRecord.screenshotPath(fromMessage: text) }
        }
        return TrajectoryOutcomeInfo(
            ok: ok,
            exit: nil,
            errorClass: ok ? nil : "error",
            diff: diff,
            screenshotPath: screenshotPath,
            verified: verified,
            deliveryConfirmed: confirmed,
            settled: stable
        )
    }
}

// MARK: - Rendering helpers

public extension ScreenPoint {
    /// The `x,y` form used in trajectory args, dropping a trailing `.0` for
    /// integral coordinates (`120,64` not `120.0,64.0`) to match the raw string an
    /// MCP client sends.
    var rendered: String { "\(JSONText.number(x)),\(JSONText.number(y))" }
}

public extension ActVerb {
    /// The verb name recorded in `args.verb`, matching the MCP tool's `verb`
    /// vocabulary so a CLI `act press` and an MCP `act`/verb=press shape alike.
    var trajectoryName: String {
        switch self {
        case .press: return "press"
        case .focus: return "focus"
        case .showMenu: return "show-menu"
        case .setValue: return "set-value"
        }
    }
}
