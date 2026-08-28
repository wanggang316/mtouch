import ArgumentParser
import Foundation
import MTouchKit

struct Batch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Execute a list of tool-call steps in one process, in order.",
        discussion: """
        Reads steps as JSON Lines from stdin (or --file): one object per line, \
        {"tool":"<name>","arguments":{...}} — exactly the shapes the MCP \
        tools/call surface accepts, with the same ten tools (snapshot, act, wait, \
        screenshot, apps, windows, doctor, app, clipboard, read) and the same \
        argument names. Every capability of those tools works in a batch \
        unchanged: criteria targeting ('of'), quiescence waits ('stable'), pid \
        targeting, unverified delivery ('noVerify').

        The WHOLE input is validated before step 1 runs: a malformed line, an \
        unknown tool, or a non-object 'arguments' value fails the batch at exit \
        64 naming the offending line, and nothing executes — a typo must not \
        leave a half-executed flow. Zero steps is the same usage error.

        Steps run sequentially, in order, in this one process, and the batch \
        STOPS at the first step whose result is an error; the remaining steps \
        are reported as not run. To pause between steps, add a wait step — \
        waiting is a step, not a flag.

        Output per step: a '## step N/<total>: <tool>' header, then the step's \
        payload exactly as the tool prints it; a failed step shows its \
        diagnostic. With --json the batch emits one array \
        [{"step":1,"tool":...,"ok":...,"payload":...}, ...] instead, one entry \
        per executed step.

        Evidence behavior is per step and unchanged: MTOUCH_TRAJECTORY records, \
        MTOUCH_RUN_DIR step numbering, and capture markers all apply to each \
        step exactly as if it were invoked separately; --run-dir/--capture apply \
        to every step of the batch.

        Batch is CLI-only by design: an MCP client already holds one live \
        process and makes sequential tools/call requests, so a batch tool would \
        be redundant there.

        Exit codes: 0 every step succeeded; 1 a step failed (the per-step \
        exit-code taxonomy is preserved in the trajectory records — one process \
        can only return one code); 64 the input failed validation.
        """
    )

    @Option(help: ArgumentHelp(
        "Read the steps from this file instead of stdin.", valueName: "path"
    ))
    var file: String?

    @Flag(help: "Emit the per-step results as a single machine-readable JSON array.")
    var json = false

    @OptionGroup var runOptions: RunOptions

    mutating func validate() throws {
        if let file, file.isEmpty {
            throw ValidationError("--file value must not be empty; pass a path to a JSON Lines file.")
        }
    }

    mutating func run() throws {
        let input = try readInput()
        // Resolved ONCE here, so --run-dir/--capture apply to every step exactly
        // as they would to a single command (mirrors the MCP entry).
        let environment = runOptions.environment()

        // Sequential, on the MAIN thread — AX reads and capture are main-bound,
        // and this is the same thread the one-shot commands run on. Each step
        // routes through the SAME recorded dispatch as the MCP surface, so its
        // trajectory record, run-bundle step, and payload are identical to a
        // separate invocation.
        let outcome = BatchPipeline.run(input: input) { step in
            MCPToolDispatch.dispatchRecorded(
                tool: step.tool, arguments: step.arguments, environment: environment
            )
        }

        switch outcome {
        case let .invalid(diagnostic):
            // Validation failed: NOTHING executed. Usage error, like any other
            // malformed invocation.
            FileHandle.standardError.write(Data((diagnostic + "\n").utf8))
            throw ExitCode(MTouchExitCode.usageError.rawValue)
        case let .executed(batchRun):
            print(json ? BatchPipeline.renderJSON(batchRun) : BatchPipeline.renderText(batchRun))
            if !batchRun.succeeded {
                throw ExitCode(MTouchExitCode.runtimeFailure.rawValue)
            }
        }
    }

    /// The raw script text, from --file or stdin. An unreadable or non-UTF-8
    /// input is a usage error (64): the batch never started, nothing executed.
    private func readInput() throws -> String {
        let data: Data
        if let file {
            guard let contents = FileManager.default.contents(atPath: file) else {
                FileHandle.standardError.write(Data("mtouch: batch: cannot read steps file: \(file)\n".utf8))
                throw ExitCode(MTouchExitCode.usageError.rawValue)
            }
            data = contents
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }
        guard let text = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("mtouch: batch: the steps input is not valid UTF-8.\n".utf8))
            throw ExitCode(MTouchExitCode.usageError.rawValue)
        }
        return text
    }
}
