# mtouch

## Quick Start

```bash
swift build          # build
swift test           # hermetic unit suite (no AX / TCC / network / display)
./ci/smoke.sh        # end-to-end smoke of the built binary
```

There is no separate linter. The gate is **zero new warnings** from `swift build`
(one pre-existing `forcefullyActivate` deprecation is expected).

## Architecture Overview

mtouch drives arbitrary macOS applications for AI agents through the Accessibility
API, with a token-efficient text/JSON contract. Its shape is a loop —
**perceive → act → verify** — where perception is an AX tree rendered as text with
scoped refs, action is an AX call or synthesized input, and verification is the AX
diff the action returns. A ScreenCaptureKit path covers AX-opaque apps, and a run
evidence bundle (log, per-step stills, screen recording, HTML report) makes a run
auditable after the fact.

Domains, layers, and the seams that keep it testable: [Architecture](docs/architecture.md).

## Repository Structure

```
mtouch/
├── Sources/MTouchKit/       # all logic; ArgumentParser-free, injectable seams
├── Sources/mtouch/          # thin CLI (15 subcommands) + the MCP stdio server
├── Tests/MTouchKitTests/    # hermetic unit tests only
├── ci/                      # smoke.sh + ungranted-persona live probes
├── docs/                    # the Library (see below)
└── .github/workflows/       # ci.yml (3 jobs) + release.yml
```

## Golden Rules

1. **A wrong answer is worse than a refusal** — ambiguity is refused with the
   candidates listed, never guessed; a failed accessibility read is an error, never
   rendered as an empty result.
2. **An action must return evidence, and grade it** — every act returns a diff;
   weaker evidence is labelled (`verified` / `deliveryConfirmed` / `settled`)
   rather than passed off as normal.
3. **No `sleep`, anywhere** — every synchronization point is an explicit, bounded
   wait on an observable condition.
4. **Measure before diagnosing** — state a root cause only from evidence you have
   actually observed. Several confident diagnoses in this project's history were
   falsified by a five-minute probe.
5. **Prove a test fails without its fix** — neuter the guard, watch the test fail,
   restore. A test that passes either way pins nothing.

Full list with rationale: [Golden Rules](docs/golden-rules.md).

## Documentation

| Directory | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System architecture, domains, seams |
| [docs/agent-guide.md](docs/agent-guide.md) | How to drive a computer with mtouch |
| [docs/golden-rules.md](docs/golden-rules.md) | Constrained principles and conventions |
| [docs/platform-notes.md](docs/platform-notes.md) | macOS facts learned the hard way |
| [docs/design-docs/](docs/design-docs/) | Technical design docs (human-authored) |
| [docs/user-test-patterns.md](docs/user-test-patterns.md) | Project-wide testing conventions |
| [docs/references/](docs/references/) | External docs and API references |
| [docs/generated/](docs/generated/) | Generated artifacts |
| `.harness-runtime/` | Per-plan FDD state — **gitignored**, not part of docs |

## Working with This Repository

- Read [docs/platform-notes.md](docs/platform-notes.md) before touching anything
  that talks to macOS. Most of its entries cost a full debugging cycle to learn,
  and several are invisible to unit tests.
- Run `harness-stack:fdd` for non-trivial work; keep implementers **serial** —
  concurrent ones trample the shared tree, and the frontmost application is shared
  state too (do not drive apps while another agent is running live probes).
- Every behavioural claim needs pasted real output. Measure exit codes directly
  with `cmd; echo $?` — **never through a pipe**, which reports the last command's
  status and has produced false conclusions here four separate times.
- Unit tests must stay hermetic: no AX, no TCC, no network, no display, no media
  decoding. CI runners have none of them. What genuinely needs the environment is
  verified live and declared, never faked.
- Changing observable CLI or MCP behaviour means amending
  `.harness-runtime/plans/mtouch/validation-contract.md`. Implementers report the
  impact; the controller amends it.

## Build & Test Commands

```bash
swift build                      # build
swift test                       # full unit suite
swift test --filter <Suite>      # one suite
./ci/smoke.sh                    # smoke the debug binary
MTOUCH_BIN=$(which mtouch) ./ci/smoke.sh   # smoke an installed binary
make release                     # arm64 release binary
make package VERSION=v0.2.2      # release tarball + .sha256
make ungranted                   # ungranted-persona live probes
```

## Code Style & Conventions

- Swift 6, strict concurrency clean. New code adds zero warnings.
- All logic lives in `MTouchKit` behind injectable seams; `Sources/mtouch` stays a
  thin shell so everything stays unit-testable without the environment.
- JSON is hand-built for fixed key order and byte-stable output — do not swap in
  `JSONEncoder`, which does not guarantee ordering.
- Tests use swift-testing. No nested `#require` inside `#expect`, no `mutating`
  calls inside `#expect` (the CI toolchain rejects both), and no background threads
  left alive at test end (they crash the runner).
- Diagnostics are actionable: name what failed, what was seen, and the next command
  to run. An error message is a control surface for an agent, not a log line.
