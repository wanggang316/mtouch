# mtouch

`mtouch` is a native Swift, agent-facing macOS UI automation CLI. It exposes perception (`doctor`, `apps`, `windows`, `snapshot`, `screenshot`), action (`act` with press/focus/show-menu/set-value/click/rightclick/doubleclick/drag/scroll/type/key verbs), synchronization (`wait`), and an MCP server mode (`mcp`). The full CLI grammar is declared and parses today; subcommand bodies are stubs that exit 1 until their features land. Shared types (exit-code taxonomy, coordinate and duration parsing) live in the `MTouchKit` library.

## Build & Test

```sh
swift build
swift test
swift run mtouch --help
```
