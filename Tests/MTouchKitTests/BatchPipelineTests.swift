import Foundation
import Testing
@testable import MTouchKit

// MARK: - Spy dispatcher & helpers

/// Records every dispatched step and answers from a script of results, so
/// sequencing and stop-on-failure are asserted without any live AX. Steps beyond
/// the script succeed with a marker payload.
private final class SpyDispatcher {
    private(set) var calls: [BatchStep] = []
    private let results: [ToolResult]

    init(results: [ToolResult] = []) {
        self.results = results
    }

    func dispatch(_ step: BatchStep) -> ToolResult {
        calls.append(step)
        guard calls.count <= results.count else { return .text("ok \(calls.count)") }
        return results[calls.count - 1]
    }
}

private func runBatch(
    _ input: String, results: [ToolResult] = []
) -> (outcome: BatchPipeline.Outcome, spy: SpyDispatcher) {
    let spy = SpyDispatcher(results: results)
    let outcome = BatchPipeline.run(input: input) { spy.dispatch($0) }
    return (outcome, spy)
}

private func invalidDiagnostic(_ outcome: BatchPipeline.Outcome) -> String? {
    if case let .invalid(diagnostic) = outcome { return diagnostic }
    return nil
}

private func executedRun(_ outcome: BatchPipeline.Outcome) -> BatchRun? {
    if case let .executed(run) = outcome { return run }
    return nil
}

/// A fresh, unique temp directory removed at the end of the closure. Tests write
/// ONLY here — never the real home or a shared /tmp trajectory.
private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-batch-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

// MARK: - Upfront validation

/// The whole input is validated BEFORE anything executes: a bad line rejects the
/// batch at exit 64 with zero steps dispatched — a typo must not leave a
/// half-executed flow.
@Suite struct BatchValidationTests {
    @Test func malformedLineNamesItsLineNumberAndExecutesNothing() throws {
        let input = """
        {"tool":"apps"}
        {"tool":"doctor"
        {"tool":"apps"}
        """
        let (outcome, spy) = runBatch(input)
        let diagnostic = try #require(invalidDiagnostic(outcome))
        #expect(diagnostic.contains("line 2"))
        #expect(diagnostic.contains("not valid JSON"))
        // Even though line 1 is valid, NOTHING ran.
        #expect(spy.calls.isEmpty)
    }

    @Test func unknownToolFailsTheWholeBatchBeforeStepOne() throws {
        let input = """
        {"tool":"apps"}
        {"tool":"frobnicate"}
        """
        let (outcome, spy) = runBatch(input)
        let diagnostic = try #require(invalidDiagnostic(outcome))
        #expect(diagnostic.contains("line 2"))
        #expect(diagnostic.contains("unknown tool 'frobnicate'"))
        // The refusal lists the valid vocabulary, mirroring the MCP surface.
        #expect(diagnostic.contains("Available tools: "))
        #expect(spy.calls.isEmpty)
    }

    @Test func nonObjectArgumentsValueIsRejected() throws {
        for arguments in ["[1,2]", "5", "\"press\"", "null"] {
            let (outcome, spy) = runBatch("{\"tool\":\"apps\",\"arguments\":\(arguments)}")
            let diagnostic = try #require(invalidDiagnostic(outcome))
            #expect(diagnostic.contains("line 1"))
            #expect(diagnostic.contains("'arguments' must be a JSON object"))
            #expect(spy.calls.isEmpty)
        }
    }

    @Test func missingOrNonStringToolIsRejected() throws {
        let missing = try #require(invalidDiagnostic(runBatch("{\"arguments\":{}}").outcome))
        #expect(missing.contains("line 1"))
        #expect(missing.contains("missing 'tool'"))

        let nonString = try #require(invalidDiagnostic(runBatch("{\"tool\":7}").outcome))
        #expect(nonString.contains("'tool' must be a string"))
    }

    @Test func nonObjectLineIsRejected() throws {
        let diagnostic = try #require(invalidDiagnostic(runBatch("42").outcome))
        #expect(diagnostic.contains("line 1"))
        #expect(diagnostic.contains("not a JSON object"))
    }

    /// A key that is not 'tool'/'arguments' is most likely a misspelling of one
    /// of them; accepting it would surface the mistake only MID-RUN.
    @Test func unknownStepKeyIsRejected() throws {
        let diagnostic = try #require(
            invalidDiagnostic(runBatch("{\"tool\":\"apps\",\"argument\":{}}").outcome)
        )
        #expect(diagnostic.contains("line 1"))
        #expect(diagnostic.contains("unknown key 'argument'"))
    }

    @Test func emptyInputIsAUsageErrorNotANoOp() throws {
        for input in ["", "\n", "  \n\t\n"] {
            let (outcome, spy) = runBatch(input)
            let diagnostic = try #require(invalidDiagnostic(outcome))
            #expect(diagnostic.contains("no steps"))
            #expect(spy.calls.isEmpty)
        }
    }

    /// Blank lines are skipped but still COUNTED, so a diagnostic's line number
    /// matches the file the user is looking at.
    @Test func lineNumbersArePhysicalAcrossBlankLines() throws {
        let input = "{\"tool\":\"apps\"}\n\nnot-json\n"
        let diagnostic = try #require(invalidDiagnostic(runBatch(input).outcome))
        #expect(diagnostic.contains("line 3"))
    }
}

// MARK: - Sequencing

@Suite struct BatchSequencingTests {
    @Test func stepsRunSequentiallyInInputOrder() throws {
        let input = """
        {"tool":"doctor"}
        {"tool":"apps","arguments":{"json":true}}
        {"tool":"wait","arguments":{"app":"com.example.a","timeout":"5s"}}
        """
        let (outcome, spy) = runBatch(input)
        let run = try #require(executedRun(outcome))
        #expect(spy.calls.map(\.tool) == ["doctor", "apps", "wait"])
        #expect(run.total == 3)
        #expect(run.records.count == 3)
        #expect(run.succeeded)
        #expect(run.failedStep == nil)
        #expect(run.notRunCount == 0)
    }

    @Test func failureStopsTheBatchAndSkipsTheRest() throws {
        let input = """
        {"tool":"apps"}
        {"tool":"snapshot","arguments":{"app":"com.example.a"}}
        {"tool":"apps"}
        """
        let (outcome, spy) = runBatch(input, results: [
            .text("first"),
            .text("mtouch: it failed", isError: true),
            .text("never dispatched"),
        ])
        let run = try #require(executedRun(outcome))
        // Step 3 was NOT dispatched — stop means stop, not skip-and-continue.
        #expect(spy.calls.count == 2)
        #expect(run.records.count == 2)
        #expect(run.failedStep == 2)
        #expect(run.notRunCount == 1)
        #expect(!run.succeeded)
        #expect(run.records[1].ok == false)
        #expect(run.records[1].payload == "mtouch: it failed")
    }

    /// Argument values keep their natural JSON type on the way to the dispatcher
    /// — the same narrowing the MCP entry applies — so a step's payload means the
    /// same thing on every surface.
    @Test func argumentValuesKeepTheirNaturalJSONTypes() throws {
        let input = "{\"tool\":\"act\",\"arguments\":"
            + "{\"verb\":\"press\",\"pid\":42,\"noVerify\":true,\"scale\":1.5,\"bad\":[1],\"nul\":null}}"
        let (_, spy) = runBatch(input)
        let arguments = try #require(spy.calls.first?.arguments)
        #expect(arguments.string("verb") == "press")
        #expect(arguments.rawValues["pid"] == .int(42))
        #expect(arguments.rawValues["noVerify"] == .bool(true))
        #expect(arguments.rawValues["scale"] == .double(1.5))
        // Non-primitive values narrow to .other, exactly as over MCP.
        #expect(arguments.rawValues["bad"] == .other)
        #expect(arguments.rawValues["nul"] == .other)
    }

    /// A step with no "arguments" key dispatches with an EMPTY argument set, not
    /// a refusal — the tool itself decides whether its arguments are required.
    @Test func omittedArgumentsDispatchAsEmpty() throws {
        let (outcome, spy) = runBatch("{\"tool\":\"doctor\"}")
        #expect(executedRun(outcome) != nil)
        let arguments = try #require(spy.calls.first?.arguments)
        #expect(arguments.rawValues.isEmpty)
    }
}

// MARK: - Rendering

@Suite struct BatchRenderingTests {
    @Test func textModePrintsAHeaderThenThePayloadVerbatim() {
        let run = BatchRun(total: 2, records: [
            BatchStepRecord(step: 1, tool: "apps", ok: true, payload: "line one\nline two"),
            BatchStepRecord(step: 2, tool: "doctor", ok: true, payload: "report"),
        ])
        #expect(BatchPipeline.renderText(run) == """
        ## step 1/2: apps
        line one
        line two
        ## step 2/2: doctor
        report
        """)
    }

    @Test func textModeReportsTheStopAfterAFailedStep() {
        let run = BatchRun(total: 4, records: [
            BatchStepRecord(step: 1, tool: "apps", ok: true, payload: "fine"),
            BatchStepRecord(step: 2, tool: "act", ok: false, payload: "mtouch: no such element"),
        ])
        #expect(BatchPipeline.renderText(run) == """
        ## step 1/4: apps
        fine
        ## step 2/4: act
        mtouch: no such element
        ## stopped: step 2 failed; 2 step(s) not run
        """)
    }

    @Test func jsonModeIsOneArrayWithDeterministicFieldOrder() {
        let run = BatchRun(total: 3, records: [
            BatchStepRecord(step: 1, tool: "apps", ok: true, payload: "a"),
            BatchStepRecord(step: 2, tool: "act", ok: false, payload: "mtouch: nope"),
        ])
        // Byte-stable, hand-built shape (project convention): step, tool, ok,
        // payload — executed steps only.
        #expect(BatchPipeline.renderJSON(run) ==
            "[{\"step\":1,\"tool\":\"apps\",\"ok\":true,\"payload\":\"a\"},"
            + "{\"step\":2,\"tool\":\"act\",\"ok\":false,\"payload\":\"mtouch: nope\"}]")
    }

    @Test func jsonPayloadsAreEscaped() {
        let run = BatchRun(total: 1, records: [
            BatchStepRecord(step: 1, tool: "read", ok: true, payload: "a \"b\"\nc"),
        ])
        #expect(BatchPipeline.renderJSON(run)
            == "[{\"step\":1,\"tool\":\"read\",\"ok\":true,\"payload\":\"a \\\"b\\\"\\nc\"}]")
    }
}

// MARK: - Trajectory parity

/// Each batch step routes through the SAME recorded dispatch as the MCP surface,
/// so every executed step writes its own trajectory record — and a batch that
/// stops early keeps the records of the steps that DID run.
@Suite struct BatchTrajectoryTests {
    private struct StubPermissions: PermissionProvider {
        var accessibilityGranted = true
        var screenRecordingGranted = true
    }

    @Test func eachExecutedStepWritesItsOwnRecordEvenWhenTheBatchFails() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let environment = [
                "MTOUCH_TRAJECTORY": trajectory,
                "MTOUCH_SESSION": dir.appendingPathComponent("s.json").path,
            ]
            // doctor succeeds hermetically; snapshot WITHOUT 'app' is refused by
            // dispatch (isError) before any AX access — also hermetic.
            let input = """
            {"tool":"doctor"}
            {"tool":"snapshot"}
            {"tool":"doctor"}
            """
            let outcome = BatchPipeline.run(input: input) { step in
                MCPToolDispatch.dispatchRecorded(
                    tool: step.tool, arguments: step.arguments,
                    environment: environment, permissions: StubPermissions()
                )
            }
            let run = try #require(executedRun(outcome))
            #expect(run.failedStep == 2)
            #expect(run.notRunCount == 1)

            // One record per EXECUTED step, in order; the failed step's record
            // is there and marked not-ok; the never-run step left no record.
            let content = try String(contentsOf: URL(fileURLWithPath: trajectory), encoding: .utf8)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            let records = try lines.map { line in
                try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
            #expect(records.count == 2)
            #expect(records.map { $0["command"] as? String } == ["doctor", "snapshot"])
            let outcomes = records.map { $0["outcome"] as? [String: Any] }
            #expect(outcomes[0]?["ok"] as? Bool == true)
            #expect(outcomes[1]?["ok"] as? Bool == false)
        }
    }
}

// MARK: - Surface pin

@Suite struct BatchSurfaceTests {
    /// Batch is CLI-only BY DESIGN: an MCP client already holds one live process
    /// and makes sequential tools/call requests, and the advertised tool set is
    /// pinned at exactly ten. Batch must never appear in the catalog.
    @Test func batchIsNotAnMCPTool() {
        #expect(!MCPToolCatalog.toolNames.contains("batch"))
        #expect(MCPToolCatalog.tools.count == 10)
    }
}
