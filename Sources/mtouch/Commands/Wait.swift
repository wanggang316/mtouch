import ArgumentParser
import MTouchKit

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for a UI condition in an application."
    )

    @OptionGroup var appOptions: RequiredAppOptions

    // Condition flags. Exactly one of --appears / --disappears / --text /
    // --value-equals is expected; mutual exclusivity is enforced in a later
    // feature — for now the grammar only parses them.
    @Option(help: ArgumentHelp("Wait until an element matching the criteria appears.", valueName: "criteria"))
    var appears: String?

    @Option(help: ArgumentHelp("Wait until an element matching the criteria disappears.", valueName: "criteria"))
    var disappears: String?

    @Option(help: ArgumentHelp("Wait until the given text is visible.", valueName: "s"))
    var text: String?

    @Option(help: ArgumentHelp("Wait until an element's value equals the given string.", valueName: "s"))
    var valueEquals: String?

    @Option(help: ArgumentHelp("Criteria selecting the element checked by --value-equals.", valueName: "criteria"))
    var of: String?

    @Option(help: ArgumentHelp("Maximum time to wait, in seconds.", valueName: "duration"))
    var timeout: WaitDuration

    @Option(help: ArgumentHelp("Polling interval, in seconds.", valueName: "duration"))
    var interval: WaitDuration?

    mutating func run() throws { stubExit("wait") }
}
