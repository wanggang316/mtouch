import ArgumentParser
import Foundation
import MTouchKit

struct Act: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "act",
        abstract: "Perform a UI action.",
        subcommands: [
            Press.self,
            Focus.self,
            ShowMenu.self,
            SetValue.self,
            Click.self,
            RightClick.self,
            DoubleClick.self,
            Drag.self,
            Scroll.self,
            TypeText.self,
            Key.self,
        ]
    )

    mutating func run() throws {
        // Bare `mtouch act` is a usage error (exit 64), not a help request.
        throw ValidationError("Missing action verb. See 'mtouch act --help' for the list of verbs.")
    }
}

// MARK: - Shared argument shapes

/// Positional grammar shared by the ref-based verbs: `<ref> [<value>]`.
/// Only set-value consumes `<value>`.
struct RefActionArguments: ParsableArguments {
    @Argument(help: ArgumentHelp("Element reference from a prior snapshot.", valueName: "ref"))
    var ref: String

    @Argument(help: ArgumentHelp("Optional value payload (used by set-value).", valueName: "value"))
    var value: String?

    @Flag(help: "Emit the resulting diff as machine-readable JSON.")
    var json = false

    @OptionGroup var appOptions: OptionalAppOptions
}

/// Executes a ref-based verb through `ActPipeline` and maps its outcome to
/// stdout/stderr + exit code. The CLI layer stays thin: the resolve → re-locate →
/// act → re-walk → diff → persist flow lives in `ActPipeline` so the coordinate
/// and keyboard verbs (later features) reuse it.
func runRefVerb(_ verb: ActVerb, _ arguments: RefActionArguments) throws {
    let environment = ProcessInfo.processInfo.environment
    let outcome = try recorded(
        command: "act",
        args: TrajectoryArgs.build([
            "verb": .string(verb.trajectoryName),
            "ref": .string(arguments.ref),
            "value": arguments.value.map(TrajectoryArgs.Value.string),
            "json": arguments.json ? .bool(true) : nil,
            "app": arguments.appOptions.app.map(TrajectoryArgs.Value.string),
            "pid": arguments.appOptions.pid.map { .int(Int($0)) },
        ]),
        kind: .action,
        describe: { (outcome: ActOutcome) in outcome.trajectoryInfo }
    ) {
        ActPipeline.run(
            ref: arguments.ref,
            verb: verb,
            value: arguments.value,
            json: arguments.json,
            environment: environment
        )
    }
    switch outcome {
    case let .acted(output):
        print(output)
    case let .failed(stderr, code):
        FileHandle.standardError.write(Data((stderr + "\n").utf8))
        throw ExitCode(code.rawValue)
    }
}

// MARK: - Ref-based verbs

extension Act {
    struct Press: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "press",
            abstract: "Press (activate) the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { try runRefVerb(.press, arguments) }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "focus",
            abstract: "Give keyboard focus to the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { try runRefVerb(.focus, arguments) }
    }

    struct ShowMenu: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show-menu",
            abstract: "Open the menu of the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { try runRefVerb(.showMenu, arguments) }
    }

    struct SetValue: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-value",
            abstract: "Set the value of the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { try runRefVerb(.setValue, arguments) }
    }
}

// MARK: - Coordinate-based verbs

/// Executes a coordinate verb through `ActPipeline.runCoordinate` and maps its
/// outcome to stdout/stderr + exit code, mirroring `runRefVerb`/`runKeyboardVerb`.
/// The pipeline reuses the ref/keyboard verbs' back half (resolve target →
/// off-screen guard → post → re-walk → diff → persist); only the "act" step
/// differs (a mouse gesture at screen points).
///
/// Malformed coordinates (`--at foo,bar`), reference tokens passed to a
/// coordinate-only verb (`drag --from e1 --to e2`, `click e1`), and unknown verbs
/// (`act wiggle`) are all rejected by ArgumentParser as usage errors (exit 64)
/// BEFORE this runs — a ref token is not a valid `x,y`, so it fails value parsing.
func runCoordinateVerb(_ action: PointerAction, appOverride: String?, pidOverride: pid_t?, json: Bool) throws {
    let environment = ProcessInfo.processInfo.environment
    let outcome = try recorded(
        command: "act",
        args: coordinateArgs(action, appOverride: appOverride, pidOverride: pidOverride, json: json),
        kind: .action,
        describe: { (outcome: ActOutcome) in outcome.trajectoryInfo }
    ) {
        // `--pid` rides the pipeline's existing resolution seam (it applies only
        // when `--app` selects the target; `OptionalAppOptions` rejects a lone pid).
        ActPipeline.runCoordinate(
            action: action,
            appOverride: appOverride,
            json: json,
            environment: environment,
            resolvePID: AppTarget.resolver(pid: pidOverride)
        )
    }
    switch outcome {
    case let .acted(output):
        print(output)
    case let .failed(stderr, code):
        FileHandle.standardError.write(Data((stderr + "\n").utf8))
        throw ExitCode(code.rawValue)
    }
}

/// The recorded args for a coordinate verb: the verb name plus its target points
/// (and scroll delta), mirroring the MCP `act` tool's argument vocabulary.
private func coordinateArgs(
    _ action: PointerAction, appOverride: String?, pidOverride: pid_t?, json: Bool
) -> TrajectoryArgs {
    var pairs: [String: TrajectoryArgs.Value?] = [
        "app": appOverride.map(TrajectoryArgs.Value.string),
        "pid": pidOverride.map { .int(Int($0)) },
        "json": json ? .bool(true) : nil,
    ]
    switch action {
    case let .click(point):
        pairs["verb"] = .string("click"); pairs["at"] = .string(point.rendered)
    case let .rightClick(point):
        pairs["verb"] = .string("rightclick"); pairs["at"] = .string(point.rendered)
    case let .doubleClick(point):
        pairs["verb"] = .string("doubleclick"); pairs["at"] = .string(point.rendered)
    case let .drag(from, to):
        pairs["verb"] = .string("drag")
        pairs["from"] = .string(from.rendered); pairs["to"] = .string(to.rendered)
    case let .scroll(at, dy):
        pairs["verb"] = .string("scroll")
        pairs["at"] = .string(at.rendered); pairs["dy"] = .int(dy)
    }
    return TrajectoryArgs.build(pairs)
}

extension Act {
    struct Click: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "click",
            abstract: "Click at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to click.", valueName: "x,y"))
        var at: ScreenPoint

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws {
            try runCoordinateVerb(.click(at), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json)
        }
    }

    struct RightClick: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rightclick",
            abstract: "Right-click at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to right-click.", valueName: "x,y"))
        var at: ScreenPoint

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws {
            try runCoordinateVerb(.rightClick(at), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json)
        }
    }

    struct DoubleClick: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "doubleclick",
            abstract: "Double-click at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to double-click.", valueName: "x,y"))
        var at: ScreenPoint

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws {
            try runCoordinateVerb(.doubleClick(at), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json)
        }
    }

    struct Drag: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "drag",
            abstract: "Drag from one screen coordinate to another."
        )

        @Option(help: ArgumentHelp("Starting screen coordinate.", valueName: "x,y"))
        var from: ScreenPoint

        @Option(help: ArgumentHelp("Ending screen coordinate.", valueName: "x,y"))
        var to: ScreenPoint

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws {
            try runCoordinateVerb(.drag(from: from, to: to), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json)
        }
    }

    struct Scroll: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scroll",
            abstract: "Scroll at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to scroll at.", valueName: "x,y"))
        var at: ScreenPoint

        // `.unconditional` so a negative delta (`--dy -300`) is taken as the value
        // rather than parsed as an option/flag — the documented idiom for a
        // dash-prefixed numeric argument. Positive `--dy` scrolls content up.
        @Option(parsing: .unconditional,
                help: ArgumentHelp("Vertical scroll delta (positive scrolls content up).", valueName: "n"))
        var dy: Int

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws {
            try runCoordinateVerb(.scroll(at: at, dy: dy), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json)
        }
    }
}

// MARK: - Keyboard verbs

/// Executes a keyboard verb through `ActPipeline.runKeyboard` and maps its
/// outcome to stdout/stderr + exit code, mirroring `runRefVerb`. The pipeline
/// reuses the ref verbs' back half (activate → post → re-walk → diff → persist);
/// only the "act" step differs (keystrokes to the focused element).
/// `args` is supplied by the caller: the `type` verb records its `text`, and the
/// `key` verb its raw `combo` string (which the parsed `KeyCombo` does not
/// retain). A refused/failed keyboard verb has its payload stripped by the
/// recorder, so a secret never persists.
func runKeyboardVerb(
    _ action: KeyboardAction, appOverride: String?, pidOverride: pid_t?, json: Bool, args: TrajectoryArgs
) throws {
    let environment = ProcessInfo.processInfo.environment
    let outcome = try recorded(
        command: "act",
        args: args,
        kind: .action,
        describe: { (outcome: ActOutcome) in outcome.trajectoryInfo }
    ) {
        // `--pid` rides the pipeline's existing resolution seam (it applies only
        // when `--app` selects the target; `OptionalAppOptions` rejects a lone pid).
        ActPipeline.runKeyboard(
            action: action,
            appOverride: appOverride,
            json: json,
            environment: environment,
            resolvePID: AppTarget.resolver(pid: pidOverride)
        )
    }
    switch outcome {
    case let .acted(output):
        print(output)
    case let .failed(stderr, code):
        FileHandle.standardError.write(Data((stderr + "\n").utf8))
        throw ExitCode(code.rawValue)
    }
}

extension Act {
    struct TypeText: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type literal text."
        )

        @Argument(help: ArgumentHelp("Text to type.", valueName: "text"))
        var text: String

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws {
            let args = TrajectoryArgs.build([
                "verb": .string("type"),
                "text": .string(text),
                "json": json ? .bool(true) : nil,
                "app": appOptions.app.map(TrajectoryArgs.Value.string),
                "pid": appOptions.pid.map { .int(Int($0)) },
            ])
            try runKeyboardVerb(.type(text), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json, args: args)
        }
    }

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "key",
            abstract: "Send a key combination."
        )

        @Argument(help: ArgumentHelp("Key combination, e.g. 'cmd+shift+t'.", valueName: "combo"))
        var combo: String

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws {
            // Parse the combo FIRST: an unknown modifier/key name is a usage error
            // (exit 64) that must precede any permission/AX work (pinned 64 -> 2 -> 3).
            let parsed: KeyCombo
            do {
                parsed = try KeyCombo(parsing: combo)
            } catch let error as KeyComboParseError {
                FileHandle.standardError.write(Data((error.message + "\n").utf8))
                throw ExitCode(error.exitCode.rawValue)
            }
            let args = TrajectoryArgs.build([
                "verb": .string("key"),
                "combo": .string(combo),
                "json": json ? .bool(true) : nil,
                "app": appOptions.app.map(TrajectoryArgs.Value.string),
                "pid": appOptions.pid.map { .int(Int($0)) },
            ])
            try runKeyboardVerb(.key(parsed), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json, args: args)
        }
    }
}
