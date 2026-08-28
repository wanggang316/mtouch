import Foundation

/// A short, already-phrased reason an onboarding step could not be carried out.
/// Mirrors `RecordFailure`: the caller's only job is to print it.
public struct InitFailure: Error, Equatable, Sendable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// What running a client's CLI produced. Output is stdout and stderr merged: the
/// clients mix diagnostics across both, and mtouch only ever quotes the text back.
public struct InitCommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// What `mtouch init` asks for.
public struct InitRequest: Equatable, Sendable {
    /// nil means DISCOVERY: list the clients and change nothing.
    public let client: InitClient?
    /// Render the plan instead of carrying it out.
    public let printOnly: Bool
    /// Replace an existing entry (or instructions file) that differs.
    public let force: Bool
    /// Destination for the agent instructions, overriding the client default.
    public let out: String?

    public init(client: InitClient?, printOnly: Bool = false, force: Bool = false, out: String? = nil) {
        self.client = client
        self.printOnly = printOnly
        self.force = force
        self.out = out
    }
}

/// The observable outcome of `mtouch init`, kept SEPARATE from printing and
/// exiting so the whole flow is unit-testable — the shape `RecordPipeline` uses.
public enum InitOutcome: Equatable, Sendable {
    case reported(stdout: String, notes: [String])
    case failed(stderr: String, code: MTouchExitCode)

    public static func reported(_ stdout: String) -> InitOutcome {
        .reported(stdout: stdout, notes: [])
    }
}

/// The syscall-shaped collaborators `InitPipeline` needs: this process's own
/// identity, PATH lookup, spawning the client's CLI, and the filesystem.
/// Isolating them behind one protocol is what lets every DECISION — discover,
/// register, recognise, refuse, replace — be tested without spawning anything or
/// touching a real configuration.
public protocol InitHost {
    /// Absolute path of the mtouch binary now running. This is what gets
    /// registered, so it must be resolved, not assumed.
    var executablePath: String { get }
    /// The user's home directory, for the client-owned default instructions path.
    var homeDirectory: String { get }
    /// Absolute path of `tool` on PATH, or nil when it is not installed.
    func locate(_ tool: String) -> String?
    /// Run `executable` with `arguments` — never through a shell — and capture
    /// its status and merged output.
    func run(_ executable: String, _ arguments: [String]) -> Result<InitCommandResult, InitFailure>
    /// Contents of `path`, or nil when it does not exist or cannot be read.
    func readFile(_ path: String) -> String?
    /// Write `contents` to `path`, creating parent directories.
    func writeFile(_ contents: String, to path: String) -> Result<Void, InitFailure>
}

/// Composes `mtouch init` on top of `InitHost`.
///
/// Two rules shape the whole flow:
///
/// 1. **Nothing mutates until every conflict is known.** The client CLI is
///    located and probed, and the instructions file is read, BEFORE the first add
///    or write. A run that is going to be refused must be refused having done
///    nothing — a half-registered client is worse than an unregistered one,
///    because it looks finished.
/// 2. **An existing entry that differs is never silently replaced.** It is
///    described, both sides quoted, and `--force` is required. The one thing an
///    operator cannot recover from is a configuration that changed without
///    saying so.
public enum InitPipeline {
    public static func run(_ request: InitRequest, host: InitHost) -> InitOutcome {
        guard let client = request.client else {
            // Discovery runs NOTHING and reads nothing: the one invocation an
            // operator makes before they have decided anything must be the
            // safest one in the command.
            return .reported(discoveryText())
        }
        let plan = InitPlan(
            client: client,
            binary: host.executablePath,
            home: host.homeDirectory,
            out: request.out
        )
        if request.printOnly {
            // A dry run that probed would need the client installed to print the
            // command for installing the client. It renders the PLAN, nothing else.
            return .reported(dryRunText(plan))
        }
        switch client {
        case .claude:
            return registerWithClaude(plan: plan, force: request.force, host: host)
        case .mcpJSON:
            return emitGenericEntry(plan: plan, force: request.force, host: host)
        }
    }

    // MARK: - Discovery

    static func discoveryText() -> String {
        var lines = [
            "mtouch init registers this binary as an MCP server with an agent client",
            "and installs the mtouch usage instructions for it.",
            "",
            "Nothing has been changed. Choose a client:",
            "",
        ]
        for client in InitClient.allCases {
            lines.append("  --client \(client.rawValue)   (\(client.displayName))")
            lines.append(contentsOf: client.summaryLines.map { "      \($0)" })
            lines.append("")
        }
        lines.append(contentsOf: [
            "Add --print to see exactly what would be run and written, without doing it.",
            "An entry that already matches is left alone; one that differs needs --force.",
        ])
        return lines.joined(separator: "\n")
    }

    // MARK: - Dry run

    static func dryRunText(_ plan: InitPlan) -> String {
        var lines: [String] = []
        switch plan.client {
        case .claude:
            lines.append("# would run (nothing has been run):")
            lines.append(plan.addCommandText)
            lines.append("")
            lines.append("# an entry that already matches is left alone; one that differs needs --force.")
        case .mcpJSON:
            lines.append("# would print this MCP server entry (it writes nothing either way):")
            lines.append(plan.mcpServerEntryJSON)
        }
        if let path = plan.instructionsPath {
            lines.append("")
            lines.append("# would write \(path) (nothing has been written):")
            lines.append("")
            lines.append(AgentInstructions.text)
        } else {
            lines.append("")
            lines.append("# no agent instructions file: pass --out <path> to write one.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Claude Code

    private static func registerWithClaude(plan: InitPlan, force: Bool, host: InitHost) -> InitOutcome {
        guard let executable = host.locate(ClaudeClient.cli) else {
            return .failed(stderr: missingClientText(plan), code: .runtimeFailure)
        }

        let existing: ClaudeEntry?
        switch host.run(executable, ClaudeClient.getArguments(plan.registration.name)) {
        case let .failure(failure):
            return .failed(
                stderr: "mtouch: could not ask \(plan.client.displayName) about its MCP servers: \(failure.reason). "
                    + "Nothing was registered and nothing was written.",
                code: .runtimeFailure
            )
        case let .success(result):
            // A non-zero status is how this client says "no such server". It is
            // the ONLY reading that leaves the command able to register at all,
            // and a genuinely broken client fails again on the add, loudly.
            existing = result.status == 0 ? ClaudeEntry.parse(result.output) : nil
        }

        let instructions = instructionsStep(plan: plan, host: host)

        // Every refusal is collected BEFORE the first mutation, so a conflicting
        // instructions file cannot leave a registration behind it.
        var conflicts: [String] = []
        if let existing, !existing.matches(plan.registration), !force {
            conflicts.append(registrationConflictText(existing: existing, plan: plan))
        }
        if case let .replace(path, _) = instructions, !force {
            conflicts.append(instructionsConflictText(path: path))
        }
        guard conflicts.isEmpty else {
            return .failed(
                stderr: conflicts.joined(separator: "\n\n") + "\n\nNothing was changed.",
                code: .runtimeFailure
            )
        }

        var lines: [String] = []
        var notes: [String] = []

        if let existing, existing.matches(plan.registration) {
            lines.append(
                "'\(plan.registration.name)' is already registered with \(plan.client.displayName): "
                    + "\(existing.summaryText) — left alone."
            )
        } else {
            if let existing {
                notes.append(
                    "mtouch: replacing the existing '\(plan.registration.name)' entry "
                        + "(\(existing.summaryText)) because --force was given."
                )
                if case let .failure(failure) = removeExisting(plan: plan, executable: executable, host: host) {
                    return .failed(stderr: failure.reason, code: .runtimeFailure)
                }
            }
            switch host.run(executable, ClaudeClient.addArguments(plan.registration)) {
            case let .failure(failure):
                return .failed(
                    stderr: "mtouch: could not run \(ClaudeClient.cli): \(failure.reason)\n"
                        + "Register mtouch yourself with:\n  \(plan.addCommandText)",
                    code: .runtimeFailure
                )
            case let .success(result) where result.status != 0:
                return .failed(
                    stderr: "mtouch: \(plan.client.displayName) refused the registration "
                        + "(exit \(result.status)):\n\(indented(result.output))\n"
                        + "The command that was run:\n  \(plan.addCommandText)",
                    code: .runtimeFailure
                )
            case .success:
                lines.append(
                    "registered '\(plan.registration.name)' with \(plan.client.displayName) at "
                        + "\(ClaudeClient.scope) scope: \(plan.registration.commandText)"
                )
            }
        }

        switch applyInstructions(instructions, host: host) {
        case let .failure(failure):
            return .failed(stderr: failure.reason, code: .runtimeFailure)
        case let .success(line):
            if let line { lines.append(line) }
        }

        lines.append(
            "Start a new \(plan.client.displayName) session to pick up the server; "
                + "'\(ClaudeClient.commandText(ClaudeClient.getArguments(plan.registration.name)))' shows its status."
        )
        return .reported(stdout: lines.joined(separator: "\n"), notes: notes)
    }

    private static func removeExisting(
        plan: InitPlan, executable: String, host: InitHost
    ) -> Result<Void, InitFailure> {
        // This client refuses an `add` over an existing name, so replacing means
        // removing first. A failed remove aborts BEFORE the add, so the entry the
        // operator already had is never lost to a half-applied replacement.
        let arguments = ClaudeClient.removeArguments(plan.registration.name)
        switch host.run(executable, arguments) {
        case let .failure(failure):
            return .failure(InitFailure(
                "mtouch: could not run \(ClaudeClient.cli): \(failure.reason)\n"
                    + "The existing entry is unchanged."
            ))
        case let .success(result) where result.status != 0:
            return .failure(InitFailure(
                "mtouch: \(plan.client.displayName) would not remove the existing "
                    + "'\(plan.registration.name)' entry (exit \(result.status)):\n\(indented(result.output))\n"
                    + "The existing entry is unchanged. Remove it yourself with:\n"
                    + "  \(ClaudeClient.commandText(arguments))"
            ))
        case .success:
            return .success(())
        }
    }

    // MARK: - Generic MCP entry

    private static func emitGenericEntry(plan: InitPlan, force: Bool, host: InitHost) -> InitOutcome {
        let instructions = instructionsStep(plan: plan, host: host)
        if case let .replace(path, _) = instructions, !force {
            return .failed(
                stderr: instructionsConflictText(path: path) + "\n\nNothing was changed.",
                code: .runtimeFailure
            )
        }

        var lines = [plan.mcpServerEntryJSON]
        switch applyInstructions(instructions, host: host) {
        case let .failure(failure):
            return .failed(stderr: failure.reason, code: .runtimeFailure)
        case let .success(line):
            if let line {
                lines.append(line)
            } else {
                lines.append(
                    "Agent instructions: 'mtouch init --client \(plan.client.rawValue) --out <path>' writes them, "
                        + "'--print' shows them."
                )
            }
        }
        return .reported(lines.joined(separator: "\n"))
    }

    // MARK: - The instructions file

    /// What would happen to the agent instructions file, decided from a READ.
    enum InstructionsStep: Equatable {
        /// This client has nowhere mtouch may write and `--out` named nowhere.
        case skip
        case create(path: String)
        case upToDate(path: String)
        /// Present with different content: an older mtouch wrote it, or a person did.
        case replace(path: String, existingLength: Int)
    }

    static func instructionsStep(plan: InitPlan, host: InitHost) -> InstructionsStep {
        guard let path = plan.instructionsPath else { return .skip }
        guard let current = host.readFile(path) else { return .create(path: path) }
        return current == AgentInstructions.text
            ? .upToDate(path: path)
            : .replace(path: path, existingLength: current.count)
    }

    /// Carries out `step`, returning the stdout line it earned (nil when there is
    /// nothing to say).
    private static func applyInstructions(
        _ step: InstructionsStep, host: InitHost
    ) -> Result<String?, InitFailure> {
        switch step {
        case .skip:
            return .success(nil)
        case let .upToDate(path):
            return .success("agent instructions already up to date at \(path)")
        case let .create(path), let .replace(path, _):
            switch host.writeFile(AgentInstructions.text, to: path) {
            case let .failure(failure):
                return .failure(InitFailure(
                    "mtouch: could not write the agent instructions to \(path): \(failure.reason)"
                ))
            case .success:
                return .success("wrote agent instructions to \(path)")
            }
        }
    }

    // MARK: - Diagnostics

    /// The client CLI is missing. Printing the exact command mtouch WOULD have
    /// run is the whole point: an operator who installs the client later, or who
    /// registers by hand, needs the identical absolute path — retyping it from
    /// memory is how a broken registration gets made.
    static func missingClientText(_ plan: InitPlan) -> String {
        var lines = [
            "mtouch: the \(plan.client.displayName) CLI ('\(ClaudeClient.cli)') is not on PATH, so NOTHING "
                + "was registered and no files were written.",
            "Install it and re-run 'mtouch init --client \(plan.client.rawValue)', or register mtouch "
                + "yourself with the exact command this would have run:",
            "  \(plan.addCommandText)",
        ]
        if let path = plan.instructionsPath {
            lines.append(
                "The agent instructions for \(path) are printed by "
                    + "'mtouch init --client \(plan.client.rawValue) --print'."
            )
        }
        return lines.joined(separator: "\n")
    }

    static func registrationConflictText(existing: ClaudeEntry, plan: InitPlan) -> String {
        [
            "mtouch: an MCP server named '\(plan.registration.name)' is already registered with "
                + "\(plan.client.displayName), and it is NOT this binary:",
            "  registered: \(existing.summaryText)",
            "  this run:   \(plan.registration.commandText)",
            "Re-run with --force to replace it, or remove it yourself with:",
            "  \(ClaudeClient.commandText(ClaudeClient.removeArguments(plan.registration.name)))",
        ].joined(separator: "\n")
    }

    static func instructionsConflictText(path: String) -> String {
        [
            "mtouch: \(path) already exists with different content — an older mtouch wrote it, "
                + "or it has been edited.",
            "Re-run with --force to overwrite it, or pass --out <path> to write elsewhere.",
        ].joined(separator: "\n")
    }

    private static func indented(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}
