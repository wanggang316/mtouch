# User-Test Patterns

> Project-wide conventions for runtime user-level validation. Written at the first run of
> `/harness-stack:fdd-validation-contract` (Step 0: Bootstrap). Read this before writing or
> probing any plan's validation contract; contract assertions live in
> `.harness-runtime/plans/<slug>/validation-contract.md`.

## Status

**Status:** Approved
**Last updated:** 2026-08-06

## Platforms in Scope

- **macOS CLI (`mtouch`)** — the product itself; a SwiftPM executable invoked from a terminal in a logged-in GUI session.
- **MCP stdio server (`mtouch mcp`)** — the agent-facing surface; JSON-RPC 2.0 over stdin/stdout.
- **Swift unit tests (`swift test`)** — pure-logic verification (textualization, diff, refs, wait-condition evaluation) against fake tree fixtures; no AX or TCC dependency.

Not in scope: Web, iOS, Android, HTTP APIs. mtouch has no network surface.

## Tooling per Platform

### macOS CLI

- **Primary:** direct invocation of the built binary: `swift run mtouch <subcommand> ...` (or `.build/debug/mtouch ...` after `swift build`)
- **Fallback:** none needed — the CLI is the surface
- **Invocation:** run from a terminal that HAS the Accessibility TCC grant (see Personas); E2E probes drive **TextEdit (`com.apple.TextEdit`) only**
- **Ready signal:** `mtouch doctor` exits 0 and reports Accessibility as granted; for app-driving probes, launch TextEdit with a fresh untitled document and wait via `mtouch wait` for its text area to appear (never `sleep`). Interim rule for M1-scope probes (before `wait` exists): a bounded snapshot-retry loop (≤ 10 attempts, explicit 500 ms delay between attempts) is the only sanctioned polling
- **Isolation env:** probes set `MTOUCH_SESSION=<per-case path>` so concurrent cases never share snapshot state, and `MTOUCH_TRAJECTORY=<per-case path>` when recording is under test
- **Sanctioned exceptions:** (a) the default-session case (VAL-SNAP-015) runs serialized with `MTOUCH_SESSION` unset — back up `~/.mtouch/session.json` to the scratchpad first and restore it after; (b) probes may re-activate the invoking terminal to establish the "terminal frontmost" precondition — that is not "driving another app"; (c) mixed-grant cases (Accessibility yes / Screen Recording no — VAL-ENV-004, VAL-MCP-014) must be scheduled BEFORE Screen Recording is ever granted to the validating terminal, because the grant cannot be shed without forbidden TCC mutation
- **Cost tier:** medium

### MCP stdio server

- **Primary:** pipe JSON-RPC frames into `swift run mtouch mcp` (initialize → tools/list → tools/call), assert on the JSON responses
- **Fallback:** an MCP client harness script checked into `tests/` if raw piping proves brittle
- **Ready signal:** `initialize` response returns the server name/version
- **Cost tier:** expensive

### Swift unit tests

- **Primary:** `swift test` (optionally `swift test --filter <TestName>` for one case)
- **Ready signal:** none needed — hermetic
- **Cost tier:** cheap

## Case Dimensions

| Dimension | Mandatory? | What to check |
|---|---|---|
| Happy path | Mandatory | primary success flow of the subcommand/tool |
| Error path | Mandatory | at least one declared failure mode (missing permission, unknown bundle id, stale ref, timeout) |
| Edge values | Mandatory | empty tree, zero matches, unicode text, boundary timeouts |
| Permission variants | Mandatory | behaviour with vs. without the required TCC grant |
| Accessibility | N/A | mtouch consumes the AX API; it has no GUI of its own |
| Performance budget | Optional | snapshot of a typical window < ~2s when a plan NFR cites it |
| Security | Mandatory for typing/recording cases | secure-input detection; no typed-secret leakage into trajectories |
| i18n | Optional | unicode typing (CJK) where text input is exercised |

## Selector and Assertion Rules

### Allowed selectors

- Snapshot-text queries: role + visible title/value as printed by `mtouch snapshot` (e.g. a line containing `button "Save"`)
- Refs (`e1`, `e2`, …) **taken from the current snapshot output within the same probe** and passed to the next command
- CLI exit codes and stderr diagnostics (exact expected code, substring of the documented error message)
- Structured output fields (JSON keys in `--json` output; JSON-RPC response fields on MCP)
- Filesystem observables: existence/content of an artifact file the command claims to write (PNG, trajectory JSONL)
- Observable app state via a fresh snapshot (e.g. TextEdit's text area value after typing)

### Forbidden selectors

- Ref numbers cached from an earlier snapshot or a previous probe — refs are snapshot-scoped by contract
- Hardcoded screen coordinates, except when the probe derives them from a fresh snapshot's geometry or a fresh screenshot in the same probe
- Swift type/function names, file paths inside `Sources/` — implementation detail
- Exact full-tree dumps of system apps as golden files — OS updates restyle system UI; assert on stable anchor elements (TextEdit's text area, window title), never on the whole tree
- Pixel-exact screenshot comparison — assert on file existence, dimensions, and format instead

### Allowed assertions

- Binary: PASS or FAIL; no "looks good"
- Specific: expected exit code / substring / JSON value named in the assertion
- Independent: one probe per assertion; probes may share a TextEdit session only when read-only (see tiers)

## State Isolation

- **Per-case app state:** every TextEdit-driving case launches a fresh untitled document (`open -na TextEdit` or `mtouch`-driven `⌘N`) and closes it without saving at the end — the probe kills only processes it launched
- **No cross-case state:** no case depends on another having run; order must not matter
- **Filesystem:** artifacts and trajectories go under `tests/runs/<timestamp>/<case-id>/`; probes never write outside the repo and the scratchpad
- **TCC state:** never modified programmatically; the two permission personas (below) are realized by which invoking context runs the probe — permission-denied cases run the binary from a context WITHOUT the grant (fresh binary path not yet granted, or `tccutil reset Accessibility <bundle>` is FORBIDDEN — instead use a copy of the binary at an ungranted path only if macOS treats it as ungranted; otherwise mark the case blocked and record why)
- **External services:** none exist; probes must not touch the network

## Surface Cost Tiers

| Tier | Cost | Isolation strategy | Surfaces (this project) |
|---|---|---|---|
| **cheap** | sub-second, hermetic | one case per verification step | `swift test`; `mtouch` parse/help/exit-code checks not needing AX |
| **medium** | shares a GUI session + TextEdit instance | group read-only cases on one fresh document; reset (new document) between mutating groups | CLI driving TextEdit (snapshot/act/wait) |
| **expensive** | process-lifecycle per case; extra TCC surface | batch at the end of a run; minimize sessions | MCP stdio session; screenshot cases (Screen Recording grant); trajectory-recording sessions |

Default when unsure: **medium**.

## Personas

- `agent_operator` — an AI agent's harness invoking `mtouch` from a terminal WITH the Accessibility grant (and Screen Recording where a case needs screenshots). Full CLI + MCP access.
- `unprivileged_operator` — the same invocation context WITHOUT the required TCC grant; used for permission-diagnostic and fail-fast assertions.
- `mcp_client` — an MCP client speaking JSON-RPC over stdio to `mtouch mcp`, running under the same grants as `agent_operator`.

## Fixtures and Test Data

**Naming:** `<scenario>.<format>` — e.g. `fake-tree-simple.json`, `fake-tree-electron-empty.json`, `typing-unicode.txt`.

**Rule:** fixtures are static data (serialized fake AX trees for unit tests, sample texts). They import no code and live in `Tests/MTouchKitTests/Fixtures/`.

## Artifacts

**Location:** `tests/runs/<timestamp>/<case-id>/`

**Each FAIL must produce:**

- `report.md` — the failed assertion + expected vs. observed
- `repro.sh` — a runnable script reproducing the probe in isolation (including TextEdit launch/cleanup)
- `output.txt` — full stdout/stderr of the failing invocation
- `snapshot.txt` — the last AX snapshot taken (app-driving cases)
- `shot.png` — the captured image (screenshot cases)

**Retention:** keep the last 10 runs; older runs are deleted manually or by CI.

## Anti-Patterns

### Sleep-based waiting in probes

**Looks like:** `sleep 2` between launching TextEdit and snapshotting.
**Why wrong:** the product's own contract bans sleeps; probes that sleep hide latency bugs and flake under load.
**Do instead:** use `mtouch wait --appears <criteria> --timeout 5s` — the wait primitive is itself under test.

### Golden-tree assertion on system apps

**Looks like:** diffing the full TextEdit snapshot against a stored dump.
**Why wrong:** OS updates and locale changes restyle system UI; the golden file rots.
**Do instead:** assert on stable anchors — the text area exists, its value equals what was typed.

### Stale-ref reuse across probes

**Looks like:** case B clicks `e7` obtained during case A's snapshot.
**Why wrong:** refs are snapshot-scoped by design; reuse tests nothing and flakes.
**Do instead:** every probe takes its own snapshot and resolves refs from it; stale-ref rejection has its own dedicated case.

### Tool-loop exhaustion

**Looks like:** retrying a flaky probe 50 times, then reporting timeout instead of a verdict.
**Why wrong:** the probe never produced a judgment.
**Do instead:** max 3 attempts with explicit waits between; if still unstable, record INCONCLUSIVE with the attempt log.

### Driving unowned applications

**Looks like:** a probe clicks around in Finder or the user's browser because TextEdit was busy.
**Why wrong:** violates the plan's infrastructure boundary; can destroy user state.
**Do instead:** TextEdit only; if TextEdit is unusable, FAIL the probe with diagnostics.

## Knowledge Persistence

**Who writes here:** the runtime validator, after a run, recording facts that outlive the run.
Author-time conventions (tooling, selectors, isolation) stay in the sections above; this section is for operational discoveries.

**Format:** one fact per line.

```
- [YYYY-MM-DD] <surface / step>: <fact discovered>. <what to do next time>.
```

- [2026-08-06] TextEdit readiness: snapshotting a TextEdit instance in its first ~1–2s after `open -na` (still restoring/creating windows) can hit mtouch's 8s bounded-timeout (exit 1, "appears unresponsive"). Gate readiness on `mtouch windows` returning a window (or a bounded snapshot-retry ≤10×/500ms), NOT an immediate snapshot; expect a possible one-off bounded-timeout if you snapshot mid-launch.
- [2026-08-06] Multi-instance TextEdit: `open -na TextEdit` spawns a NEW process each time; `mtouch --app com.apple.TextEdit` resolves to ONE of them nondeterministically. For SIGSTOP/timeout probes, ensure a single instance so the one you STOP is the resolve target. Clean the slate with `pkill -9 -x TextEdit` before a controlled run (only ever our own test instances).
- [2026-08-06] TCC grants attach to the INVOKING TERMINAL app, not the mtouch binary — a binary copy at a fresh path is still granted. The `unprivileged_operator` persona is therefore unrealizable from a granted terminal without forbidden TCC mutation; assertions requiring it are BLOCKED here and must be re-probed from a never-granted host app / CI runner. Ungranted code paths are covered by unit filters (declared evidence for VAL-ENV-006; DoctorReport covers all four grant combos).
- [2026-08-06] `mtouch screenshot` was "not implemented" until M3; for a no-dialog check pre-M3, the system `screencapture` stands in.
- [2026-08-06] **Frontmost contention (affects all keyboard/coordinate live probes):** this session's host process `com.gumpw.codans` aggressively re-grabs frontmost during bash command execution. mtouch DOES dislodge a merely-frontmost app (activation works — VAL-ACT-019 holds), but a target it activates can lose the race to an aggressively-foregrounding caller mid-command, degrading exact live captures of typed/clicked results. On a lost race mtouch writes NOTHING to the target (honest "(no changes)"), never a wrong-app write. For act-typing/act-coordinate live probes: prefer running from a normal non-contending terminal; where a live capture degrades, the behavior is covered by equivalent captures (e.g. a CJK type through the same cmd+a→type path) + `EventSynthesisTests`. Do not mark such an assertion FAIL solely due to this contention — retry from a quiescent foreground, else record the equivalent evidence.
- [2026-08-06] Do NOT use `osascript`/AppleScript to drive or quit TextEdit in probes — it triggers a per-host-app AppleScript-automation TCC consent prompt that blocks/hangs the run. Drive TextEdit via the Accessibility API (i.e. through `mtouch` itself); to dirty a document for the unsaved-changes-sheet test, use a real edit via the AX/keyboard path, not `osascript`. Menu-bar menus opened by one CLI process only stay open for the next process while TextEdit is frontmost (macOS menu-tracking) — this is what makes menu-ref staleness (VAL-ACT-018) demonstrable across processes.
