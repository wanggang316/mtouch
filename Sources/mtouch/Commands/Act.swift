import ArgumentParser
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
/// Only set-value consumes `<value>`; semantics land in later features.
struct RefActionArguments: ParsableArguments {
    @Argument(help: ArgumentHelp("Element reference from a prior snapshot.", valueName: "ref"))
    var ref: String

    @Argument(help: ArgumentHelp("Optional value payload (used by set-value).", valueName: "value"))
    var value: String?

    @OptionGroup var appOptions: OptionalAppOptions
}

// MARK: - Ref-based verbs

extension Act {
    struct Press: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "press",
            abstract: "Press (activate) the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { stubExit("act press") }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "focus",
            abstract: "Give keyboard focus to the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { stubExit("act focus") }
    }

    struct ShowMenu: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show-menu",
            abstract: "Open the contextual menu of the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { stubExit("act show-menu") }
    }

    struct SetValue: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-value",
            abstract: "Set the value of the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { stubExit("act set-value") }
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

extension Act {
    struct TypeText: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type literal text."
        )

        @Argument(help: ArgumentHelp("Text to type.", valueName: "text"))
        var text: String

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws { stubExit("act type") }
    }

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "key",
            abstract: "Send a key combination."
        )

        @Argument(help: ArgumentHelp("Key combination, e.g. 'cmd+shift+t'.", valueName: "combo"))
        var combo: String

        @OptionGroup var appOptions: OptionalAppOptions

        mutating func run() throws { stubExit("act key") }
    }
}
