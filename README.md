# mtouch

[![CI](https://github.com/wanggang316/mtouch/actions/workflows/ci.yml/badge.svg)](https://github.com/wanggang316/mtouch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

`mtouch` is a native Swift, **agent-facing macOS UI automation tool** built for stable automated testing. It lets an AI agent (or any script) perceive and drive arbitrary third-party macOS apps through the Accessibility API, with a compact text/JSON contract designed for LLM token budgets.

The agent-facing contract is **AX-tree-as-text + snapshot-scoped refs + post-action AX diff as verification** — the pattern that proved most reliable in practice — with explicit wait primitives (no sleeps), a ScreenCaptureKit vision fallback, and trajectory recording as the foundation for deterministic replay.

## Highlights

- **Perception** — walk an app's accessibility tree into compact, ref-annotated text (`e1`, `e2`, …) or stable JSON; noise-filtered, menu-collapsed, Electron-aware (`AXManualAccessibility` fallback), with secure-field values masked.
- **Action** — `press` / `focus` / `show-menu` / `set-value` by ref, plus `click` / `rightclick` / `doubleclick` / `drag` / `scroll` by coordinate and `type` / `key` via CGEvent. Every action returns an **AX diff** (added/removed/changed) as built-in verification.
- **Synchronization** — `wait --appears/--disappears/--text/--value-equals` with a full duration grammar and a poll engine. **No `sleep` anywhere.**
- **Vision fallback** — `screenshot` via ScreenCaptureKit (full-screen or per-window by `CGWindowID`), for AX-opaque apps.
- **Agent surface** — an **MCP (Model Context Protocol) stdio server** (`mtouch mcp`) exposing every capability as a tool with payloads byte-identical to the CLI. Zero network endpoints.
- **Recording** — `MTOUCH_TRAJECTORY` appends a JSONL trajectory (command, args, pre/post digests, diff) for later deterministic replay.
- **Stable by design** — snapshot-scoped refs pinned to their owning window (`CGWindowID`), explicit stale-ref rejection, actionable permission diagnostics, bounded AX traversal that never hangs, and secure-input refusal.

## Requirements

- macOS 14+ (Sonoma or later), Apple Silicon or Intel
- Swift 6 / Xcode 16+
- **Accessibility** permission granted to the invoking terminal app (required); **Screen Recording** only for `screenshot`

## Install

Download the prebuilt (Apple Silicon) binary from the [latest release](https://github.com/wanggang316/mtouch/releases/latest):

```sh
VER=v0.1.0
curl -fsSL -O "https://github.com/wanggang316/mtouch/releases/download/${VER}/mtouch-${VER}-macos-arm64.tar.gz"
tar xzf "mtouch-${VER}-macos-arm64.tar.gz"
./mtouch-${VER}-macos-arm64/mtouch --help
```

Prebuilt binaries target Apple Silicon (arm64); on Intel, build from source (below). Grant the invoking terminal **Accessibility** in System Settings → Privacy & Security before driving apps (`mtouch doctor` reports status).

## Build & test

```sh
swift build
swift test              # hermetic unit tests (no AX/TCC/network)
swift run mtouch --help

make release            # arm64 (Apple Silicon) release binary
make package VERSION=v0.1.0   # -> mtouch-v0.1.0-macos-arm64.tar.gz (+ .sha256)
make ungranted          # run the ungranted-persona live probes
```

Continuous integration (GitHub Actions, `macos-15`) runs the unit suite and — because a fresh CI runner is an *ungranted* host — live-verifies the ungranted-persona fail-fast behavior (`ci/ungranted-probes.sh`) that a granted developer machine cannot reproduce. Tagging `v*` builds and publishes an arm64 binary as a GitHub Release.

## Quick start

```sh
# 1. Check permissions
swift run mtouch doctor

# 2. Perceive
open -na TextEdit
swift run mtouch wait --app com.apple.TextEdit --appears textarea --timeout 5s
swift run mtouch snapshot --app com.apple.TextEdit          # ref-annotated tree
swift run mtouch snapshot --app com.apple.TextEdit --json   # { "nodes": [ … ] }

# 3. Act (refs come from the latest snapshot; each action returns a diff)
swift run mtouch act focus e1
swift run mtouch act type "hello world"

# 4. Verify
swift run mtouch snapshot --app com.apple.TextEdit --json | jq '.. | .value? // empty'

# 5. Screenshot / MCP / recording
swift run mtouch screenshot --window <id> --out shot.png
swift run mtouch mcp                                        # stdio MCP server
MTOUCH_TRAJECTORY=/tmp/run.jsonl swift run mtouch act press e5
```

## Exit codes

`0` ok · `1` runtime failure · `2` permission missing · `3` ref error (stale/unknown/no-session) · `4` wait timeout · `5` secure input active · `64` usage error. Check precedence: `64 → 2 → 3 → 1`.

## Architecture

- **`MTouchKit`** (library) — all logic, ArgumentParser-free and unit-testable via a fake `AXTreeProvider` seam.
- **`mtouch`** (executable) — a thin CLI (+ the MCP server) over `MTouchKit`.

The load-bearing value type is `AXNode` (role/title/value/frame/enabled/actionable/…). See [`docs/architecture.md`](docs/architecture.md) for the full structural map and [`docs/references/mcp-swift-sdk.md`](docs/references/mcp-swift-sdk.md) for MCP integration notes.

## Status

v1 complete: perception, action, wait, screenshot, MCP server, and trajectory recording, built across three validated milestones (378 unit tests; security-audited). The ungranted-persona fail-fast behaviors that a granted developer machine can't reproduce are live-verified in CI (a fresh runner is an ungranted host); the minimized-window and split-grant cases remain unit-covered. Known non-blocking hardening items are tracked for follow-up.

## License

[MIT](LICENSE) © 2026 Gump.
