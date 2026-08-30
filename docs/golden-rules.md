# Golden Rules

Every rule here was paid for. Each one names the failure it prevents and, where a
measurement exists, the number that motivated it.

## 1. A wrong answer is worse than a refusal

A tool an agent cannot trust is worse than no tool, because a confident wrong
answer propagates. So mtouch refuses instead of guessing:

- A bundle id matching several processes is refused with the candidate pids
  listed. Guessing bound to a process whose accessibility server was dead, and
  every subsequent step failed for reasons that looked nothing like the cause.
- A ref whose element moved is rejected (exit 3, *"Nothing was acted on"*), never
  re-pointed at whatever now occupies that position. Before element labels became
  part of ref identity, a sibling shift silently re-pointed every ref at its
  neighbour: an intended `123 × 456` was entered as `13+456`, with all eight
  presses exiting 0.
- An accessibility read that fails is an error, never an empty result. `windows`
  once printed *"no windows"* at exit 0 for a process that visibly owned a window.
- Acting on an ambiguous criteria is refused with the candidates listed — while
  *reading* many matches is safe, so `read --of` returns them all. The asymmetry
  is deliberate.

**Enforcement:** exit-code taxonomy pinned in the validation contract; the
adversarial failure drill (10 cases, all previously-shipped bugs) in the scenario
suite.

## 2. An action must return evidence, and grade it

Every `act` returns an AX diff. When the evidence is weaker than usual, the output
says so — on stdout and as a machine-readable field:

| Field | Meaning |
|---|---|
| `verified: false` | no diff was taken (you passed `--no-verify`) |
| `deliveryConfirmed: false` | input was posted but delivery could not be confirmed |
| `settled: false` | the UI was still changing when the settle budget expired |

A *wrong* diff is worse than no diff: an agent reading "nothing changed" after a
successful action retries and double-applies it. The settle race produced exactly
that — up to 4 of 8 runs under load reported a partial or unrelated diff; 0 of 8
after the fix.

**Enforcement:** three fields in the trajectory record; distinct `ActOutcome`
cases so no consumer can silently treat them as ordinary success.

## 3. No `sleep`, anywhere

Every synchronization point is an explicit, bounded wait on an observable
condition. A sleep is a guess about someone else's timing that fails on a loaded
machine and wastes time on a fast one.

Where waiting is genuinely needed, the *condition* is the interesting part:
`--stable` waits until content stops changing. Against a streaming answer,
`--text <fragment>` returned in 0.71 s with 212 characters while `--stable`
returned in 15.21 s with 4197 — **both at exit 0**. Without quiescence an agent
proceeds on 5% of an answer with no error to warn it.

Event pacing is the one nearby thing that is *not* a synchronization guess: input
delivery waits on an observable counter, not a fixed delay.

**Enforcement:** VAL-WAIT-011 ("no sleep surface exists"); `WaitPoll` seams take
an injected clock so timing is deterministic in tests.

## 4. Measure before diagnosing

State a root cause only from evidence actually observed. This project's history
contains several confident diagnoses that a five-minute probe falsified:

- "The real window is still reachable via `kAXWindows`" — the single element
  returned *was* the application element. The count was read without inspecting
  the contents.
- "The panel ignores unicode-payload events" — a probe posting exactly that shape
  typed perfectly. The real cause (the process exited before the window server
  delivered) was simpler and explained all four symptoms at once.

When one cause explains every symptom, that is evidence it is the real one. When
your explanation needs a special case per symptom, keep measuring.

**Enforcement:** diagnosis-driven briefs must measure each suspected symptom
before any fix, and skip what turns out not to be broken.

## 5. Prove a test fails without its fix

Neuter the guard, watch the test fail, restore it. A test that passes either way
pins nothing.

This is not theoretical. A CI failure once revealed that two "passing" negative
tests were asserting nothing at all: they expected a refusal, and a blanket
timeout refuses everything. And a before/after comparison was once run against a
binary that was silently the fixed one — SwiftPM records absolute paths, so
copying `.build` across directories does not rebuild.

**Enforcement:** implementer briefs require the neuter-prove-restore cycle with
the failure count pasted.

## 6. Declare what you could not verify

Coverage that cannot be honest should be visibly absent. CI runners are headless
with no decoder, so media-container tests are **skipped visibly** there and run on
developer machines — because a blanket read timeout would have made the negative
cases pass while asserting nothing.

Two gaps are currently declared rather than papered over: the `settled: false`
path has deterministic coverage but was never reproduced live, and a one-shot
command failing inside the ~15–50 ms kernel teardown window after `SIGKILL` still
sees the older diagnostic.

**Enforcement:** VAL-ENV-009; environment-blocked assertions are recorded in the
plan, and `fdd gate` withholds a pass rather than force-passing them.

## 7. Evidence collection never breaks the task it documents

A capture failure is recorded into the step and execution continues at the
command's normal exit code. An evidence system that can fail the run it is
documenting is worse than none.

Related: while a recording is live mtouch opens no second capture session (one
invalidates the other — reproduced 4/4), so step stills are extracted from the
movie instead, which also makes them provably contemporaneous.

## 8. Fix the environment, not the prompt

When the same mistake recurs, the toolchain needs work. Measuring an exit code
through a pipe produced a false conclusion four times, so the instruction now
appears in every brief and as a comment in `ci/smoke.sh`. Concurrent implementers
trampled the working tree once, so serial dispatch is now a standing rule — and it
extends to the screen itself, which is shared state during live probes.
