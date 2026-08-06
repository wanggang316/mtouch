import ArgumentParser

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot of the screen or a window."
    )

    @Option(help: ArgumentHelp("Identifier of the window to capture.", valueName: "id"))
    var window: String?

    @Option(help: ArgumentHelp("File path to write the image to.", valueName: "path"))
    var out: String?

    mutating func run() throws { stubExit("screenshot") }
}
