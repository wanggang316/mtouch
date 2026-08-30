# Changelog

All notable changes to mtouch are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Fixes are described by the *symptom* rather than the patch, because nearly every
defect in this project was silent — the failures below reported success. If you
ran an earlier version, that is what you need to know.

## [Unreleased]

### Known gaps

- `settled: false` has deterministic test coverage but has never been reproduced
  live; three attempts to force it failed (an animating scroll exposed no
  accessibility change, a concurrent writer was slower than the poll interval, a
  full-screen transition settled honestly).
- A one-shot command that fails inside the ~15–50 ms kernel teardown window after
  a target is `SIGKILL`ed still reports the older diagnostic; a polling command
  self-heals on its next tick.
- `mtouch init` collects every conflict before mutating anything, so a stale
  instructions file blocks an otherwise-fine registration until `--force`.
  Planned fix: stamp generated files with a version marker (ours → update freely
  and report the bump; not ours → ask).

## [0.2.2] — 2026-08-29

### Added

- **`mtouch init`** — one-command agent onboarding. Registers the MCP server with
  an agent client and installs a compact instruction file covering the usage
  doctrine. Discovery is inert, `--print` dry-runs the plan, a second run leaves
  an existing registration alone, and a *differing* one is reported rather than
  silently overwritten. Registers the absolute path of the running binary, because
  a Homebrew install and a source build are different binaries.
- **`act --of <criteria> --wait <duration>`** — the wait folds into the action, so
  a multi-screen flow needs no separate `wait` step. Expiry distinguishes *never
  appeared* (exit 4, naming what was seen) from *matched several* (exit 4, listing
  the candidates); a target that dies mid-wait fails fast at exit 1 (measured
  2.06 s of a 60 s wait), and a wedged-but-alive target is exit 1 because waiting
  cannot help it.
- **Homebrew distribution** — `brew install wanggang316/tap/mtouch`, with the
  tap's formula bumped automatically on each release. The workflow re-downloads
  the asset and verifies it against the release's published checksum, so a
  corrupted or tampered asset fails the job instead of landing in a formula.

### Fixed

- The CLI smoke job's subcommand roll-call had drifted behind `batch` and `init`.

## [0.2.1] — 2026-08-28

### Added

- **`act --of <criteria>`** — the ref verbs address elements by criteria (title,
  value, description, or identifier), resolved against the action's own pre-walk.
  A scripted flow needs no snapshot and has no ref that can go stale. An ambiguous
  match is refused with the candidates listed, since acting on many matches is
  misdelivery — whereas `read --of` returns them all, because reading many is safe.
- **`mtouch batch`** — many MCP-shaped tool-call steps in one process. The whole
  batch is validated before step 1 runs, so a typo on line 3 executes nothing; the
  first failing step stops it. An 8-press flow went from ~1.65 s across 8
  processes to ~1.17 s, and 10 agent round-trips became 1.

### Fixed

- **A dead target was diagnosed as a stale element, or as a timeout.** "The
  application crashed" and "that element went away" demand opposite responses, and
  the first could masquerade as the second. A `wait` whose target died 2 s into a
  15 s timeout burned the full 15.2 s and exited 4; it now fails fast at exit 1
  naming the pid and suggesting relaunch. Trajectory records carry an `app-gone`
  error class.

## [0.2.0] — 2026-08-28

The release that turned a perception-and-action tool into one that can operate a
computer end to end.

### Added

- **App lifecycle** — `app launch` / `activate` / `quit`, with polled readiness
  and *verified* activation.
- **Clipboard** — `clipboard get` / `set` / `clear`, with a read-back check on write.
- **Menu-path invocation** — `act menu "File>Save"`. Exact → case-insensitive →
  localized matching; a wrong path lists the available titles, and every failure
  path closes the menus it opened. This is the reliable route into applications
  whose document views expose no accessibility tree.
- **Quiescence waits** — `wait --stable`, waiting until content *stops changing*.
  Against a streamed answer, `--text <fragment>` returned in 0.71 s with 212
  characters while `--stable` returned in 15.21 s with 4197 — both at exit 0.
- **Untruncated reads** — `read` by ref, by criteria, or whole-app, for content the
  snapshot's node budget drops (measured: 1053 nodes dropped on a real transcript,
  227 text blocks otherwise unreachable).
- **Label-based addressing** — elements are labelled by title, value, accessibility
  description, or identifier, so controls carrying no title are addressable at last.
- **Unverified delivery** — `--no-verify` for modal panels that block an
  application's accessibility server. Explicit, marked in the output and the log,
  and refused on verbs that need the tree.
- **Run evidence bundles** — `MTOUCH_RUN_DIR` collects `run.json`, a JSONL
  trajectory, per-step stills, and a screen recording; `record start|stop|status`
  and `report` render it as one offline, deterministic HTML page.
- **Instance targeting** — `--pid`, for hosts running several processes under one
  bundle id.

### Fixed

Every item below was found by running a real task against a real application, and
every one of them previously reported success.

- **A wrong action, reported as success.** Ref identity was role + subrole + title
  only, so controls with no title were indistinguishable and a sibling shift
  silently re-pointed every ref at its neighbour: an intended `123 × 456` was
  entered as `13+456`, with all eight presses exiting 0. Element labels are now
  part of ref identity. (`Session` version 2 — the first `act` after upgrading
  returns exit 3 until you take a fresh `snapshot`.)
- **Input reported as delivered but never delivered.** `CGEvent.post` is
  asynchronous and the process exited before the window server delivered —
  measured 0 of 3 files written while every command exited 0. Delivery now waits
  on an observable counter with a bounded deadline.
- **A diff that described the wrong thing.** The post-action diff returned on the
  first non-empty reading, so a still-rendering interface produced a partial or
  unrelated one — up to 4 of 8 runs under load; 0 of 8 in every condition after.
- **A self-referential accessibility graph erased the real UI.** Some applications
  expose their own application element as their own child; the walk filled its node
  budget with 101 nested nodes and the real window never appeared. Cycles are now
  cut and reported.
- **An accessibility failure rendered as an empty result.** `windows` printed "no
  windows" at exit 0 for a process whose accessibility API was disabled while it
  visibly owned a window.
- **An ambiguous bundle id was silently resolved** to whichever process came first
  — sometimes one with a dead accessibility server. Now refused, listing the pids.
- **Screenshots killed an in-progress recording** (reproduced 4/4). Step stills are
  now extracted from the movie, and a standalone `screenshot` during a recording is
  refused rather than silently invalidating it.
- **A killed recorder was reported as a successful recording** — capture flushes
  playable fragments, so the artifact passes every check. A recording is now
  successful only if the recorder countersigned it after finalizing.

## [0.1.0] — 2026-08-07

Initial release: perception, action, waiting, screenshots, the MCP stdio server,
and trajectory recording, built across three validated milestones.

- **Perception** — accessibility tree as compact ref-annotated text or stable JSON;
  noise-filtered, menu-collapsed, with secure-field values masked.
- **Action** — `press` / `focus` / `show-menu` / `set-value` by ref, plus
  coordinate and keyboard verbs, each returning an accessibility diff.
- **Synchronization** — `wait --appears/--disappears/--text/--value-equals` over a
  bounded poll engine. No `sleep` anywhere.
- **Vision fallback** — `screenshot` via ScreenCaptureKit, full screen or by
  `CGWindowID`.
- **Agent surface** — `mtouch mcp`, an MCP stdio server with payloads
  byte-identical to the CLI and zero network endpoints.
- **Recording** — `MTOUCH_TRAJECTORY` appends a JSONL trajectory.

[Unreleased]: https://github.com/wanggang316/mtouch/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/wanggang316/mtouch/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/wanggang316/mtouch/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/wanggang316/mtouch/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/wanggang316/mtouch/releases/tag/v0.1.0
