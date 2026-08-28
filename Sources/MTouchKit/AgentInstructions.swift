/// The usage doctrine `mtouch init` installs alongside the MCP registration.
///
/// It is EMBEDDED in the binary rather than read from the repository, because the
/// installed binary has no repository: a Homebrew install is one file, and a file
/// that is not there at runtime cannot be an onboarding artifact. `docs/agent-guide.md`
/// stays the long-form companion for a human reading the source tree; this is the
/// compact operating manual an agent client loads.
///
/// The two are kept CONCEPTUALLY aligned by hand and nothing more. There is
/// deliberately no build step that reads the doc: coupling the binary's behavior
/// to a path under `docs/` would mean moving or renaming a document breaks the
/// build, and a doc tree must stay free to be reorganised.
public enum AgentInstructions {
    /// The name this file takes when it is written into a client's own directory.
    /// Prefixed with the tool it belongs to so it can never collide with — or be
    /// mistaken for — a file the client or the user owns.
    public static let fileName = "mtouch-agent-instructions.md"

    /// Raw-delimited so the JSON example below keeps its backslash escapes
    /// verbatim, exactly as they must be typed into a batch script.
    public static let text: String = #"""
    # mtouch — operating instructions for an agent

    mtouch drives macOS applications through the accessibility tree. Every command is
    one process, one action, one answer on stdout, and an exit code that means
    something. Read this before driving an application you have not driven before.

    ## The loop

        perceive  ->  act  ->  verify
        snapshot      act      the diff the act returned

    `mtouch snapshot --app <bundleId>` prints a labelled element tree. Each element
    carries a ref (`e1`, `e2`, …). Refs are SNAPSHOT-SCOPED: they belong to the
    snapshot that issued them. They survive ordinary actions — the diff carries them
    forward — but an element that genuinely went away makes its ref stale, and a
    stale ref is REFUSED (exit 3) rather than re-pointed at whatever now sits in that
    position. On exit 3, re-snapshot; never retry blindly.

    ## Addressing an element by criteria, not by ref

    A criteria is a role plus an optional quoted substring, matched over the
    element's title, value, accessibility description, and identifier:

        mtouch act press --of 'button "Seven"' --app com.apple.calculator
        mtouch read --of 'scrollarea "Editor"' --app <bundleId>
        mtouch wait --appears 'button "Save"' --timeout 5s --app <bundleId>

    `--of` resolves against the action's OWN pre-walk, so there is no ref to go
    stale. Prefer it for scripted flows; no snapshot is needed at all.

    Ambiguity is refused on purpose. Reading many matches is harmless, but ACTING on
    many is misdelivery, so more than one actionable match exits 1 and lists the
    candidates, and zero matches exits 1. Make the criteria more specific — do not
    hope the tool picks correctly.

    `act --of <criteria> --wait <duration>` waits for the criteria to resolve to
    exactly one actionable element and then acts, in one command. Several matches
    keep waiting (duplicates are often transient while a screen renders); expiry is
    exit 4, and the diagnostic says whether the criteria never appeared or stayed
    ambiguous. A target that dies mid-wait fails immediately at exit 1.

    ## Waiting

    Never sleep. Pick the weakest condition that actually means "ready":

    | Situation | Use |
    |---|---|
    | an element should appear | `wait --appears '<criteria>'` |
    | a dialog should go away | `wait --disappears '<criteria>'` |
    | a field should hold a value | `wait --value-equals <v> --of '<criteria>'` |
    | content is streaming or animating | `wait --stable --of '<criteria>' --stable-for 1s` |

    `--stable` is the one that gets forgotten. A streamed answer satisfies
    `--text <fragment>` on its FIRST fragment, at exit 0, and you will proceed on a
    partial result with nothing to tell you it was partial. `--stable` waits for a
    quiet window instead: any change resets it, and on timeout the diagnostic
    reports how many changes were seen and the longest quiet stretch — which is what
    you need to decide whether to retry with a longer window.

    ## Applications with no usable accessibility tree

    Some applications expose their menu bar and almost nothing of their document
    view. Drive them through menu paths:

        mtouch act menu "File>New File" --app <bundleId>
        mtouch act menu "Edit>Paste"    --app <bundleId>
        mtouch act menu "File>Save"     --app <bundleId>

    Prefer a menu path over a keyboard shortcut wherever one exists. A shortcut
    depends on winning the frontmost race; a menu path is resolved and pressed
    through the accessibility tree, and a wrong path fails loudly listing the titles
    available at that level instead of doing something unintended.

    For such an application, verify at a boundary the tool cannot fake — for a
    file-producing task, that is the file on disk, not the diff.

    ## Modal panels

    An open/save panel runs a nested event loop and is often hosted out of process,
    so reads against it time out:

        mtouch snapshot   -> exit 1, "the application appears unresponsive"
        mtouch act key …  -> exit 1, "act timed out reading the accessibility tree"

    That refusal is correct: mtouch will not act on a tree it cannot read. To drive
    the panel anyway, opt out of verification EXPLICITLY:

        mtouch act key  --no-verify cmd+shift+g --app <bundleId>
        mtouch act type --no-verify "/tmp/"      --app <bundleId>
        mtouch act key  --no-verify return       --app <bundleId>

    `--no-verify` skips the pre/post walk, so no diff is produced; the output says
    `delivered without verification`. It is accepted only on input verbs (type, key,
    click, …); on ref verbs, which need the tree to find their target, it is a usage
    error. Navigate the panel explicitly rather than trusting its remembered
    directory, then re-snapshot once the panel is gone.

    ## How much to trust a diff

    The diff an action returns is your verification, so mtouch states its own
    uncertainty. Three independent qualifiers can appear, each with its own field in
    `--json` and in the trajectory:

    | Qualifier | Meaning | When you see it |
    |---|---|---|
    | `verified:false` | no diff was taken at all | you passed `--no-verify` |
    | `deliveryConfirmed:false` | the input was posted but its delivery could not be confirmed | rare; a loaded or wedged window server |
    | `settled:false` | the interface was still changing when the settle budget expired | animations, streaming content, a slow render |

    An unsettled diff is prefixed on stdout with `(unsettled) …`. It is not a
    failure — the exit code is still 0 and the action did happen — but the diff may
    be partial, or may describe a state the application has already moved past.
    Re-snapshot instead of treating it as ground truth.

    These exist because a WRONG diff is worse than no diff: an agent that reads
    "nothing changed" after a successful action retries and double-applies it.

    ## Exit codes

        0   ok
        1   runtime failure
        2   a permission is missing — run 'mtouch doctor'
        3   ref error — the ref is stale; re-snapshot
        4   wait timeout — wait longer, or wait for a different condition
        5   secure input is active — a password field has the keyboard
        64  usage error — your invocation is wrong; the message names what

    Only 3 and 4 are recoverable without human help.

    A DEAD TARGET IS ITS OWN DIAGNOSIS. If the application exited or crashed, every
    surface says so at exit 1 and suggests `mtouch app launch` — you will not get a
    misleading exit 3 (re-snapshotting cannot resurrect a process), and `wait` fails
    fast instead of burning its whole timeout.

    Measure exit codes DIRECTLY. `cmd | head` reports `head`'s status, not the
    command's — a mistake that will tell you an action succeeded when it did not.

    ## Targeting the right process

    `--app <bundleId>` is required. If several live processes share the bundle id,
    mtouch refuses and lists the pids; pass `--pid <pid>` to choose one
    (`mtouch apps` lists them). This is deliberate — one of those processes may have
    a dead accessibility server, and binding to it silently would make every later
    step wrong for reasons that look nothing like the cause.

    ## Many steps, one process

        mtouch batch <<'EOF'
        {"tool":"act","arguments":{"verb":"press","of":"button \"One\"","app":"com.apple.calculator"}}
        {"tool":"wait","arguments":{"app":"com.apple.calculator","appears":"button \"Equals\"","timeout":"5s"}}
        {"tool":"read","arguments":{"app":"com.apple.calculator","of":"scrollarea \"Editor\""}}
        EOF

    Steps are MCP-shaped tool calls, one JSON object per line. The WHOLE batch is
    validated before step 1 runs (a typo on line 3 executes nothing, exit 64), and
    the first failing step stops it. One process, one round-trip.

    ## Evidence bundles

        RUN=~/runs/task-1
        mtouch record start --run-dir "$RUN" --max-duration 600s
        MTOUCH_RUN_DIR=$RUN MTOUCH_RUN_CAPTURE=1 mtouch act press e5
        mtouch record stop  --run-dir "$RUN"
        mtouch report "$RUN"

    WARNING: an evidence bundle captures WHATEVER IS ON SCREEN — other
    applications, notifications, and anything visible behind the target window. A
    successful `act type <secret>` is in the trajectory verbatim. Use
    `mtouch report --redact` before a bundle leaves the machine, and do not start a
    recording on a screen showing something that must not be recorded.

    ## Things that will bite you

    - `(no changes)` is not a failure. In an accessibility-opaque application a
      successful action can produce no visible diff. The exit code is the signal;
      verify at a real boundary.
    - The frontmost application is shared state. Two agents driving different
      applications on one machine will fight over it. Use `MTOUCH_SESSION` to
      isolate ref sessions, and serialize anything that synthesizes input.
    - Screen lock changes the accessibility graph. Do not assume a locked-screen run
      behaves like an unlocked one.

    """#
}
