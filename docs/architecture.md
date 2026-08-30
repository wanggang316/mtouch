# Architecture

## What mtouch is

A native Swift CLI that lets an AI agent perceive and drive arbitrary macOS
applications. The contract is deliberately narrow: an accessibility tree rendered
as compact text with scoped refs, actions addressed by ref or by criteria, and an
AX diff returned as the action's own verification. Everything else — screenshots,
recordings, run bundles — exists to cover cases the AX tree cannot, or to make a
run auditable afterwards.

## Package layout

SwiftPM, macOS 14+ (screen recording to video needs 15+), Swift 6 strict
concurrency.

| Target | Role |
|---|---|
| `MTouchKit` (library) | All logic. ArgumentParser-free, every environment touchpoint behind an injectable seam. |
| `mtouch` (executable) | A thin CLI over the library, plus the MCP stdio server. |
| `MTouchKitTests` | Hermetic unit tests — no AX, TCC, network, display, or media decoding. |

The split exists so the environment is never required to test logic. If something
is hard to test, the seam is in the wrong place.

## The load-bearing value type

`AXNode` — role, subrole, title, value, description, identifier, frame, enabled,
actionable, children. Everything upstream produces it and everything downstream
consumes it: the walker builds it, the textualizer and JSON renderer format it,
the diff engine compares it, criteria match against it, and refs are issued for
the actionable ones.

## The three pipelines

Each user-facing capability is a pipeline: a pure composition over injected seams,
with the CLI and MCP surfaces as two thin callers. That is why CLI and MCP
payloads are byte-identical — they are the same function.

```
                 ┌──────────────┐
   perceive ───► │ Snapshot /   │  walk → filter noise → collapse menus →
                 │ Read         │  cut cycles → label → assign refs → render
                 └──────────────┘
                 ┌──────────────┐
   act      ───► │ Act          │  resolve target (ref | criteria [| wait]) →
                 │              │  activate → deliver → flush → settle → diff
                 └──────────────┘
                 ┌──────────────┐
   verify   ───► │ Wait         │  bounded poll over an injected clock:
                 │              │  appears / disappears / text / value / stable
                 └──────────────┘
```

Supporting pipelines follow the same shape: `Windows`, `AppLifecycle`,
`Clipboard`, `Screenshot`, `Record`, `Report`, `Batch`, `Init`.

## Perception

**Walking.** `AXTreeWalker` reads an application element's children over the AX
IPC boundary. Three guards make it safe against hostile trees: a per-read
messaging timeout, a whole-walk deadline (`BoundedWalk`) so a hung target cannot
wedge the CLI, and cycle detection (`AXCycleGuard`) because applications do expose
themselves as their own children. A depth cap remains as a backstop only.

**Filtering.** `SnapshotNoise` drops elements that carry neither actionable
content nor text, memoized bottom-up so the pass is O(n). Menus collapse unless
open — a closed menu's items are not reachable by an agent, so advertising them
would be a lie the action layer cannot honour.

**Labelling.** `AXLabel` picks the first available of title → value → description
→ identifier, marking non-title sources `@desc` / `@id`. Without this, controls
that carry no title are indistinguishable and unaddressable.

**Refs.** Actionable elements get `e1`, `e2`, … scoped to the snapshot that issued
them and persisted in a session file. Ref identity is role + subrole + title +
description + identifier, pinned to the owning `CGWindowID`. Every component was
added because omitting it caused a silent misdelivery: the window id stopped a
ref matching an identically-titled window in another window; the label stopped a
sibling shift re-pointing refs at their neighbours.

**Reading.** The text form has a node budget and drops non-actionable nodes past
it. `read` exists because that budget genuinely bites (1053 nodes dropped on a
real chat transcript, 227 text blocks unreachable) — it never truncates and can
address by ref, by criteria, or whole-app.

## Action

**Targeting.** A ref, or a criteria (`--of`, the same grammar `wait` uses),
optionally with `--wait` to poll until the criteria resolves. Criteria resolution
happens against the action's own pre-walk, so a scripted flow needs no snapshot
and has no ref that can go stale. Ambiguity is refused with candidates listed —
acting on many matches is misdelivery, whereas *reading* many is safe, so
`read --of` returns them all.

**Delivery.** Two channels with different properties: AX actions
(`AXPress`, set-value) reach an element directly and need no frontmost; CGEvent
synthesis (`type`, `key`, coordinates) goes through the HID layer and does. The
event poster is a seam; `InputDeliveryFlush` waits on an observable event counter
because `CGEvent.post` is asynchronous and returning too early delivers nothing.

**Verification.** The post-action walk produces a diff via `DiffEngine`, which
matches elements positionally with a role+label cross-path fallback so a root
insert (a window opening) reads as a minimal change rather than a cascade.
`DiffSettle` waits for a diff that *repeats* rather than the first non-empty one —
a still-rendering UI otherwise yields a partial or unrelated diff, which is worse
than none.

**Grading.** Where evidence is weaker than usual the outcome says so:
`verified` (a diff was taken), `deliveryConfirmed` (delivery was observed), and
`settled` (the reading was stable). Each is a distinct `ActOutcome` case, so no
consumer can silently treat it as ordinary success.

**Menu paths.** `act menu "File>Save"` walks the menu bar by title with
exact → case-insensitive matching, and always closes menus it opened on any
failure path. This is the reliable route into applications whose document views
expose nothing.

## Synchronization

`WaitPoll` is a pure bounded loop over an injected clock and sleep — there is no
`sleep` anywhere in the product. Conditions: `appears`, `disappears`, `text`,
`value-equals`, and `stable` (quiescence: any change resets the quiet window).
Quiescence is shared with the act pipeline's settle step, so "settled" means one
thing in the codebase rather than two.

Failure paths consult `ProcessLiveness` before reporting a timeout, because "the
application died" and "the element is not there yet" demand opposite responses
from an agent.

## Vision fallback

`screenshot` captures via ScreenCaptureKit, full screen or a single window by
`CGWindowID` — the same id space `windows` reports, which is what lets an agent
correlate the two. This path works on applications with no usable AX tree at all,
and needs the Screen Recording grant.

## Evidence

`MTOUCH_RUN_DIR` turns a sequence of invocations into an auditable bundle:
`run.json`, a JSONL trajectory (one record per command), per-step stills, and a
screen recording. The step counter is allocated under the same advisory lock that
guards the trajectory append, so concurrent processes cannot collide.

`record` runs a `setsid`-detached recorder with a control file; `stop` verifies
the artifact and requires the recorder's countersignature, because capture flushes
playable fragments and a killed recorder leaves a movie that passes every check.
During a recording no second capture session is opened — one invalidates the other
— so step stills are extracted from the movie at each step's timestamp, which also
makes them provably contemporaneous.

`report` renders the bundle into one offline, deterministic HTML page.

## Agent surfaces

| Surface | Shape |
|---|---|
| CLI | 15 subcommands, exit-code taxonomy, `--json` on read commands |
| MCP stdio (`mtouch mcp`) | 10 tools, payloads byte-identical to the CLI, zero network endpoints |
| `batch` | JSONL of MCP-shaped tool calls executed in one process |
| `init` | Registers the MCP server with an agent client and installs usage doctrine |

`batch` reuses the MCP dispatch verbatim, which is why every capability worked in
a batch the day it shipped. The MCP server hops tool handlers onto the main thread
because AX reads and capture require it, while the SDK is actor-based.

## Interfaces (pinned)

- **Exit codes:** `0` ok · `1` runtime · `2` permission · `3` ref · `4` wait
  timeout · `5` secure input · `64` usage. Precedence `64 → 2 → 3 → 1`.
- **Output discipline:** stdout is empty or valid payload, never a hybrid;
  diagnostics go to stderr; `--json` shapes are hand-built for fixed key order.
- **Isolation:** `MTOUCH_SESSION` / `MTOUCH_TRAJECTORY` / `MTOUCH_RUN_DIR`. CLI
  and MCP share one session file by design.

The authoritative specification is
`.harness-runtime/plans/mtouch/validation-contract.md`. Changing observable
behaviour means amending it.

## Permissions

Accessibility is the only *required* grant; Screen Recording is needed for
`screenshot` and `record`. Grants attach to the **invoking terminal application**,
not to the binary — so an ungranted persona cannot be realized from a granted
terminal without mutating TCC, which is forbidden. Those assertions are verified
by a dedicated CI job on a fresh runner instead.

## Testing strategy

| Layer | Where |
|---|---|
| Logic | Hermetic unit tests through seams — the whole suite, no environment |
| Wiring | `ci/smoke.sh` against the shipped binary: subcommand surface, exit-code taxonomy, MCP handshake, rendered report |
| Environment-only behaviour | Live scenarios against real applications, plus the ungranted-persona CI job |

Unit tests cannot find the defects that matter most here. Every significant bug in
this project's history was found by running a real task against a real
application; the unit suite's job is to keep them fixed.
