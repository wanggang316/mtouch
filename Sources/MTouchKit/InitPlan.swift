import Foundation

/// The agent clients `mtouch init` knows how to onboard.
///
/// A client is either DRIVEN (mtouch runs the client's own registration CLI) or
/// DESCRIBED (mtouch prints an entry the operator pastes). Nothing in between:
/// hand-editing a client's configuration file is the failure mode this enum
/// exists to avoid, because the client owns that format and may change it.
public enum InitClient: String, CaseIterable, Sendable {
    /// The Claude Code CLI, registered through `claude mcp add`.
    case claude
    /// Any MCP client: emit a server entry to paste, touching nothing.
    case mcpJSON = "mcp-json"

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .mcpJSON: "generic MCP client"
        }
    }

    /// The discovery listing's description of what this client WOULD do,
    /// pre-wrapped so the listing reads in a narrow terminal.
    public var summaryLines: [String] {
        switch self {
        case .claude:
            [
                "Registers the MCP server by running '\(ClaudeClient.cli) mcp add', and writes",
                "the mtouch agent instructions into the client's own directory.",
            ]
        case .mcpJSON:
            [
                "Prints an MCP server entry to paste into any client's configuration.",
                "Writes nothing.",
            ]
        }
    }

    /// Accepted `--client` values, for a usage error that names them.
    public static var names: [String] { allCases.map(\.rawValue) }
}

// MARK: - The registration itself

/// The MCP server entry mtouch registers for itself.
///
/// `command` is the ABSOLUTE path of the running binary, never the bare name:
/// the client resolves this string in its OWN environment, and a Homebrew
/// install, a `swift build` product, and a checked-out tree are three different
/// binaries. A bare `mtouch` that happens not to be on the client's PATH
/// produces a registration that fails much later, at a moment that looks nothing
/// like a mis-registration.
public struct InitRegistration: Equatable, Sendable {
    /// The server name inside the client. Fixed: two mtouch entries under
    /// different names would defeat the whole idempotency story.
    public static let serverName = "mtouch"

    public let name: String
    public let command: String
    public let arguments: [String]

    public init(name: String = InitRegistration.serverName, command: String, arguments: [String] = ["mcp"]) {
        self.name = name
        self.command = command
        self.arguments = arguments
    }

    /// How the entry reads in a diagnostic: `"/usr/local/bin/mtouch mcp"`.
    public var commandText: String {
        ShellCommandLine.render([command] + arguments)
    }
}

// MARK: - Claude Code specifics

/// Everything mtouch knows about driving the Claude Code CLI.
public enum ClaudeClient {
    /// The executable looked up on PATH. Never invoked through a shell.
    public static let cli = "claude"

    /// `user` scope, stated explicitly rather than relying on the client's
    /// default (`local`, which is private to the current directory). mtouch is a
    /// machine-wide tool: registering it only for whichever directory the
    /// operator happened to be standing in is a surprise that surfaces as "the
    /// tool disappeared" in the next project. The scope is visible in `--print`
    /// and in the command echoed on failure, so it is never a hidden choice.
    public static let scope = "user"

    public static func addArguments(_ registration: InitRegistration) -> [String] {
        ["mcp", "add", "--scope", scope, registration.name, "--"] + [registration.command] + registration.arguments
    }

    public static func removeArguments(_ name: String) -> [String] {
        // No `--scope`: the entry being replaced may live in any scope, and the
        // client resolves that itself. Pinning a scope here would turn "replace
        // the entry I just found" into "fail to find it".
        ["mcp", "remove", name]
    }

    public static func getArguments(_ name: String) -> [String] {
        ["mcp", "get", name]
    }

    /// The human-pasteable form of a command mtouch would run.
    public static func commandText(_ arguments: [String]) -> String {
        ShellCommandLine.render([cli] + arguments)
    }

    /// Where the agent instructions go by default: inside the directory the
    /// CLIENT owns, under a name only mtouch uses. Deliberately NOT the client's
    /// own instruction file — appending to or replacing a file the operator
    /// writes in is exactly the silent config rewriting this command refuses.
    public static func instructionsPath(home: String) -> String {
        (home as NSString).appendingPathComponent(".claude/\(AgentInstructions.fileName)")
    }
}

/// What the client reports for an existing server of a given name.
public enum ClaudeEntry: Equatable, Sendable {
    /// A stdio server: the shape mtouch registers.
    case stdio(command: String, arguments: [String])
    /// Anything else (an HTTP/SSE server, or output this binary cannot read).
    /// Kept as a summary rather than discarded so the conflict can be DESCRIBED —
    /// "something else already owns this name" is only actionable if it says what.
    case other(summary: String)

    /// Whether this entry is already exactly what `mtouch init` would register.
    public func matches(_ registration: InitRegistration) -> Bool {
        guard case let .stdio(command, arguments) = self else { return false }
        return command == registration.command && arguments == registration.arguments
    }

    /// How the entry reads in a diagnostic.
    public var summaryText: String {
        switch self {
        case let .stdio(command, arguments): ShellCommandLine.render([command] + arguments)
        case let .other(summary): summary
        }
    }

    /// Reads `claude mcp get <name>`'s report, which lists one `Key: value` per
    /// indented line:
    ///
    ///     mtouch:
    ///       Scope: User config
    ///       Status: ✔ Connected
    ///       Type: stdio
    ///       Command: /usr/local/bin/mtouch
    ///       Args: mcp
    ///
    /// Anything it cannot read as a stdio entry becomes `.other`, never a false
    /// `.stdio` — mis-reading an entry as "matches" would silently skip a
    /// registration that needed replacing.
    public static func parse(_ output: String) -> ClaudeEntry {
        var type: String?
        var command: String?
        var arguments: [String] = []
        var url: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = field("Type", in: line) { type = value }
            else if let value = field("Command", in: line) { command = value }
            else if let value = field("Args", in: line) { arguments = value.split(separator: " ").map(String.init) }
            else if let value = field("URL", in: line) { url = value }
        }

        // A `Command` with no `Type` line still identifies a stdio server; a
        // `Type` that says otherwise never does, whatever else was parsed.
        if type == nil || type == "stdio", let command, !command.isEmpty {
            return .stdio(command: command, arguments: arguments)
        }
        if let url, !url.isEmpty {
            return .other(summary: "\(type ?? "remote") server at \(url)")
        }
        return .other(summary: type.map { "a \($0) server" } ?? "an entry mtouch could not read")
    }

    private static func field(_ key: String, in line: String) -> String? {
        let prefix = key + ":"
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Command rendering

/// Renders an argument vector as a line an operator can paste into a shell.
///
/// mtouch NEVER runs a command through a shell — arguments go to `posix_spawn`
/// as a vector — so this quoting exists only for the printed form. It still has
/// to be right: the absolute path of the binary is the thing being printed, and
/// an unquoted path with a space in it is a command that silently does something
/// else when pasted.
enum ShellCommandLine {
    static func render(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    static func quote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        if argument.unicodeScalars.allSatisfy(isShellSafe) { return argument }
        // Single quotes protect everything except a single quote, which is
        // closed, escaped, and reopened — the portable POSIX form.
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A conservative allow-list: anything outside it gets quoted. Non-ASCII is
    /// deliberately excluded — a path with CJK characters is safe in practice but
    /// quoting it costs nothing and removes the question.
    private static func isShellSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": true
        case "_", "-", ".", "/", ":", "=", "@", "+", ",": true
        default: false
        }
    }
}

// MARK: - The plan

/// Everything `mtouch init` would do for one client, decided BEFORE anything is
/// run or written. `--print` renders exactly this, which is what makes the dry
/// run trustworthy: there is no second code path that could disagree with it.
public struct InitPlan: Equatable, Sendable {
    public let client: InitClient
    public let registration: InitRegistration
    /// Where the agent instructions would be written, or nil when this client has
    /// no place mtouch may write and `--out` named none.
    public let instructionsPath: String?

    public init(client: InitClient, binary: String, home: String, out: String?) {
        self.client = client
        self.registration = InitRegistration(command: binary)
        self.instructionsPath = switch (out, client) {
        case let (out?, _): out
        case (nil, .claude): ClaudeClient.instructionsPath(home: home)
        case (nil, .mcpJSON): nil
        }
    }

    /// The `claude mcp add …` line, as a human would type it.
    public var addCommandText: String {
        ClaudeClient.commandText(ClaudeClient.addArguments(registration))
    }

    /// A generic MCP server entry, in the `mcpServers` shape every client's
    /// documentation uses for a paste. Hand-built, sorted keys, two-space indent
    /// (project pattern: stable bytes, no JSONEncoder ordering surprises).
    public var mcpServerEntryJSON: String {
        let args = registration.arguments.map { "        \(JSONText.string($0))" }.joined(separator: ",\n")
        return """
        {
          "mcpServers": {
            \(JSONText.string(registration.name)): {
              "args": [
        \(args)
              ],
              "command": \(JSONText.string(registration.command))
            }
          }
        }
        """
    }
}
