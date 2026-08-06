# mtouch — Architecture

> The structural map of mtouch, an agent-facing macOS UI automation tool for automated testing.
> Code is the source of truth; this records durable structure and conventions, updated at milestone
> boundaries. Written at the M1-perception seal (2026-08-06).

## What mtouch is

A native Swift CLI + (M3) MCP stdio server that lets AI agents perceive and drive arbitrary
third-party macOS apps. Perception and element actions go through the Accessibility API
(`AXUIElement`), input synthesis through `CGEvent`, screenshots through ScreenCaptureKit. The
agent-facing contract is **AX-tree-as-text + snapshot-scoped refs + post-action AX diff as
verification**, with explicit wait primitives (no sleeps) and trajectory recording.

## Package layout (SwiftPM, macOS 14+, Swift 6)

- **`MTouchKit`** (library) — all logic; **ArgumentParser-free** so it is unit-testable and reusable.
- **`mtouch`** (executable) — thin CLI over `MTouchKit` using swift-argument-parser; the only place
  CLI concerns (parsing, exit codes as `ExitCode`) live.
- **`MTouchKitTests`** — hermetic unit tests over fake providers; no AX/TCC/network dependency.

## Core data structure

`AXNode` (value type) is the load-bearing model the whole tool builds on: role, subrole, title,
value, frame (screen points, top-left origin), enabled, **actionable** (derived from an actionable
role set OR an `AXPress` action, independent of enabled), isScrollArea, scrollPosition, children.
The diff engine (M2), wait evaluator (M2), and act layer (M2) all consume `AXNode`.

## Seams & patterns (established M1)

- **`AXTreeProvider` seam** — `LiveTreeProvider` (real `AXUIElementCreateApplication` + `AXSupport`
  helpers) vs. a fake provider for tests, so the walker and all rendering are testable with zero AX.
- **Perception pipeline** (`SnapshotPipeline`): preflight → resolve bundle id→pid → bounded walk →
  scroll-position enrichment → render (text/JSON) → persist session. Thin composition; heavy lifting
  in named MTouchKit pieces.
- **Menu collapse** (`MenuDescent`): closed submenus (nil/zero-size `AXMenu` frame) are NOT expanded;
  the owner menu-bar/menu item stays actionable. Perception matches the action model — items appear
  only after `act show-menu` opens the menu (frame becomes non-zero → walked).
- **Bounded walk** (`BoundedWalk`): an 8s wall-clock deadline turns a hung/SIGSTOPped target into an
  explicit exit-1 timeout, never an indefinite hang. NOTE: it abandons (not cancels) the walk thread;
  M2 `wait` (polling) and M3 `mcp` (long-running) must make it cancellable to avoid thread leaks.
- **Secret-safety** (`SnapshotSecure`): secure-text-field values are masked at a single chokepoint on
  every surface (text, JSON) and the persisted ref table (`RefEntry`) carries no value at all; the
  session digest hashes already-masked JSON. A planted secret cannot reach any output or the state file.
- **Session store** (`SessionStore`): current snapshot (ref table + digest) persisted to
  `~/.mtouch/session.json` (or `$MTOUCH_SESSION`), atomic temp+rename write; corrupt→absent;
  `RefResolution` = resolved/stale/unknown/noSession → CLI exit 0/3/64/3.

## Interfaces (pinned; authority = plan.md "Interface semantics")

- Exit codes: 0 ok · 1 runtime · 2 permission · 3 ref · 4 wait-timeout · 5 secure-input · 64 usage;
  precedence 64 → 2 → 3 → 1.
- Every read subcommand supports `--json`; snapshot `--json` is `{ "nodes": [...] }` (object, not a
  bare array); frames in points; `scrollPosition` as normalized 0..1 `{x,y}`.
- Sessions/recording isolate via `$MTOUCH_SESSION` / `$MTOUCH_TRAJECTORY`; CLI↔MCP share one session file.

## TCC / environment

Accessibility is the only *required* permission (doctor exits 2 iff missing); Screen Recording is
optional (only `screenshot` needs it). Grants attach to the **invoking terminal app**, not the binary
— so an ungranted persona is unrealizable from a granted terminal without TCC mutation (forbidden);
such assertions are verified at the unit level or deferred to an ungranted CI runner. No headless mode.

## Milestones

- **M1-perception** (sealed 2026-08-06): scaffold, doctor/TCC preflight, app/window enumeration, AX
  walker + Electron fallback, textualization/refs/noise/secure-mask, session store, snapshot CLI,
  menu-collapse. 17/20 assertions PASS live/unit; 3 (ungranted-persona) deferred.
- **M2-action-loop** (next): CGEvent synthesis, post-action diff, act element/typing/coordinate
  commands, wait primitives.
- **M3-agent-surface**: ScreenCaptureKit screenshots, MCP stdio server, trajectory recording.
