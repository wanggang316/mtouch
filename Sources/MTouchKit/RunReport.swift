import Foundation

/// One recorded argument, already rendered to text for display. Kept as a value
/// (not a tuple) so the whole report model stays `Equatable` and testable.
public struct RunReportArg: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// One trajectory record, narrowed to what the timeline shows.
public struct RunReportRecord: Sendable, Equatable {
    public let step: Int?
    public let command: String
    public let args: [RunReportArg]
    public let wallClock: Double?
    public let monotonic: Double?
    public let ok: Bool
    public let exit: Int?
    public let errorClass: String?
    public let diff: String?
    public let screenshotPath: String?
    public let evidence: RunEvidence

    /// `0001`-style ordinal, or an em dash for a record written before a run
    /// directory was in play (an operator can still read it, it just has no
    /// screenshots).
    public var ordinalText: String {
        step.map { String(format: "%04d", $0) } ?? "—"
    }
}

/// A timeline entry. A line that is not valid JSON is KEPT as `.unreadable`
/// rather than dropped: silently swallowing a damaged record would misrepresent
/// the run, which is the one thing an evidence bundle must not do.
public enum RunReportEntry: Sendable, Equatable {
    case record(RunReportRecord)
    case unreadable(line: Int, raw: String)
}

/// Everything the renderer needs, read off disk. Loading is TOTAL: a missing or
/// damaged `run.json`, an absent/empty trajectory, an absent `video/`, and
/// missing step images each degrade to an explicit absence the report states
/// plainly — never to a failure or a broken page.
public struct RunReportBundle: Sendable, Equatable {
    public let root: String
    public let metadata: RunMetadata?
    public let trajectoryPresent: Bool
    public let entries: [RunReportEntry]
    /// Run-root-relative paths of anything sitting in `video/`, sorted by name.
    public let videoFiles: [String]

    public var records: [RunReportRecord] {
        entries.compactMap { if case let .record(record) = $0 { return record } else { return nil } }
    }

    public var passedCount: Int { records.filter(\.ok).count }
    public var failedCount: Int { records.filter { !$0.ok }.count }
    public var unreadableCount: Int {
        entries.filter { if case .unreadable = $0 { return true } else { return false } }.count
    }

    /// Wall-clock span the bundle covers, in seconds: from the run's creation (or
    /// the first record, when `run.json` is gone) to the last record. Nil when
    /// there is nothing to measure. Derived only from RECORDED data, never from
    /// the time of rendering, so two renders of one bundle agree.
    public var durationSeconds: Double? {
        let stamps = records.compactMap(\.wallClock).filter { $0 > 0 }
        guard let last = stamps.max() else { return nil }
        let created = metadata.map(\.createdAtWallClock).flatMap { $0 > 0 ? $0 : nil }
        let first = created ?? stamps.min()
        guard let first, last >= first else { return nil }
        return last - first
    }
}

/// Reads a run bundle off disk into a `RunReportBundle`.
public enum RunReportLoader {
    public static func load(runDirectory: String) -> RunReportBundle {
        let bundle = RunBundle(root: URL(fileURLWithPath: runDirectory).path)
        // Decoded leniently rather than with a failable UTF-8 read: a single
        // corrupt byte must degrade to one unreadable LINE, not to "this run has
        // no trajectory at all".
        let data = try? Data(contentsOf: URL(fileURLWithPath: bundle.trajectoryPath))
        return RunReportBundle(
            root: bundle.root,
            metadata: bundle.loadMetadata(),
            trajectoryPresent: data != nil,
            entries: parseEntries(data.map { String(decoding: $0, as: UTF8.self) } ?? ""),
            videoFiles: videoFiles(in: bundle)
        )
    }

    /// One entry per non-empty line, in FILE order — which is completion order for
    /// concurrent writers, and identical to allocation order for the ordinary
    /// sequential case. The step ordinal is shown alongside, so the two orders are
    /// always distinguishable.
    static func parseEntries(_ trajectory: String) -> [RunReportEntry] {
        var entries: [RunReportEntry] = []
        for (offset, rawLine) in trajectory.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let record = parseRecord(line) {
                entries.append(.record(record))
            } else {
                entries.append(.unreadable(line: offset + 1, raw: line))
            }
        }
        return entries
    }

    static func parseRecord(_ line: String) -> RunReportRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let command = object["command"] as? String
        else { return nil }
        let outcome = object["outcome"] as? [String: Any]
        let evidence = object["evidence"] as? [String: Any]
        return RunReportRecord(
            step: object["step"] as? Int,
            command: command,
            args: renderArgs(object["args"] as? [String: Any] ?? [:]),
            wallClock: object["wallClock"] as? Double,
            monotonic: object["timestamp"] as? Double,
            ok: outcome?["ok"] as? Bool ?? false,
            exit: outcome?["exit"] as? Int,
            errorClass: outcome?["errorClass"] as? String,
            diff: object["diff"] as? String,
            screenshotPath: object["screenshotPath"] as? String,
            evidence: RunEvidence(
                before: evidence?["before"] as? String,
                after: evidence?["after"] as? String,
                state: evidence?["state"] as? String,
                captureError: evidence?["captureError"] as? String
            )
        )
    }

    /// Args in sorted key order, each value rendered the way the CLI would print
    /// it (numbers compact, booleans as `true`/`false`, strings verbatim — the
    /// renderer escapes them for HTML).
    static func renderArgs(_ args: [String: Any]) -> [RunReportArg] {
        args.keys.sorted().map { key in
            RunReportArg(key: key, value: renderValue(args[key]))
        }
    }

    private static func renderValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            // A JSON boolean bridges to NSNumber too, and `as? Bool` would also
            // accept the integers 0 and 1 — so ask the CoreFoundation type instead
            // and keep `{"dy":1}` from rendering as `true`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return JSONText.number(number.doubleValue)
        }
        return String(describing: value ?? "")
    }

    /// Only MOVIES get an embed slot. `video/` also holds a recording's control
    /// file and its log, and rendering those into a `<video>` element would
    /// produce a player that can never play.
    static let movieExtensions: Set<String> = ["mp4", "mov", "m4v"]

    private static func videoFiles(in bundle: RunBundle) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bundle.videoDirectory)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .filter { movieExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted()
            .map { "\(RunBundle.videoDirectoryName)/\($0)" }
    }
}
