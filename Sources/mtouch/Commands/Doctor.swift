import ArgumentParser

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report environment health and permission status."
    )

    @Flag(help: "Emit machine-readable JSON output.")
    var json = false

    mutating func run() throws { stubExit("doctor") }
}
