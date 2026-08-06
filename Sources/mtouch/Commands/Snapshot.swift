import ArgumentParser

struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Capture an accessibility snapshot of an application."
    )

    @OptionGroup var appOptions: RequiredAppOptions

    @Flag(help: "Emit machine-readable JSON output.")
    var json = false

    mutating func run() throws { stubExit("snapshot") }
}
