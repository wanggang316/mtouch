# MCP Swift SDK — integration notes

> Researched 2026-08-06 against `modelcontextprotocol/swift-sdk` 0.12.1 (2026-05-07,
> implements the 2025-11-25 MCP spec). Pre-1.0: minor versions may break API — **pin the version**.

## Requirements

- Swift 6.0+ (Xcode 16+), minimum platform macOS 13.0+ — compatible with our macOS 14 target.
- Package product is `MCP`:
  `.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")`
  (pinned exact in `Package.swift`; resolved revision `a0ae212`).

## Server shape (verified against source)

```swift
import MCP

let server = Server(
    name: "mtouch", version: "…",
    capabilities: .init(tools: .init(listChanged: true))
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [
        Tool(name: "…", description: "…",
             inputSchema: .object(["properties": .object([…])]))  // hand-written JSON Schema via `Value`
    ])
}

await server.withMethodHandler(CallTool.self) { params in
    // manual switch on params.name; args via params.arguments?["k"]?.stringValue
    .init(content: [.text("…")], isError: false)
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()   // returns on stdin EOF / stop()
```

Key types: `Tool.inputSchema: Value` (`.null/.bool/.int/.double/.string/.array/.object`);
`CallTool.Result` has `content: [Tool.Content]`, `structuredContent: Value?`, `isError: Bool?`;
`Tool.Content` supports `.text`, `.image(data: base64String, mimeType:)`, `.resource`, `.resourceLink`.

## Concurrency model (load-bearing for AX/CGEvent integration)

- `Server` and `StdioTransport` are **actors** on the cooperative pool; stdio reads are
  non-blocking (`O_NONBLOCK` + 10 ms sleep polling). **No run-loop dependency, never touches
  the main thread.**
- Recommended process structure: non-async `main` spawns
  `Task { try await server.start(…); await server.waitUntilCompleted(); exit(0) }`,
  then the main thread runs `RunLoop.main.run()` for AXObserver / CGEvent taps.
  Handlers hop to `MainActor` when an AX call needs the main thread.

## Gotchas

- **Never log to stdout** in the stdio server — it corrupts the JSON-RPC stream. Use stderr
  (`StreamLogHandler.standardError`) or a file.
- Images must be base64-encoded strings (no `Data` convenience).
- No tool-registration DSL: schemas are hand-written `Value` dictionaries; `CallTool` dispatch
  is a manual switch. Acceptable at our tool count (~8).
- **Strict mode silently drops pre-initialize requests** (verified 0.12.1): `Server` strict
  configuration throws the pre-init rejection from a receive-loop path swallowed by `try?`, so the
  client gets NO response at all (a silent drop), not the JSON-RPC error the spec expects. Use
  non-strict mode and gate initialization yourself in the `CallTool` handler — throw
  `MCPError.invalidRequest`, which the SDK DOES convert into a JSON-RPC error response — so a pre-init
  call stays observable and side-effect-free. Track `initialize` via the `server.start` completion
  hook.
- **Main-thread hop for run-loop-pumping APIs**: when a handler must drive an async main-actor API
  that pumps `CFRunLoopRunInMode` itself (our ScreenCaptureKit capture), hop via
  `CFRunLoopPerformBlock` on the main run loop — NOT `MainActor.run` / `DispatchQueue.main.async`. The
  latter mark the main dispatch queue occupied (libdispatch reentrancy), so the nested pump never
  drains and the capture times out. Run `RunLoop.main.run(until:)` on the main thread to service the
  posted block; it runs from the run-loop context exactly like a plain CLI's base call stack.
- Open issues cluster on the HTTP/OAuth side; the stdio path is comparatively stable.
- Alternative if DX ever matters: `Cocoanetics/SwiftMCP` (`@MCPServer`/`@MCPTool` macros) —
  personal project, better ergonomics, weaker spec tracking. Not chosen.
