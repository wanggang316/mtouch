import ArgumentParser
import Foundation
import MTouchKit

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Register mtouch with an agent client and install its usage instructions.",
        discussion: """
        Wires this binary into an agent client as an MCP server, and writes the \
        mtouch operating instructions — the perceive/act/verify loop, criteria \
        addressing, the exit-code taxonomy, the evidence qualifiers — where the \
        client can load them. Those instructions are EMBEDDED in the binary, so an \
        installed mtouch onboards a client with no repository present.

        With no --client it LISTS the clients and exits, having changed nothing. \
        --print renders exactly what would be run and written, and also changes \
        nothing: run it first.

        Safe to run twice. The registered command is the ABSOLUTE path of the \
        binary you invoked, so a Homebrew install and a locally built one register \
        distinctly. An existing entry that already matches is left alone (exit 0); \
        one that DIFFERS is reported with both sides quoted and requires --force — \
        mtouch does not rewrite a configuration without saying so. Every conflict \
        is detected before the first change, so a refused run leaves nothing \
        half-applied.
        """
    )

    @Option(help: ArgumentHelp(
        "Agent client to register with: \(InitClient.names.joined(separator: ", ")). "
            + "Omit it to list the clients and exit without changing anything.",
        valueName: "name"
    ))
    var client: String?

    @Flag(name: .customLong("print"), help: ArgumentHelp(
        "Render the commands and the instructions file that would be produced, to stdout, "
            + "and change nothing. Runs no client commands and writes no files."
    ))
    var printOnly = false

    @Flag(help: ArgumentHelp(
        "Replace an existing registration, or an existing instructions file, whose content differs. "
            + "Without it, a difference is reported and nothing is changed."
    ))
    var force = false

    @Option(help: ArgumentHelp(
        "Write the agent instructions to this path instead of the client's default location.",
        valueName: "path"
    ))
    var out: String?

    mutating func validate() throws {
        if let client, InitClient(rawValue: client) == nil {
            throw ValidationError(
                "unknown --client '\(client)'; expected one of \(InitClient.names.joined(separator: ", ")). "
                    + "Run 'mtouch init' with no options to see what each one does."
            )
        }
        if let out, out.isEmpty {
            throw ValidationError("--out value must not be empty; pass a file path.")
        }
        // Each of these would otherwise be a silent no-op against a listing that
        // changes nothing — the same refusal `--capture` makes without a run
        // directory.
        if client == nil {
            let stray = [
                printOnly ? "--print" : nil,
                force ? "--force" : nil,
                out != nil ? "--out" : nil,
            ].compactMap { $0 }
            if let flag = stray.first {
                throw ValidationError(
                    "\(flag) needs a --client to act on; 'mtouch init' with no --client only lists them."
                )
            }
        }
        if printOnly, force {
            throw ValidationError("--force has nothing to force alongside --print, which changes nothing.")
        }
    }

    mutating func run() throws {
        let request = InitRequest(
            client: client.flatMap(InitClient.init(rawValue:)),
            printOnly: printOnly,
            force: force,
            out: out
        )
        switch InitPipeline.run(request, host: LiveInitHost()) {
        case let .reported(stdout, notes):
            for note in notes {
                FileHandle.standardError.write(Data((note + "\n").utf8))
            }
            print(stdout)
        case let .failed(stderr, code):
            FileHandle.standardError.write(Data((stderr + "\n").utf8))
            throw ExitCode(code.rawValue)
        }
    }
}
