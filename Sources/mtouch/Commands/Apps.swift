import ArgumentParser

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "List running applications."
    )

    @Flag(help: "Emit machine-readable JSON output.")
    var json = false

    mutating func run() throws { stubExit("apps") }
}
