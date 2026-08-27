import ArgumentParser
import Foundation
import MTouchKit

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for a UI condition in an application.",
        discussion: """
        Polls the target application's accessibility tree until a condition holds \
        or the timeout expires. Exactly one condition flag is required.

        A CRITERIA is a role name optionally followed by a quoted substring matched \
        over an element's title and value, e.g. 'textarea' or 'button "Save"'. \
        Friendly role names map to AX roles (textarea → AXTextArea, button → \
        AXButton, window → AXWindow, menu → AXMenu); a raw AX role is also accepted. \
        A role that matches nothing simply times out (exit 4).

        --stable waits for QUIESCENCE: the watched tree must stop changing, not \
        merely start containing something. Scope it with --of; without --of the \
        whole tree must settle. Use it after a --text or --appears wait when the \
        content streams in — --text matches the FIRST fragment, so reading straight \
        after it yields a half-written result. Any change restarts the quiet window; \
        --of matching nothing is not success (an absent element has not settled), so \
        it keeps waiting until the element appears AND settles. On timeout the \
        diagnostic reports how many changes were seen and the longest quiet stretch \
        achieved, so a retry can be an informed one.

        DURATIONS accept '5s', '500ms', or a bare number of seconds ('5'). The \
        default interval is 100ms and the default --stable-for is 500ms. \
        --stable-for may equal --timeout (meaning "never changed at all"), but not \
        exceed it (exit 64).

        Exit codes: 0 condition met; 4 timed out; 2 Accessibility not granted; \
        1 the application is not running; 64 a malformed invocation.
        """
    )

    @OptionGroup var appOptions: RequiredAppOptions

    // Exactly ONE condition flag must be present; mutual exclusivity, the
    // `--of`-requires-`--value-equals` rule, and the non-empty `--text` rule are
    // enforced in `validate()` so a malformed invocation is a usage error (exit
    // 64) BEFORE any AX call.
    @Option(help: ArgumentHelp("Wait until an element matching the criteria appears.", valueName: "criteria"))
    var appears: String?

    @Option(help: ArgumentHelp("Wait until an element matching the criteria disappears.", valueName: "criteria"))
    var disappears: String?

    @Option(help: ArgumentHelp("Wait until the given text is visible.", valueName: "s"))
    var text: String?

    @Option(help: ArgumentHelp("Wait until an element's value equals the given string.", valueName: "s"))
    var valueEquals: String?

    @Flag(help: "Wait until the watched tree stops changing (quiescence). Scope it with --of.")
    var stable = false

    @Option(help: ArgumentHelp(
        "Scope for --value-equals and --stable: only elements matching this criteria.",
        valueName: "criteria"
    ))
    var of: String?

    @Option(help: ArgumentHelp(
        "How long --stable requires the tree to stay unchanged (default 500ms).", valueName: "duration"
    ))
    var stableFor: WaitDuration?

    @Option(help: ArgumentHelp("Maximum time to wait (e.g. 5s, 500ms).", valueName: "duration"))
    var timeout: WaitDuration

    @Option(help: ArgumentHelp("Polling interval (default 100ms).", valueName: "duration"))
    var interval: WaitDuration?

    /// Default poll interval when `--interval` is omitted.
    static let defaultInterval = WaitDuration(seconds: 0.1)

    mutating func validate() throws {
        if let message = WaitGrammar.selectionError(
            appears: appears, disappears: disappears, text: text, valueEquals: valueEquals, of: of,
            stable: stable, stableFor: stableFor?.seconds, timeout: timeout.seconds
        ) {
            throw ValidationError(message)
        }
    }

    mutating func run() throws {
        let condition = WaitGrammar.makeCondition(
            appears: appears, disappears: disappears, text: text, valueEquals: valueEquals, of: of,
            stable: stable, stableFor: stableFor?.seconds
        )

        let outcome = try recorded(
            command: "wait",
            args: TrajectoryArgs.build([
                "app": .string(appOptions.app),
                "pid": appOptions.pid.map { .int(Int($0)) },
                "appears": appears.map(TrajectoryArgs.Value.string),
                "disappears": disappears.map(TrajectoryArgs.Value.string),
                "text": text.map(TrajectoryArgs.Value.string),
                "valueEquals": valueEquals.map(TrajectoryArgs.Value.string),
                "stable": stable ? .bool(true) : nil,
                "of": of.map(TrajectoryArgs.Value.string),
                "stableFor": stableFor.map { .double($0.seconds) },
                "timeout": .double(timeout.seconds),
                "interval": interval.map { .double($0.seconds) },
            ]),
            kind: .read,
            describe: { (outcome: WaitOutcome) in outcome.trajectoryInfo }
        ) {
            // `--pid` rides the pipeline's existing resolution seam.
            WaitPipeline.run(
                bundleId: appOptions.app,
                condition: condition,
                timeout: timeout.seconds,
                interval: (interval ?? Self.defaultInterval).seconds,
                resolvePID: AppTarget.resolver(pid: appOptions.pid)
            )
        }

        switch outcome {
        case .satisfied:
            return
        case let .failed(stderr, code):
            FileHandle.standardError.write(Data((stderr + "\n").utf8))
            throw ExitCode(code.rawValue)
        }
    }
}
