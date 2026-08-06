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
  explicit exit-1 timeout, never an indefinite hang. It abandons (not cancels) the walk thread, so
  M2 `wait` polls through `GuardedWalk` — a single-flight cap that keeps at most ONE walk in flight on
  a hung target (never one leaked thread per poll); M3 `mcp` (long-running) reuses the same guard.
- **Secret-safety** (`SnapshotSecure`): secure-text-field values are masked at a single chokepoint on
  every surface (text, JSON) and the persisted ref table (`RefEntry`) carries no value at all; the
  session digest hashes already-masked JSON. A planted secret cannot reach any output or the state file.
- **Session store** (`SessionStore`): current snapshot (ref table + digest) persisted to
  `~/.mtouch/session.json` (or `$MTOUCH_SESSION`), atomic temp+rename write; corrupt→absent;
  `RefResolution` = resolved/stale/unknown/noSession → CLI exit 0/3/64/3.

## Seams & patterns (established M2-action-loop)

- **Input synthesis chokepoint** (`InputSynthesizer` over `Activator` / `SecureInputState` /
  `EventPoster`): the single place every keyboard/mouse `CGEvent` is built and posted. Keyboard verbs
  refuse when secure input is active BEFORE activating or posting (zero events, payload-free diagnostic
  → exit 5); the target app is always activated before any event. `KeyCombo(parsing:)` is the only
  key-name interpreter (unknown names → usage error 64).
- **Unified act pipeline** (`ActPipeline`): ref, keyboard, and coordinate verbs share one back half —
  resolve target → (ref only: re-locate by hint, never a positional impostor) → act → bounded
  early-stopping settle re-walk → `DiffEngine` diff → persist the reconciled session. Precedence
  64 → 2 → 3 → 1 is encoded by order in an AX-free front half; a rejected case delivers zero events.
  Coordinate verbs add an off-screen guard (`ScreenBounds` / `CGDisplayBounds`) validated before any
  event is posted.
- **Post-action diff** (`DiffEngine`): identity = role + structural PATH; title/value/enabled/frame
  are changeable attributes; matched nodes keep their ref, added actionable nodes get fresh continuing
  refs, removed refs go stale; digest reuses the single `Session.digest` scheme. KNOWN LIMITATION:
  positional identity does not re-pair a node that shifted to a new path — a root insert/remove (e.g. a
  window close while the menu bar is a sibling root) reads as remove+re-add of the shifted subtrees
  rather than a minimal removal. A role+title cross-path fallback is the pending fix.
- **Guarded poll** (`WaitPoll` + `GuardedWalk`): `wait` observes only (never delivers input), checks
  before sleeping (already-true returns fast), fails only at ≥ timeout, does exactly one check at
  `--timeout 0`, and never leaks threads on a hung target.

## Seams & patterns (established M3-agent-surface)

- **Screenshot pipeline** (`ScreenshotPipeline` over `LiveScreenCapture`): preflight Screen Recording
  (exit 2, no file) → resolve target/path → capture (SCK) → all-black backstop → PNG encode → atomic
  temp+rename write. Every collaborator is injectable, so the flow is unit-testable with zero SCK/TCC.
  Pixel dims are `filter.contentRect` (points) × `filter.pointPixelScale`, so `pixels == points × scale`
  holds by construction; `--window` addresses the SAME `CGWindowID` space `mtouch windows` prints.
  Black-capture safety is two-layered — the SR preflight is the primary guard,
  `ScreenCaptureImage.isEffectivelyBlank` the backstop — and neither ever writes a file.
  `LiveScreenCapture` runs the async per-window SCK capture on a main-actor task and PUMPS the run loop
  (`CFRunLoopRunInMode`) rather than blocking (the per-window path needs the main-thread window-server
  connection; a blocked main thread trips `CGS_REQUIRE_INIT`), guarded by a 15 s deadline so the
  one-shot CLI can never hang.
- **MCP dispatch seam** (`MCPToolCatalog` + `MCPToolDispatch`, both SDK-free in MTouchKit): the single
  source of truth for the seven tools and the one place a tool name + arguments map onto the existing
  pipelines (Snapshot/Act/Wait/Screenshot, enumeration, DoctorReport) — never re-implementing their
  logic — returning a `ToolResult` (payloads + isError). Payload parity holds because dispatch returns
  the pipelines' outcome strings verbatim. Domain failures (unknown tool, missing/invalid arg, wait
  timeout, stale ref, missing permission) are `isError` results; protocol problems (unknown method,
  malformed frame, pre-initialize call) are JSON-RPC errors. The executable
  (`Sources/mtouch/Commands/MCP.swift`) keeps stdout pure (only JSON-RPC frames; transport logger left
  no-op), gates pre-init calls in the handler (the SDK's strict mode silently drops them), and hops
  tool work to the main thread via a `CFRunLoopPerformBlock` run-loop block — NOT `MainActor.run` /
  `DispatchQueue.main.async`, which would deadlock the screenshot capture's nested run-loop pump. The
  long-running server reuses `GuardedWalk`, so it never leaks walk threads.
- **Trajectory recorder** (`TrajectoryRecorder` + `TrajectoryRecord`): a cross-cutting OBSERVER both
  surfaces route through — the CLI via `Support.swift recorded(…)`, MCP via
  `MCPToolDispatch.dispatchRecorded(…)` — feeding one record model so a command and its tool shape
  identically (same field names). Recording NEVER alters observable behavior: with `MTOUCH_TRAJECTORY`
  unset it is a pure pass-through; when set it appends exactly one atomic `O_APPEND` `write(2)` of the
  full `<json>\n` line, so a crash leaves every completed line parseable and concurrent writers never
  interleave. Per-class shapes: snapshot carries the tree digest; a mutating act carries pre/post
  `Session.digest` + the diff; reads carry no digests; screenshot references the written PNG path,
  never image bytes. The digest chain links by construction (each act reads the prior act's persisted
  digest). A directory/unwritable path aborts (exit 1) BEFORE running the operation — never a silent
  unrecorded run — and a secure-input-refused `type`/`key` records the event but strips its
  `text`/`combo` payload so a secret never persists.

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
- **M2-action-loop** (sealed 2026-08-06): CGEvent synthesis, post-action diff, act element/typing/
  coordinate commands, wait primitives.
- **M3-agent-surface** (implemented; validation in progress): ScreenCaptureKit screenshots, the MCP
  stdio server (seven tools), and trajectory recording — the agent surface. 364 tests passing.
