# Driving a computer with mtouch — an agent's guide

This is the practical companion to the README: how to turn a natural-language task into mtouch
calls, and what to do when an application fights back. Every technique here exists because a real
application broke the obvious approach.

## The loop

```
perceive  ->  act  ->  verify
snapshot      act        the diff the act returned
```

Refs (`e1`, `e2`, …) belong to the snapshot that issued them. They survive ordinary actions — the
diff carries them forward — but an element that genuinely went away makes its ref **stale**, and a
stale ref is refused (exit 3, "Nothing was acted on") rather than re-pointed at whatever is now in
that position. When you get exit 3, re-snapshot; do not retry blindly.

## Finding the thing you want to click

`snapshot` labels each element with the first available of title → value → **accessibility
description** → **identifier**, marking the last two `@desc` / `@id`. Many controls carry no title
at all, so this matters:

```
AXButton "7"@desc #e5      AXButton "乘"@desc #e8      AXButton "等于"@desc #e20
```

Criteria (`wait --appears`, `read --of`) match a quoted substring against **all four** attributes:

```sh
mtouch wait --app <id> --appears 'button "Seven"' --timeout 5s     # matches an identifier
mtouch read --app <id> --of 'scrollarea "编辑字段"'                  # matches a description
```

If the text you want is long, do not parse it out of a snapshot — the text tree has a node budget
and drops non-actionable nodes past it. `read` never truncates.

## Waiting

Never sleep. Pick the weakest condition that actually means "ready":

| Situation | Use |
|---|---|
| an element should appear | `wait --appears '<criteria>'` |
| a dialog should go away | `wait --disappears '<criteria>'` |
| a field should hold a value | `wait --value-equals <v> --of '<criteria>'` |
| **content is still streaming or animating** | `wait --stable --of '<criteria>' --stable-for 1s` |

`--stable` is the one people forget. A streamed answer satisfies `--text <fragment>` on its first
fragment, at exit 0, and you will proceed on a partial result with no error to tell you. Any change
resets the quiet window; on timeout the diagnostic reports how many changes were seen and the
longest quiet stretch, which is what you need to decide whether to retry with a longer window.

## When an application has no usable accessibility tree

Some editors expose their menu bar but nothing of their document view. You can still drive them:

```sh
mtouch act menu "File>New File" --app <id>     # menu paths are verifiable AX presses
mtouch act menu "Edit>Paste"   --app <id>      # more reliable than cmd+v: no focus race
mtouch act menu "File>Save"    --app <id>
```

Prefer a menu path over a keyboard shortcut whenever one exists. A shortcut depends on winning the
frontmost race; a menu path is resolved and pressed through the accessibility tree, and a wrong path
fails loudly listing the available titles at that level instead of doing something unintended.

Verify the outcome at a boundary the tool cannot fake — for a file-producing task, that is the
**file on disk**, not the diff.

## When a modal panel blocks everything

An open/save panel runs a nested event loop and is often hosted out-of-process. Symptoms:

```
mtouch snapshot   -> exit 1, "the application appears unresponsive"
mtouch act key …  -> exit 1, "act timed out reading the accessibility tree"
```

That refusal is correct — mtouch will not act on a tree it cannot read. To drive the panel anyway,
opt out of verification explicitly:

```sh
mtouch act key  --no-verify cmd+shift+g --app <id>   # "go to folder"
mtouch act type --no-verify "/tmp/"      --app <id>
mtouch act key  --no-verify return       --app <id>
mtouch act type --no-verify "report.txt" --app <id>
mtouch act key  --no-verify return       --app <id>
```

`--no-verify` skips the pre/post walk, so no diff is produced. The output says
`delivered without verification`, and the trajectory records `verified:false` — an unverified action
must never be mistaken for a verified one. It is accepted only on input verbs; on ref verbs, which
need the tree to find their target, it is a usage error.

Navigate explicitly rather than trusting the panel's remembered directory — otherwise the file lands
somewhere you then have to hunt for.

## Targeting the right process

`--app <bundleId>` is required. If several processes share it, mtouch refuses and lists the pids:

```
mtouch: 'com.example.app' matches 2 running processes (48594, 90292).
        Pass --pid <pid> to choose one; 'mtouch apps' lists them.
```

This is deliberate. One of those processes may have a dead accessibility server, and binding to it
silently would make every later step wrong for reasons that look nothing like the cause.

## Trusting a diff

The diff an action returns is your verification, so mtouch tells you how much to trust it. Three
independent qualifiers can appear, each with its own field in `--json` and in the trajectory:

| Qualifier | Meaning | When you see it |
|---|---|---|
| `verified:false` | no diff was taken at all | you passed `--no-verify` |
| `deliveryConfirmed:false` | the input was posted but its delivery could not be confirmed | rare; a loaded or wedged window server |
| `settled:false` | the interface was still changing when the settle budget expired | animations, streaming content, a slow render |

An unsettled diff is prefixed on stdout with `(unsettled) …`. It is not a failure — the exit code
is still 0 and the action did happen — but the diff "may be partial or may describe a state the
application has already moved past". Re-`snapshot` to read the current state rather than treating
the diff as ground truth.

The reason these exist: a *wrong* diff is worse than no diff. An agent that reads "nothing changed"
after a successful action retries and double-applies it. Rather than guess, mtouch reports its own
uncertainty.

## Reading exit codes

`0` ok · `1` runtime · `2` permission · `3` ref · `4` wait timeout · `5` secure input · `64` usage.

Two are recoverable without human help: **3** (re-snapshot and retry) and **4** (wait longer, or
wait for a different condition). **2** means a permission is missing — run `mtouch doctor`. **64** is
your own invocation being wrong; the message names what.

Measure exit codes directly. `cmd | head` reports `head`'s status, not the command's — a mistake
that will tell you an action succeeded when it did not.

## Leaving evidence behind

```sh
RUN=~/runs/task-1
mtouch record start --run-dir "$RUN" --max-duration 600s
MTOUCH_RUN_DIR=$RUN MTOUCH_RUN_CAPTURE=1 MTOUCH_RUN_LABEL="task 1" mtouch act press e5
mtouch record stop  --run-dir "$RUN"
mtouch report "$RUN"
```

The bundle records whatever was on screen, and a successful `act type <secret>` is in the trajectory
verbatim (payloads are stripped only on failed records). Use `mtouch report --redact` when the
bundle leaves your machine.

## Things that will bite you

- **Screen lock changes the accessibility graph.** At least one application exposes its application
  element as its own child while the screen is locked, and its real window becomes unreachable
  through every accessibility attribute. mtouch cuts the cycle and says so, but the window is not
  there to drive. Do not assume a locked-screen run behaves like an unlocked one.
- **`(no changes)` is not failure.** In an AX-opaque app a successful action can produce no visible
  diff. The exit code is the signal; verify at a real boundary.
- **The frontmost application is shared state.** Two agents driving different apps on one machine
  will fight over it. Use `MTOUCH_SESSION` to isolate ref sessions, and serialize anything that
  synthesizes input.
