import ArgumentParser

struct Windows: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List windows of an application."
    )

    @OptionGroup var appOptions: RequiredAppOptions

    @Flag(help: "Emit machine-readable JSON output.")
    var json = false

    mutating func run() throws { stubExit("windows") }
}
