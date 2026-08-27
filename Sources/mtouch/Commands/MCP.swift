import ArgumentParser
import Foundation
import MCP
import MTouchKit

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as an MCP (Model Context Protocol) server."
    )

    @OptionGroup var runOptions: RunOptions

    mutating func run() throws {
        // Resolved ONCE here, so `--run-dir`/`--capture` apply to every tool call
        // the server goes on to serve exactly as they would to a single command.
        let environment = runOptions.environment()
        // Never returns: it starts the stdio server on the cooperative pool and
        // runs the main run loop so AX/screenshot work can hop to the main thread.
        MCPServer.serve(environment: environment)
    }
}

/// The `mtouch mcp` stdio server: it exposes the CLI's capabilities as MCP tools,
/// each a THIN mirror of the corresponding command returning the SAME payload via
/// `MCPToolDispatch`.
///
/// Concurrency bridge (see docs/references/mcp-swift-sdk.md): the SDK's
/// `Server`/`StdioTransport` are actors on the cooperative pool and never touch
/// the main thread, but AX reads and ScreenCaptureKit need the main thread + a
/// live run loop. So a non-async entry spawns the server on a `Task` and then runs
/// the main run loop on the main thread; every tool handler hops onto the main
/// thread (via `runOnMainThread`) for its pipeline work, which the run loop then
/// services.
enum MCPServer {
    /// Single source of truth, shared with the run bundle's `run.json`: two
    /// hand-synced copies WILL drift the first time one is bumped alone.
    static let version = MTouchVersion.current

    /// Tracks whether the client has completed the `initialize` handshake, so a
    /// `tools/call` that arrives BEFORE it is rejected with a JSON-RPC error (no
    /// tool side effect) rather than executed.
    ///
    /// The SDK's own strict mode is unusable here: it throws the pre-init rejection
    /// from a code path the receive loop swallows with `try?`, so the client gets
    /// NO response (a silent drop) instead of the JSON-RPC error the contract
    /// requires. Gating in the handler — which the SDK DOES convert to a JSON-RPC
    /// error response — keeps the pre-init call observable and side-effect-free.
    final class InitializationState: @unchecked Sendable {
        private let lock = NSLock()
        private var initialized = false

        var isInitialized: Bool {
            lock.lock(); defer { lock.unlock() }
            return initialized
        }

        func markInitialized() {
            lock.lock(); initialized = true; lock.unlock()
        }
    }

    static func serve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
        // The transport keeps its default no-op logger so NOTHING is ever written
        // to stdout except JSON-RPC frames (stdout purity).
        let server = Server(
            name: "mtouch",
            version: version,
            capabilities: .init(tools: .init(listChanged: false))
        )
        let initState = InitializationState()

        Task {
            do {
                await register(on: server, initState: initState, environment: environment)
                try await server.start(transport: StdioTransport()) { _, _ in
                    // Fires when the client sends `initialize`: from here on, tool
                    // calls are accepted.
                    initState.markInitialized()
                }
                await server.waitUntilCompleted()
            } catch {
                logStderr("mtouch: mcp server error: \(error)")
                exit(MTouchExitCode.runtimeFailure.rawValue)
            }
            // stdin EOF (or stop) completed the message loop: exit cleanly.
            exit(MTouchExitCode.success.rawValue)
        }

        // Keep the process (and its main run loop) alive for AX/screenshot work.
        // `run(until:)` in a loop is robust even if no explicit run-loop sources are
        // attached: it still services the run-loop blocks the tool handlers post (see
        // `runOnMainThread`) and wakes periodically. The process ends via `exit(0)`
        // above on EOF.
        while true {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        }
    }

    // MARK: - Handler registration

    private static func register(
        on server: Server, initState: InitializationState, environment: [String: String]
    ) async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPToolCatalog.tools.map(makeTool))
        }

        await server.withMethodHandler(CallTool.self) { params in
            // A tool call before the initialize handshake is a JSON-RPC protocol
            // error, NOT an isError result — and it must have NO tool side effect,
            // so this gate precedes any dispatch. Throwing here yields a JSON-RPC
            // error the client observes; the server stays alive for a later
            // initialize.
            guard initState.isInitialized else {
                throw MCPError.invalidRequest("Server is not initialized")
            }
            let arguments = ToolArguments(convert(params.arguments ?? [:]))
            // `dispatchRecorded` wraps `dispatch` with trajectory recording when
            // MTOUCH_TRAJECTORY is set (a no-op otherwise), so an MCP session
            // records each tool call under the SAME shape as the CLI.
            let dispatch: @Sendable () -> ToolResult = {
                MCPToolDispatch.dispatchRecorded(
                    tool: params.name,
                    arguments: arguments,
                    environment: environment
                )
            }
            // Thread routing (see MCPToolDispatch.requiresMainThread):
            //  - Main-thread tools (AX reads/act + screenshot) hop via
            //    `runOnMainThread`. AX reads and ScreenCaptureKit need the main
            //    thread; the heavy tree walks still run on their own background
            //    queues (BoundedWalk/GuardedWalk), so the main thread only
            //    orchestrates. We hop via a raw run-loop block rather than
            //    `MainActor.run`: the screenshot path pumps the run loop itself
            //    (CFRunLoopRunInMode) to drive an inner main-actor capture task,
            //    and that nested pump only drains from a PLAIN main-thread context.
            //    Holding the Swift main actor would park that inner task so the
            //    capture never completes (times out).
            //  - `wait` runs OFF the main thread, directly on this handler's
            //    cooperative-pool task. It only SLEEPS its timeout budget between
            //    polls (its AX walk already runs off-main via GuardedWalk), so
            //    hopping to main would park the shared main run loop for the whole
            //    timeout and stall every concurrent tool call behind it
            //    (head-of-line blocking). Running it here leaves the main run loop
            //    free to service concurrent snapshot/screenshot calls.
            let result: ToolResult
            if MCPToolDispatch.requiresMainThread(tool: params.name) {
                result = await runOnMainThread(dispatch)
            } else {
                result = dispatch()
            }
            return CallTool.Result(content: result.payloads.map(makeContent), isError: result.isError)
        }
    }

    // MARK: - Catalog → SDK types

    /// Build an SDK `Tool` from a catalog spec, hand-writing the JSON-Schema
    /// `Value` (the SDK offers no schema DSL).
    private static func makeTool(_ spec: MCPToolCatalog.Spec) -> Tool {
        Tool(name: spec.name, description: spec.description, inputSchema: inputSchema(for: spec))
    }

    private static func inputSchema(for spec: MCPToolCatalog.Spec) -> Value {
        var properties: [String: Value] = [:]
        for property in spec.properties {
            var field: [String: Value] = [
                "type": .string(property.type),
                "description": .string(property.description),
            ]
            if let enumValues = property.enumValues {
                field["enum"] = .array(enumValues.map { .string($0) })
            }
            properties[property.name] = .object(field)
        }
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !spec.required.isEmpty {
            schema["required"] = .array(spec.required.map { .string($0) })
        }
        return .object(schema)
    }

    private static func makeContent(_ payload: ToolPayload) -> Tool.Content {
        switch payload {
        case let .text(text):
            return .text(text: text, annotations: nil, _meta: nil)
        case let .image(base64, mimeType):
            return .image(data: base64, mimeType: mimeType, annotations: nil, _meta: nil)
        }
    }

    /// Narrow the SDK's `Value` arguments to the primitives `ToolArguments` accepts.
    private static func convert(_ arguments: [String: Value]) -> [String: ToolArgumentValue] {
        arguments.mapValues { value in
            switch value {
            case let .string(string): return .string(string)
            case let .bool(bool): return .bool(bool)
            case let .int(int): return .int(int)
            case let .double(double): return .double(double)
            case .null, .array, .object, .data: return .other
            }
        }
    }

    /// Run `work` on the main thread and await its result, scheduling it as a
    /// RUN-LOOP block (not a `DispatchQueue.main.async` block and not
    /// `MainActor.run`).
    ///
    /// This distinction is load-bearing for the screenshot tool. `LiveScreenCapture`
    /// drives an async, main-actor capture by pumping `CFRunLoopRunInMode` until it
    /// completes. That nested pump can only drain the inner capture task when the
    /// main DISPATCH queue is free. If `work` ran as a main-queue block (via
    /// `MainActor.run` or `DispatchQueue.main.async`), libdispatch's reentrancy guard
    /// treats the queue as occupied and the nested pump never advances the capture
    /// (it times out). A `CFRunLoopPerformBlock` block runs from the run-loop context
    /// — exactly like the CLI's base call stack — leaving the main queue free for the
    /// pump. The outer `RunLoop.main.run(until:)` services this block.
    private static func runOnMainThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let runLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                continuation.resume(returning: work())
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
