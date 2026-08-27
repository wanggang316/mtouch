import ArgumentParser

@main
struct MTouch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mtouch",
        abstract: "Agent-facing macOS UI automation CLI.",
        subcommands: [
            Doctor.self,
            Apps.self,
            App.self,
            Windows.self,
            Snapshot.self,
            Read.self,
            Act.self,
            Wait.self,
            Clipboard.self,
            Screenshot.self,
            Report.self,
            MCP.self,
            // DEV-ONLY, hidden from --help (shouldDisplay: false). Not one of the
            // public subcommands; exercises AXTreeWalker against a live app.
            WalkSmoke.self,
        ]
    )

    mutating func run() throws {
        // Bare invocation is a usage error (exit 64), not a help request.
        throw ValidationError("Missing subcommand. See 'mtouch --help' for the list of subcommands.")
    }
}
