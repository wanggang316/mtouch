import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

private let binary = "/opt/homebrew/bin/mtouch"
private let olderBinary = "/usr/local/bin/mtouch"
private let clientCLI = "/opt/homebrew/bin/claude"
private let home = "/Users/agent"
private let defaultInstructions = "/Users/agent/.claude/mtouch-agent-instructions.md"

private let addArguments = [
    "mcp", "add", "--scope", "user", "mtouch", "--", binary, "mcp",
]
private let getArguments = ["mcp", "get", "mtouch"]
private let removeArguments = ["mcp", "remove", "mtouch"]

/// A `claude mcp get mtouch` report for a stdio server, in the client's own
/// layout — including the trailing prose line, so the parser is exercised
/// against text it must ignore.
private func getReport(command: String, args: String = "mcp") -> String {
    """
    mtouch:
      Scope: User config
      Status: ✔ Connected
      Type: stdio
      Command: \(command)
      Args: \(args)
      Environment:

    To remove this server, run: claude mcp remove mtouch -s user
    """
}

private struct RecordedCommand: Equatable {
    let executable: String
    let arguments: [String]
}

/// An `InitHost` whose every answer is scripted and whose every side effect is
/// recorded. A class, not a struct, so a test can inspect what the pipeline DID
/// without any mutating call inside an `#expect`.
private final class StubInitHost: InitHost {
    var executablePath = binary
    var homeDirectory = home
    /// Tools resolvable on PATH, mapped to their absolute path.
    var tools: [String: String] = ["claude": clientCLI]
    /// Scripted results keyed by the joined argument vector.
    var responses: [String: Result<InitCommandResult, InitFailure>] = [:]
    /// Answer for an argument vector with no scripted result.
    var fallback: Result<InitCommandResult, InitFailure> = .success(InitCommandResult(status: 0, output: ""))
    var files: [String: String] = [:]
    var writeResult: Result<Void, InitFailure> = .success(())

    private(set) var commands: [RecordedCommand] = []
    private(set) var writes: [String: String] = [:]

    /// The registration commands, isolated from the read-only probe.
    var addCommands: [RecordedCommand] {
        commands.filter { Array($0.arguments.prefix(2)) == ["mcp", "add"] }
    }

    var removeCommands: [RecordedCommand] {
        commands.filter { Array($0.arguments.prefix(2)) == ["mcp", "remove"] }
    }

    func locate(_ tool: String) -> String? { tools[tool] }

    func run(_ executable: String, _ arguments: [String]) -> Result<InitCommandResult, InitFailure> {
        commands.append(RecordedCommand(executable: executable, arguments: arguments))
        return responses[arguments.joined(separator: " ")] ?? fallback
    }

    func readFile(_ path: String) -> String? { files[path] }

    func writeFile(_ contents: String, to path: String) -> Result<Void, InitFailure> {
        if case .success = writeResult {
            writes[path] = contents
            files[path] = contents
        }
        return writeResult
    }

    /// A host whose client already carries a matching stdio entry AND the current
    /// instructions file: the state a second `mtouch init` run finds.
    static func alreadyRegistered() -> StubInitHost {
        let host = StubInitHost()
        host.responses[getArguments.joined(separator: " ")] =
            .success(InitCommandResult(status: 0, output: getReport(command: binary)))
        host.files[defaultInstructions] = AgentInstructions.text
        return host
    }

    /// A host whose client carries an entry pointing at a DIFFERENT binary.
    static func registeredElsewhere() -> StubInitHost {
        let host = StubInitHost()
        host.responses[getArguments.joined(separator: " ")] =
            .success(InitCommandResult(status: 0, output: getReport(command: olderBinary)))
        return host
    }

    /// A host whose client has no such server — this client answers non-zero.
    static func unregistered() -> StubInitHost {
        let host = StubInitHost()
        host.responses[getArguments.joined(separator: " ")] = .success(InitCommandResult(
            status: 1, output: "No MCP server named \"mtouch\". Configured servers: none"
        ))
        return host
    }
}

// MARK: - Outcome accessors (kept out of #expect)

private func reportedText(_ outcome: InitOutcome) -> String? {
    if case let .reported(stdout, _) = outcome { return stdout }
    return nil
}

private func failureText(_ outcome: InitOutcome) -> String? {
    if case let .failed(stderr, _) = outcome { return stderr }
    return nil
}

private func failureCode(_ outcome: InitOutcome) -> MTouchExitCode? {
    if case let .failed(_, code) = outcome { return code }
    return nil
}

// MARK: - Discovery

@Suite struct InitDiscoveryTests {
    @Test("no --client lists every client and changes nothing")
    func discoveryListsClients() throws {
        let host = StubInitHost()
        let outcome = InitPipeline.run(InitRequest(client: nil), host: host)

        let text = try #require(reportedText(outcome))
        for client in InitClient.allCases {
            #expect(text.contains("--client \(client.rawValue)"))
            #expect(text.contains(client.displayName))
        }
        #expect(text.contains("Nothing has been changed."))
    }

    @Test("discovery runs no command and writes no file")
    func discoveryIsInert() {
        let host = StubInitHost()
        _ = InitPipeline.run(InitRequest(client: nil), host: host)

        #expect(host.commands.isEmpty)
        #expect(host.writes.isEmpty)
    }

    @Test("discovery never depends on the client being installed")
    func discoveryWithoutClientCLI() {
        let host = StubInitHost()
        host.tools = [:]
        let outcome = InitPipeline.run(InitRequest(client: nil), host: host)

        #expect(reportedText(outcome) != nil)
    }
}

// MARK: - Dry run

@Suite struct InitDryRunTests {
    @Test("--print renders the add command with the absolute binary path")
    func printRendersClaudeCommand() throws {
        let host = StubInitHost()
        let outcome = InitPipeline.run(InitRequest(client: .claude, printOnly: true), host: host)

        let text = try #require(reportedText(outcome))
        #expect(text.contains("claude mcp add --scope user mtouch -- \(binary) mcp"))
        #expect(text.contains(defaultInstructions))
        #expect(text.contains(AgentInstructions.text))
    }

    @Test("--print renders the generic entry with the absolute binary path")
    func printRendersGenericEntry() throws {
        let host = StubInitHost()
        let outcome = InitPipeline.run(InitRequest(client: .mcpJSON, printOnly: true), host: host)

        let text = try #require(reportedText(outcome))
        #expect(text.contains("\"command\": \"\(binary)\""))
        #expect(text.contains("\"mtouch\""))
    }

    @Test("--print runs no command and writes no file", arguments: InitClient.allCases)
    func printIsInert(client: InitClient) {
        let host = StubInitHost.registeredElsewhere()
        _ = InitPipeline.run(InitRequest(client: client, printOnly: true), host: host)

        #expect(host.commands.isEmpty)
        #expect(host.writes.isEmpty)
    }

    @Test("--print works with the client CLI absent — that is when it is needed most")
    func printWithoutClientCLI() throws {
        let host = StubInitHost()
        host.tools = [:]
        let outcome = InitPipeline.run(InitRequest(client: .claude, printOnly: true), host: host)

        let text = try #require(reportedText(outcome))
        #expect(text.contains("claude mcp add --scope user mtouch -- \(binary) mcp"))
    }
}

// MARK: - Fresh registration

@Suite struct InitRegistrationTests {
    @Test("a fresh run issues exactly one add command carrying the absolute binary path")
    func freshRegistrationAddsOnce() throws {
        let host = StubInitHost.unregistered()
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        #expect(reportedText(outcome) != nil)
        #expect(host.addCommands.count == 1)
        let add = try #require(host.addCommands.first)
        #expect(add.executable == clientCLI)
        #expect(add.arguments == addArguments)
        #expect(add.arguments.contains(binary))
    }

    @Test("a fresh run probes for an existing entry before adding one")
    func freshRegistrationProbesFirst() throws {
        let host = StubInitHost.unregistered()
        _ = InitPipeline.run(InitRequest(client: .claude), host: host)

        let first = try #require(host.commands.first)
        #expect(first.arguments == getArguments)
        #expect(host.commands.count == 2)
    }

    @Test("a fresh run writes the agent instructions to the client's own directory")
    func freshRegistrationWritesInstructions() throws {
        let host = StubInitHost.unregistered()
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        #expect(host.writes[defaultInstructions] == AgentInstructions.text)
        let text = try #require(reportedText(outcome))
        #expect(text.contains("wrote agent instructions to \(defaultInstructions)"))
    }

    @Test("--out redirects the agent instructions")
    func outRedirectsInstructions() {
        let host = StubInitHost.unregistered()
        _ = InitPipeline.run(InitRequest(client: .claude, out: "/tmp/elsewhere.md"), host: host)

        #expect(host.writes["/tmp/elsewhere.md"] == AgentInstructions.text)
        #expect(host.writes[defaultInstructions] == nil)
    }

    @Test("a client that refuses the add reports its output and the command that ran")
    func rejectedAddIsReported() throws {
        let host = StubInitHost.unregistered()
        host.responses[addArguments.joined(separator: " ")] =
            .success(InitCommandResult(status: 1, output: "MCP server mtouch already exists in local config"))
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        let text = try #require(failureText(outcome))
        #expect(failureCode(outcome) == .runtimeFailure)
        #expect(text.contains("already exists in local config"))
        #expect(text.contains("claude mcp add --scope user mtouch -- \(binary) mcp"))
        #expect(host.writes.isEmpty)
    }
}

// MARK: - Idempotency

@Suite struct InitIdempotencyTests {
    @Test("a second run with an identical entry adds nothing and succeeds")
    func identicalEntryIsLeftAlone() throws {
        let host = StubInitHost.alreadyRegistered()
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        let text = try #require(reportedText(outcome))
        #expect(text.contains("already registered"))
        #expect(host.addCommands.isEmpty)
        #expect(host.removeCommands.isEmpty)
        #expect(host.writes.isEmpty)
    }

    @Test("an identical instructions file is recognised, not rewritten")
    func identicalInstructionsAreLeftAlone() throws {
        let host = StubInitHost.alreadyRegistered()
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        let text = try #require(reportedText(outcome))
        #expect(text.contains("already up to date at \(defaultInstructions)"))
    }

    @Test("an entry naming a different binary is refused, and nothing is changed")
    func differingEntryIsRefused() throws {
        let host = StubInitHost.registeredElsewhere()
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        let text = try #require(failureText(outcome))
        #expect(failureCode(outcome) == .runtimeFailure)
        #expect(text.contains("registered: \(olderBinary) mcp"))
        #expect(text.contains("this run:   \(binary) mcp"))
        #expect(text.contains("--force"))
        #expect(host.addCommands.isEmpty)
        #expect(host.removeCommands.isEmpty)
        #expect(host.writes.isEmpty)
    }

    @Test("--force replaces a differing entry: remove, then add the absolute path")
    func forceReplacesDifferingEntry() throws {
        let host = StubInitHost.registeredElsewhere()
        let outcome = InitPipeline.run(InitRequest(client: .claude, force: true), host: host)

        #expect(reportedText(outcome) != nil)
        #expect(host.commands.map(\.arguments) == [getArguments, removeArguments, addArguments])
        let add = try #require(host.addCommands.first)
        #expect(add.arguments.contains(binary))
    }

    @Test("--force that cannot remove the old entry never runs the add")
    func forceStopsWhenRemoveFails() throws {
        let host = StubInitHost.registeredElsewhere()
        host.responses[removeArguments.joined(separator: " ")] =
            .success(InitCommandResult(status: 1, output: "no such server"))
        let outcome = InitPipeline.run(InitRequest(client: .claude, force: true), host: host)

        let text = try #require(failureText(outcome))
        #expect(text.contains("The existing entry is unchanged."))
        #expect(host.addCommands.isEmpty)
        #expect(host.writes.isEmpty)
    }

    @Test("a non-stdio entry under the same name is a difference, not a match")
    func remoteEntryIsADifference() throws {
        let host = StubInitHost()
        host.responses[getArguments.joined(separator: " ")] = .success(InitCommandResult(
            status: 0,
            output: """
            mtouch:
              Scope: User config
              Type: http
              URL: https://example.invalid/mcp
            """
        ))
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        let text = try #require(failureText(outcome))
        #expect(text.contains("https://example.invalid/mcp"))
        #expect(host.addCommands.isEmpty)
    }

    @Test("an instructions file with different content is refused BEFORE anything is registered")
    func differingInstructionsBlockTheWholeRun() throws {
        let host = StubInitHost.unregistered()
        host.files[defaultInstructions] = "# an older mtouch wrote this\n"
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        let text = try #require(failureText(outcome))
        #expect(failureCode(outcome) == .runtimeFailure)
        #expect(text.contains(defaultInstructions))
        #expect(text.contains("--force"))
        // The whole point: a refusal leaves NOTHING half-applied.
        #expect(host.addCommands.isEmpty)
        #expect(host.writes.isEmpty)
    }

    @Test("--force overwrites an instructions file that differs")
    func forceOverwritesInstructions() {
        let host = StubInitHost.unregistered()
        host.files[defaultInstructions] = "# an older mtouch wrote this\n"
        _ = InitPipeline.run(InitRequest(client: .claude, force: true), host: host)

        #expect(host.writes[defaultInstructions] == AgentInstructions.text)
        #expect(host.addCommands.count == 1)
    }
}

// MARK: - Missing client CLI

@Suite struct InitMissingClientTests {
    @Test("a missing client CLI exits 1 printing the exact command that would have run")
    func missingCLIPrintsTheCommand() throws {
        let host = StubInitHost.unregistered()
        host.tools = [:]
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        let text = try #require(failureText(outcome))
        #expect(failureCode(outcome) == .runtimeFailure)
        #expect(text.contains("claude mcp add --scope user mtouch -- \(binary) mcp"))
        #expect(text.contains("not on PATH"))
    }

    @Test("a missing client CLI leaves nothing half-done")
    func missingCLIDoesNothing() {
        let host = StubInitHost.unregistered()
        host.tools = [:]
        _ = InitPipeline.run(InitRequest(client: .claude), host: host)

        #expect(host.commands.isEmpty)
        #expect(host.writes.isEmpty)
    }

    @Test("a client CLI that cannot be launched is a failure, never a missing entry")
    func unlaunchableCLIIsAFailure() throws {
        let host = StubInitHost()
        host.responses[getArguments.joined(separator: " ")] = .failure(InitFailure("Permission denied"))
        let outcome = InitPipeline.run(InitRequest(client: .claude), host: host)

        let text = try #require(failureText(outcome))
        #expect(text.contains("Permission denied"))
        #expect(host.addCommands.isEmpty)
        #expect(host.writes.isEmpty)
    }
}

// MARK: - Generic MCP entry

@Suite struct InitGenericEntryTests {
    @Test("mcp-json prints a pasteable entry naming the absolute binary and only 'mcp'")
    func genericEntryShape() throws {
        let host = StubInitHost()
        let outcome = InitPipeline.run(InitRequest(client: .mcpJSON), host: host)

        let text = try #require(reportedText(outcome))
        // The entry is the leading block up to the closing brace at column 0;
        // anything after it is guidance, not JSON.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let end = lines.firstIndex(of: "}") ?? lines.endIndex
        let json = lines[..<end].joined(separator: "\n") + "\n}"
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let object = try #require(decoded as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: Any])
        let entry = try #require(servers["mtouch"] as? [String: Any])
        #expect(entry["command"] as? String == binary)
        #expect(entry["args"] as? [String] == ["mcp"])
    }

    @Test("mcp-json runs no command and writes no file")
    func genericEntryIsInert() {
        let host = StubInitHost()
        _ = InitPipeline.run(InitRequest(client: .mcpJSON), host: host)

        #expect(host.commands.isEmpty)
        #expect(host.writes.isEmpty)
    }

    @Test("mcp-json writes the instructions only where --out names")
    func genericEntryWritesInstructionsOnDemand() {
        let host = StubInitHost()
        _ = InitPipeline.run(InitRequest(client: .mcpJSON, out: "/tmp/instructions.md"), host: host)

        #expect(host.writes["/tmp/instructions.md"] == AgentInstructions.text)
        #expect(host.commands.isEmpty)
    }
}

// MARK: - The embedded instructions

@Suite struct AgentInstructionsTests {
    @Test("the embedded instructions are present and substantial")
    func instructionsExist() {
        #expect(AgentInstructions.text.count > 2000)
        #expect(AgentInstructions.text.contains("perceive"))
        #expect(AgentInstructions.text.contains("--of"))
        #expect(AgentInstructions.text.contains("--stable"))
        #expect(AgentInstructions.text.contains("--no-verify"))
        #expect(AgentInstructions.text.contains("act menu"))
    }

    @Test("the embedded instructions carry the whole exit-code taxonomy")
    func instructionsCarryExitCodes() {
        // Driven off the enum, so a code added to the taxonomy and forgotten here
        // fails rather than quietly going undocumented.
        let lines = AgentInstructions.text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for code in MTouchExitCode.allCases {
            #expect(lines.contains { $0.hasPrefix("\(code.rawValue) ") })
        }
        #expect(AgentInstructions.text.contains("DEAD TARGET"))
        #expect(AgentInstructions.text.contains("mtouch app launch"))
    }

    @Test("the embedded instructions carry the three evidence qualifiers")
    func instructionsCarryQualifiers() {
        #expect(AgentInstructions.text.contains("verified:false"))
        #expect(AgentInstructions.text.contains("deliveryConfirmed:false"))
        #expect(AgentInstructions.text.contains("settled:false"))
    }

    @Test("the embedded instructions warn what an evidence bundle captures")
    func instructionsWarnAboutEvidence() {
        #expect(AgentInstructions.text.contains("WHATEVER IS ON SCREEN"))
    }
}

// MARK: - Client-report parsing and command rendering

@Suite struct InitParsingTests {
    @Test("a stdio report parses into its command and arguments")
    func parseStdio() {
        let entry = ClaudeEntry.parse(getReport(command: binary))
        #expect(entry == .stdio(command: binary, arguments: ["mcp"]))
        #expect(entry.matches(InitRegistration(command: binary)))
    }

    @Test("a stdio report with no arguments does not match a registration that has one")
    func parseStdioWithoutArguments() {
        let entry = ClaudeEntry.parse(getReport(command: binary, args: ""))
        #expect(entry == .stdio(command: binary, arguments: []))
        #expect(!entry.matches(InitRegistration(command: binary)))
    }

    @Test("unreadable output never parses as a matching stdio entry")
    func parseUnreadable() {
        let entry = ClaudeEntry.parse("mtouch:\n  Status: unknown\n")
        #expect(!entry.matches(InitRegistration(command: binary)))
    }

    @Test("a path with a space is quoted in the command mtouch prints")
    func printedCommandIsPasteable() {
        let plan = InitPlan(client: .claude, binary: "/Users/a b/mtouch", home: home, out: nil)
        #expect(plan.addCommandText.contains("'/Users/a b/mtouch'"))
        #expect(!plan.addCommandText.contains("-- /Users/a b/mtouch"))
    }

    @Test("the registered command is the absolute path of the running binary, unchanged")
    func registrationUsesHostExecutable() {
        let host = StubInitHost()
        host.executablePath = "/somewhere/else/mtouch"
        let outcome = InitPipeline.run(InitRequest(client: .mcpJSON), host: host)

        #expect(reportedText(outcome)?.contains("/somewhere/else/mtouch") == true)
    }
}
