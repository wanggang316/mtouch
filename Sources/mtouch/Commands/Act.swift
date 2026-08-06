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
    let outcome = ActPipeline.run(
        ref: arguments.ref,
        verb: verb,
        value: arguments.value,
        json: arguments.json,
        environment: ProcessInfo.processInfo.environment
    )
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

extension Act {
    struct Click: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "click",
            abstract: "Click at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to click.", valueName: "x,y"))
        var at: ScreenPoint

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws { stubExit("act click") }
    }

    struct RightClick: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rightclick",
            abstract: "Right-click at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to right-click.", valueName: "x,y"))
        var at: ScreenPoint

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws { stubExit("act rightclick") }
    }

    struct DoubleClick: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "doubleclick",
            abstract: "Double-click at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to double-click.", valueName: "x,y"))
        var at: ScreenPoint

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws { stubExit("act doubleclick") }
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

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws { stubExit("act drag") }
    }

    struct Scroll: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scroll",
            abstract: "Scroll at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to scroll at.", valueName: "x,y"))
        var at: ScreenPoint

        @Option(help: ArgumentHelp("Vertical scroll delta.", valueName: "n"))
        var dy: Int

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws { stubExit("act scroll") }
    }
}

// MARK: - Keyboard verbs

/// Executes a keyboard verb through `ActPipeline.runKeyboard` and maps its
/// outcome to stdout/stderr + exit code, mirroring `runRefVerb`. The pipeline
/// reuses the ref verbs' back half (activate → post → re-walk → diff → persist);
/// only the "act" step differs (keystrokes to the focused element).
func runKeyboardVerb(_ action: KeyboardAction, appOverride: String?, json: Bool) throws {
    let outcome = ActPipeline.runKeyboard(
        action: action,
        appOverride: appOverride,
        json: json,
        environment: ProcessInfo.processInfo.environment
    )
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
            try runKeyboardVerb(.type(text), appOverride: appOptions.app, json: json)
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
            try runKeyboardVerb(.key(parsed), appOverride: appOptions.app, json: json)
        }
    }
}
