# mtouch

[![CI](https://github.com/wanggang316/mtouch/actions/workflows/ci.yml/badge.svg)](https://github.com/wanggang316/mtouch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

**Let an AI agent operate a Mac — and leave behind evidence of what it did.**

mtouch is a native Swift CLI that drives arbitrary macOS applications through the
Accessibility API, with a token-efficient contract designed for LLM budgets. It is
built for automated testing, where a tool that quietly does the wrong thing is
worse than no tool at all.

```sh
brew install wanggang316/tap/mtouch
mtouch init --client claude
```

## What it looks like

```sh
mtouch app launch --app com.apple.calculator --wait-ready 15s

mtouch snapshot --app com.apple.calculator
#   AXButton "7"@desc #e5   AXButton "乘"@desc #e8   AXButton "等于"@desc #e20

mtouch act press e5                     # every action returns an AX diff
mtouch read --of 'scrollarea "编辑字段"'  # read the result back
```

Or skip snapshots entirely — address elements by what they *are*, and let the
action wait for them:

```sh
mtouch act press --of 'button "Save"' --wait 5s --app <bundle-id>
```

## Why you might want it

**Actions verify themselves.** Every `act` returns an accessibility diff showing
what changed. When that evidence is weaker than usual, the output says so rather
than pretending — `verified: false`, `deliveryConfirmed: false`, `settled: false`.
A *wrong* diff is worse than no diff.

**It refuses instead of guessing.** An ambiguous bundle id lists the candidate
pids. A ref whose element moved is rejected rather than re-pointed at its
neighbour. A failed accessibility read is an error, never an empty result. Each of
those was once a silent wrong answer here, and each now has a regression test.

**No `sleep`, anywhere.** Waiting is an explicit, bounded condition — including
the one people forget: waiting for content to *stop changing*.

| wait | returned after | captured |
|---|---|---|
| `--text <first fragment>` | 0.71 s | 212 chars |
| `--stable --stable-for 1s` | 15.21 s | 4197 chars |

Both exit 0. Without quiescence an agent proceeds on 5% of a streamed answer with
nothing to warn it.

**It works on applications with no accessibility tree.** Menu paths
(`act menu "File>Save"`) drive editors whose document views expose nothing, and
ScreenCaptureKit covers the rest.

**Runs are auditable.** Point `MTOUCH_RUN_DIR` at a folder and get a structured
log, per-step stills, a screen recording, and a single offline HTML report.

## Requirements

- macOS 14+ (Sonoma). Screen **recording to video** requires macOS 15+.
- Apple Silicon for the prebuilt binary; Intel users build from source.
- **Accessibility** permission for the invoking terminal application, and
  **Screen Recording** for `screenshot` / `record`. Run `mtouch doctor` to check.

macOS attaches these grants to the terminal you run mtouch *from*, not to mtouch
itself — which surprises nearly everyone the first time.

## Install

```sh
brew install wanggang316/tap/mtouch
mtouch init --client claude    # register the MCP server + install agent instructions
```

`mtouch init` with no arguments lists what it would do and changes nothing;
`--print` dry-runs it. Running it twice is safe: an existing registration is left
alone, and a *differing* one is reported rather than silently overwritten.

<details>
<summary>Without Homebrew</summary>

```sh
VER=v0.2.2
curl -fsSL -O "https://github.com/wanggang316/mtouch/releases/download/${VER}/mtouch-${VER}-macos-arm64.tar.gz"
tar xzf "mtouch-${VER}-macos-arm64.tar.gz"
./mtouch-${VER}-macos-arm64/mtouch doctor
```

Or from source: `swift build` → `.build/debug/mtouch`.
</details>

## Command surface

| | |
|---|---|
| **Perceive** | `snapshot` · `read` · `windows` · `apps` |
| **Act** | `act press/focus/show-menu/set-value` (by ref or `--of` criteria) · `act menu` · `act click/drag/scroll/type/key` |
| **Wait** | `wait --appears/--disappears/--text/--value-equals/--stable` |
| **Control** | `app launch/activate/quit` · `clipboard get/set/clear` |
| **Vision** | `screenshot` · `record start/stop/status` |
| **Evidence** | `report` |
| **Agent** | `mcp` (10 tools, byte-identical payloads) · `batch` · `init` |
| **Health** | `doctor` |

`mtouch <command> --help` documents each one.

## Evidence bundles

```sh
RUN=~/runs/my-task
mtouch record start --run-dir "$RUN" --max-duration 600s
MTOUCH_RUN_DIR=$RUN MTOUCH_RUN_CAPTURE=1 mtouch act press --of 'button "Save"' --app <id>
mtouch record stop --run-dir "$RUN"
mtouch report "$RUN"          # → report.html, opens offline
```

While a recording is live, step stills are extracted from the movie rather than
captured separately — so they provably come from the same recording, and the
recording is never invalidated to get them.

> **A bundle contains whatever was on screen.** The trajectory strips payload keys
> (`text`, `combo`, `value`) only on *failed* records, so a successful
> `act type <secret>` is in the log verbatim. Use `mtouch report --redact` before
> sharing one.

## Exit codes

`0` ok · `1` runtime · `2` permission missing · `3` ref error · `4` wait timeout ·
`5` secure input active · `64` usage error. Precedence: `64 → 2 → 3 → 1`.

Two are recoverable without human help: **3** (re-snapshot and retry) and **4**
(wait longer, or for a different condition). A dead target is its own diagnosis —
exit 1 telling you to relaunch, never a misleading exit 3.

## Documentation

| | |
|---|---|
| [docs/agent-guide.md](docs/agent-guide.md) | Driving a computer with mtouch — the practical guide |
| [docs/architecture.md](docs/architecture.md) | How it is built and why |
| [docs/platform-notes.md](docs/platform-notes.md) | macOS behaviours learned the hard way |
| [docs/golden-rules.md](docs/golden-rules.md) | What this project refuses to do |
| [CHANGELOG.md](CHANGELOG.md) | Release history |

## Build & test

```sh
swift build
swift test                    # hermetic unit tests: no AX, TCC, network, or display
./ci/smoke.sh                 # end-to-end smoke of the built binary
make release                  # arm64 release binary
make package VERSION=v0.2.2   # release tarball + .sha256
```

CI runs three jobs on every push: the unit suite, a CLI smoke of the shipped
binary, and an **ungranted-persona live verification** — because a fresh runner is
an ungranted host, and that is the one thing a granted developer machine cannot
reproduce.

## License

[MIT](LICENSE) © 2026 Gump.
