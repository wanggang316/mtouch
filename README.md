# mtouch

[![CI](https://github.com/wanggang316/mtouch/actions/workflows/ci.yml/badge.svg)](https://github.com/wanggang316/mtouch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

`mtouch` is a native Swift, **agent-facing macOS automation tool** built for stable automated testing. It lets an AI agent (or any script) perceive and drive arbitrary third-party macOS apps through the Accessibility API, with a compact text/JSON contract designed for LLM token budgets — and it leaves behind an audit trail a human can check.

The agent-facing contract is **AX-tree-as-text + snapshot-scoped refs + post-action AX diff as verification**, with explicit wait primitives (no sleeps), a ScreenCaptureKit vision fallback, and a run evidence bundle (structured log, per-step stills, screen recording, HTML report).

## Design stance

Three rules explain most of what follows.

1. **A wrong answer is worse than a refusal.** An ambiguous bundle id is refused with the candidate pids, not guessed. A ref whose element moved is rejected (exit 3, "Nothing was acted on"), not re-pointed at a neighbour. An accessibility read that fails is an error, never rendered as an empty result.
2. **An action must return evidence — and grade it.** Every `act` returns an AX diff. Where the evidence is weaker than usual the output says so, both on stdout and as a machine-readable field: `verified:false` (no diff taken, you asked for `--no-verify`), `deliveryConfirmed:false` (posted but delivery unconfirmed), `settled:false` (the UI was still changing when the settle budget expired). A *wrong* diff is worse than no diff, so mtouch reports its own uncertainty instead of guessing.
3. **No `sleep`, anywhere.** Every synchronization point is an explicit, bounded wait on an observable condition.

## Highlights

- **Perception** — walk an app's accessibility tree into compact, ref-annotated text (`e1`, `e2`, …) or stable JSON; noise-filtered, menu-collapsed, cycle-safe, Electron-aware, with secure-field values masked. Elements are labelled by title, value, **accessibility description, or identifier**, so controls that carry no title are still addressable.
- **Reading** — `read` returns an element's **untruncated** text: by ref, by criteria (`--of`), or the whole app, for content the snapshot's node budget would drop.
- **Action** — `press` / `focus` / `show-menu` / `set-value` by ref **or by criteria** (`--of 'button "Seven"'` — a scripted flow needs no snapshot and no refs, and an ambiguous match is refused, never guessed), `menu "File>Save"` by menu-bar path, plus `click` / `rightclick` / `doubleclick` / `drag` / `scroll` by coordinate and `type` / `key` via CGEvent. Every action returns an **AX diff** as built-in verification.
- **App control** — `app launch` / `activate` / `quit` with polled readiness and **verified** activation, plus `clipboard get` / `set` / `clear` with a read-back check.
- **Synchronization** — `wait --appears/--disappears/--text/--value-equals`, and `--stable` **quiescence**: wait until a streaming or animating region stops changing.
- **Vision fallback** — `screenshot` via ScreenCaptureKit (full screen or per-window by `CGWindowID`), for AX-opaque apps.
- **Evidence** — `MTOUCH_RUN_DIR` collects `run.json`, a JSONL trajectory, per-step stills and a screen recording; `mtouch report` renders them into one offline, deterministic HTML page.
- **Throughput** — `mtouch batch` executes many MCP-shaped tool-call steps in ONE process (a typo anywhere refuses the whole batch before step 1; the first failing step stops it). Measured: an 8-press flow drops from ~1.65s across 8 processes to ~1.17s, and 10 agent round-trips become 1.
- **Failure honesty** — a DEAD target is diagnosed as dead (exit 1, "relaunch it"), never as a stale element (exit 3, "re-snapshot") or a burned timeout; `wait` fails fast when its target dies mid-poll.
- **Agent surface** — an **MCP (Model Context Protocol) stdio server** (`mtouch mcp`) exposing every capability with payloads byte-identical to the CLI. Zero network endpoints.

### Why `--stable` exists

Measured against a streaming answer in a real application:

| wait | returned after | captured |
|---|---|---|
| `--text <first fragment>` | 0.71 s | 212 chars |
| `--stable --stable-for 1s` | 15.21 s | 4197 chars |

**Both exit 0.** Without quiescence an agent silently proceeds on 5% of the answer — the failure mode that makes UI automation untrustworthy.

## Requirements

- macOS 14+ (Sonoma or later); **screen recording to video requires macOS 15+**
- Swift 6 / Xcode 16+
- **Accessibility** permission granted to the invoking terminal app (required); **Screen Recording** for `screenshot` and `record`

## Install

```sh
VER=v0.2.1
curl -fsSL -O "https://github.com/wanggang316/mtouch/releases/download/${VER}/mtouch-${VER}-macos-arm64.tar.gz"
tar xzf "mtouch-${VER}-macos-arm64.tar.gz"
./mtouch-${VER}-macos-arm64/mtouch doctor
```

Prebuilt binaries target Apple Silicon (arm64); on Intel, build from source. Grant the invoking terminal **Accessibility** in System Settings → Privacy & Security first (`mtouch doctor` reports status).

## Quick start

```sh
mtouch doctor                                   # 1. check permissions
mtouch app launch --app com.apple.calculator --wait-ready 15s

mtouch snapshot --app com.apple.calculator      # 2. perceive (refs come from here)
#   AXButton "7"@desc #e5   AXButton "乘"@desc #e8   AXButton "等于"@desc #e20

mtouch act press e5                             # 3. act — each action returns a diff
mtouch read --of 'scrollarea "编辑字段"'          # 4. read the result back
```

`@desc` / `@id` mark a label that came from the accessibility description or identifier rather than a title.

## Working with an evidence bundle

```sh
RUN=~/runs/my-task
mtouch record start --run-dir "$RUN" --max-duration 600s
MTOUCH_RUN_DIR=$RUN MTOUCH_RUN_CAPTURE=1 MTOUCH_RUN_LABEL="my task" \
  mtouch act press e5
mtouch record stop --run-dir "$RUN"
mtouch report "$RUN"          # -> $RUN/report.html, opens offline
```

While a recording is live, mtouch takes **no** second screen capture — step stills are extracted from the movie at each step's timestamp, so they provably come from the same recording. A standalone `screenshot` during a recording is refused rather than silently invalidating it.

> **The bundle contains whatever was on screen.** Screenshots and recordings capture everything visible, and the trajectory strips payload keys (`text`, `combo`, `value`) only on FAILED records — a successful `act type <secret>` is in the log verbatim. Use `mtouch report --redact` for a log-only bundle.

## Environment variables

| Variable | Effect |
|---|---|
| `MTOUCH_SESSION` | Path to the ref session file (isolates concurrent agents) |
| `MTOUCH_TRAJECTORY` | JSONL trajectory path; explicitly set, it wins over the run bundle's default |
| `MTOUCH_RUN_DIR` | Collect a run evidence bundle here (also `--run-dir`) |
| `MTOUCH_RUN_CAPTURE` | `1` enables per-step stills (also `--capture`) |
| `MTOUCH_RUN_LABEL` | Human label recorded in `run.json` |

## Exit codes

`0` ok · `1` runtime failure (includes an ambiguous bundle id and a refused AX read) · `2` permission missing · `3` ref error (stale/unknown/no-session) · `4` wait timeout · `5` secure input active · `64` usage error. Check precedence: `64 → 2 → 3 → 1`.

## Targeting an application

`--app <bundleId>` is required. When **several processes share one bundle id** (a second browser profile, a helper instance), mtouch refuses and lists the candidate pids rather than binding to one; pass `--pid <pid>` to choose. A pid that contradicts `--app` is a usage error.

## Build & test

```sh
swift build
swift test                    # hermetic unit tests (no AX/TCC/network/display)
make release                  # arm64 release binary
make package VERSION=v0.2.1   # -> mtouch-v0.2.0-macos-arm64.tar.gz (+ .sha256)
make ungranted                # ungranted-persona live probes
```

Continuous integration (GitHub Actions, `macos-15`) runs the unit suite and — because a fresh runner is an *ungranted* host — live-verifies the ungranted fail-fast behaviour that a granted developer machine cannot reproduce. Tests requiring a media decoder are skipped visibly on CI (the runner is headless) and run on developer machines.

## Architecture

- **`MTouchKit`** (library) — all logic, ArgumentParser-free and unit-testable through injectable seams (tree provider, event poster, pasteboard, workspace, capture, recorder).
- **`mtouch`** (executable) — a thin CLI plus the MCP server.

See [`docs/architecture.md`](docs/architecture.md) for the structural map.

## License

[MIT](LICENSE) © 2026 Gump.
