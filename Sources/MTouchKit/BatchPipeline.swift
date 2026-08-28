import Foundation

/// One EXECUTED step's outcome, as the batch report shows it. `payload` is the
/// step's text payload exactly as the tool renders it for the MCP surface — which
/// is byte-identical to what the CLI command prints for the same state — so an
/// agent reading a batch report re-learns nothing.
public struct BatchStepRecord: Equatable, Sendable {
    /// 1-based position in the batch (NOT the input line; blank lines don't run).
    public let step: Int
    public let tool: String
    public let ok: Bool
    public let payload: String

    public init(step: Int, tool: String, ok: Bool, payload: String) {
        self.step = step
        self.tool = tool
        self.ok = ok
        self.payload = payload
    }
}

/// A completed batch execution: which steps ran and how many there were in
/// total. Because execution STOPS at the first failure, only the LAST record can
/// be a failure, and `total - records.count` steps were never run.
public struct BatchRun: Equatable, Sendable {
    public let total: Int
    public let records: [BatchStepRecord]

    public init(total: Int, records: [BatchStepRecord]) {
        self.total = total
        self.records = records
    }

    /// The failed step's ordinal, or nil when every executed step succeeded.
    /// Stop-on-failure means a failure can only sit at the end.
    public var failedStep: Int? {
        records.last.flatMap { $0.ok ? nil : $0.step }
    }

    public var notRunCount: Int { total - records.count }

    public var succeeded: Bool { failedStep == nil }
}

/// Executes a batch script: validate EVERYTHING, then run the steps in order,
/// stopping at the first failure. The dispatcher is a seam — the CLI passes the
/// MCP dispatch (with trajectory recording), tests pass a spy — so sequencing and
/// stop-on-failure are unit-testable without any live AX.
public enum BatchPipeline {
    public enum Outcome {
        /// The input failed validation; NOTHING was executed. Usage error (64).
        case invalid(diagnostic: String)
        /// The steps ran (up to the first failure). Exit 0 when `run.succeeded`,
        /// else 1 — one process can only return one code; each step's own
        /// exit-code taxonomy is preserved in its trajectory record.
        case executed(BatchRun)
    }

    public static func run(input: String, dispatch: (BatchStep) -> ToolResult) -> Outcome {
        let steps: [BatchStep]
        do {
            steps = try BatchScript.parse(input)
        } catch let error as BatchScriptError {
            return .invalid(diagnostic: error.diagnostic)
        } catch {
            return .invalid(diagnostic: "mtouch: batch: invalid input: \(error)")
        }
        var records: [BatchStepRecord] = []
        for (index, step) in steps.enumerated() {
            let result = dispatch(step)
            records.append(BatchStepRecord(
                step: index + 1, tool: step.tool, ok: !result.isError, payload: payloadText(result)
            ))
            if result.isError { break }
        }
        return .executed(BatchRun(total: steps.count, records: records))
    }

    /// The step's printable payload: its text parts joined. An image part (the
    /// screenshot tool's PNG bytes) has no text form; its accompanying message
    /// already names the written path, matching what the CLI prints.
    static func payloadText(_ result: ToolResult) -> String {
        result.payloads
            .compactMap { payload -> String? in
                if case let .text(text) = payload { return text }
                return nil
            }
            .joined(separator: "\n")
    }

    /// Text report: per executed step a one-line header then the payload
    /// verbatim; after a failure, a summary line naming the failed step and how
    /// many steps never ran.
    public static func renderText(_ run: BatchRun) -> String {
        var lines: [String] = []
        for record in run.records {
            lines.append("## step \(record.step)/\(run.total): \(record.tool)")
            if !record.payload.isEmpty { lines.append(record.payload) }
        }
        if let failed = run.failedStep {
            lines.append("## stopped: step \(failed) failed; \(run.notRunCount) step(s) not run")
        }
        return lines.joined(separator: "\n")
    }

    /// JSON report: a single array with one object per EXECUTED step, hand-built
    /// (project pattern) so field order is byte-stable: step, tool, ok, payload.
    /// Not-run steps have no entry; the stop is visible as the trailing
    /// `"ok":false` entry plus the batch's exit 1.
    public static func renderJSON(_ run: BatchRun) -> String {
        "[" + run.records.map { record in
            "{\"step\":\(record.step)"
                + ",\"tool\":\(JSONText.string(record.tool))"
                + ",\"ok\":\(record.ok)"
                + ",\"payload\":\(JSONText.string(record.payload))}"
        }.joined(separator: ",") + "]"
    }
}
