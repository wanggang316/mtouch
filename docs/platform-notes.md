# Platform notes

macOS behaviours that cost a debugging cycle to learn. Each entry carries the
measurement that established it, because several contradict what the API
documentation implies, and a claim without evidence is not re-checkable.

Read this before writing anything that talks to macOS.

## Process and workspace

**`NSWorkspace.runningApplications` and `.frontmostApplication` never refresh
without a main run loop.** A one-shot CLI never runs one, so a newly launched
process is never observed and an application switch is never seen. Both failure
directions are silent-but-wrong: a healthy launch reads as a timeout, a successful
activation as a lost race. The first live `app launch` sat for its full 15 s and
exited 4.

*Use instead:* a LaunchServices query for readiness, and the AX system-wide
focused application for frontmost. A **single** read of `runningApplications` at
process start is fine — it is polling that never advances.

**`kill(pid, 0)` answers 0 for a SIGKILLed process for ~50 ms** while it is an
unreaped zombie. Liveness must additionally check the process state via `sysctl`
for `SZOMB`. Residue: a one-shot command failing inside the ~15–50 ms teardown
window still sees the older diagnostic; a polling command self-heals next tick.

**Several processes can share one bundle id** — a second browser profile launched
with its own `--user-data-dir` is a normal case, and one of them may have a dead
accessibility server while the other is healthy.

## Accessibility

**An application can expose its own application element as its own child.**
Observed with `CFEqual(child, appElement) == true`, 101 levels deep. Without cycle
detection the walk fills its node budget with recursion and the real window never
appears at all: 901 lines of output, zero windows, refs burned to `e599`. A depth
cap converts an infinite loop into a large pile of garbage, not into correctness.

The condition appeared **while the host screen was locked** and cleared when it
unlocked — so a locked-screen run does not behave like an unlocked one.

**Many controls carry no title.** The system calculator's buttons expose their
identity only through `AXIdentifier` (`Seven`, `Multiply`) and `AXDescription`;
reading title and value alone renders 22 indistinguishable `AXButton ""` lines and
the application is unusable. Label priority: title → value → description →
identifier.

**AppKit exposes nib-decoding indices as `AXIdentifier`** — `_NS:8`, `_NS:833`.
On one stock application, 10 of 11 identifiers were of this form. They are
meaningless and unstable across builds, so they are filtered out of the *display*
label while the raw attribute is still published in JSON and still matchable.

**A modal open/save panel is hosted out-of-process** (by the system's panel
service) while its window is attributed to the owning application's pid. It runs a
nested event loop that blocks that application's accessibility server entirely:
`snapshot` and `act` correctly refuse (exit 1, "appears unresponsive"), and
`--no-verify` is the route through.

**Some applications expose no accessibility tree for their document view at all**
while exposing a complete menu bar. Menu-path invocation is the reliable route
into those, and it has the added property of being a verifiable AX press rather
than a keystroke that depends on winning the frontmost race.

## Input synthesis

**`CGEvent.post` is asynchronous.** Posting and then exiting delivers nothing
while every command exits 0. Isolated by varying only the post-exit linger:

```
linger=0.0  out=[]        linger=0.5  out=[abcdef]
```

This one cause explained four separate symptoms: short combos occasionally winning
the race, long strings losing after the first pair, separate commands landing
nothing, and the verified path "working" only because its post-action walk kept
the process alive. Delivery now waits on `CGEventSourceCounterForEventType` with a
bounded deadline.

**Keep the unicode payload on synthesized key events.** Posting a bare keycode
lets an active IME compose it — with a Pinyin input source, `zqx` arrived as
`z'q'x`. mtouch sends the real keycode *and* the payload, which is closest to what
hardware produces.

**TCC grants attach to the invoking terminal application**, not to the binary.
A `setsid`-detached child (ppid 1, no tty) *does* inherit the Screen Recording
grant through `posix_spawn` — this was measured, not assumed, because losing it
would have made the recorder capture nothing without erroring.

## Screen capture

**A second capture session from the same client application invalidates a live
recording.** Reproduced 4/4, and isolated with controls: the system capture tool
does not do it, a separate capture binary does not, a byte-identical copy of the
mtouch binary at a *different path* does not — the same path does. Hence: during a
recording, no second session is opened and step stills are extracted from the
movie.

**Screen capture flushes playable fragments continuously**, so a `SIGKILL`ed
recorder leaves a well-formed movie with a positive duration and a video track
that passes every artifact check. Only a countersignature written after finalize
distinguishes a finished recording from an interrupted one.

**The effective frame rate is variable** — 0.74–9.68 fps observed, because frames
are emitted on change. Never assert a fixed rate, and never extract a frame with
zero tolerance. Conversely a *generous* tolerance falsifies evidence: a 2 s
tolerance collapsed 8 distinct steps onto 4 frames, captioning one picture as four
different moments. Measured four tolerances and shipped 0.75 s.

## Environment

**The session host grabs frontmost during shell commands**, which degrades
keyboard and multi-step live probes. Prefer AX delivery (`set-value`,
`act menu`) over synthesized keystrokes where a choice exists. Never use
`osascript` — it triggers a TCC prompt.

**CI runners are headless with no decoder.** Nothing in the unit suite may attempt
real capture, media decoding, or AX access. A media read there hangs to the
verifier's deadline and returns "unreadable", which does not merely break positive
tests — it hollows out negative ones that assert a refusal.

**Detecting host capability by probing is unreliable** on those runners: the first
container read returns quickly and a later identical read hangs, so a probe
reports "can decode" and the test times out anyway. Key on the environment
instead, and skip visibly.
