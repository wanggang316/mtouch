import ArgumentParser

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as an MCP (Model Context Protocol) server."
    )

    mutating func run() throws { stubExit("mcp") }
}
