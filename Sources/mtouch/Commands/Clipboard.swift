import ArgumentParser
import Foundation
import MTouchKit

struct Clipboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "Read, write, or clear the clipboard.",
        discussion: """
        Gives an agent a reliable way to move text in and out of applications whose \
        text areas are not addressable over the accessibility API: put the text on \
        the clipboard, then paste it with 'mtouch act key cmd+v'.

        Every write is READ BACK and verified, because a pasteboard write can be \
        refused or dropped silently — and a paste after a write that did not take \
        would paste the PREVIOUS contents, which looks exactly like success.

        Text only in this version. Non-text contents (images, files) are reported by \
        type rather than shown as an empty clipboard.
        """,
        subcommands: [
            Get.self,
            SetText.self,
            Clear.self,
        ]
    )

    mutating func run() throws {
        // Bare `mtouch clipboard` is a usage error (exit 64), not a help request.
        throw ValidationError("Missing verb. See 'mtouch clipboard --help' for the list of verbs.")
    }
}

/// Maps a `ClipboardOutcome` to stdout/stderr + exit code. `.rendered(nil)` is a
/// SILENT success: a confirmed write says so with exit 0, not with chatter that a
/// caller would have to parse around.
private func emit(_ outcome: ClipboardOutcome) throws {
    switch outcome {
    case let .rendered(output):
        if let output { print(output) }
    case let .failed(stderr, code):
        FileHandle.standardError.write(Data((stderr + "\n").utf8))
        throw ExitCode(code.rawValue)
    }
}

extension Clipboard {
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Print the clipboard's text.",
            discussion: """
            An empty clipboard prints nothing and exits 0 — empty is a truthful \
            answer. A clipboard holding only NON-text content exits 1 and names the \
            types that are there, so it can never be mistaken for an empty one.

            --json also reports "changeCount", the system counter that increments on \
            every write by any process: capture it, and a later read tells you whether \
            something else overwrote the clipboard in between.
            """
        )

        @Flag(help: "Emit machine-readable JSON output.")
        var json = false

        @OptionGroup var runOptions: RunOptions

        mutating func run() throws {
            let jsonOutput = json
            let outcome = try recorded(
                command: "clipboard",
                args: TrajectoryArgs.build([
                    "action": .string("get"),
                    "json": jsonOutput ? .bool(true) : nil,
                ]),
                kind: .read,
                run: runOptions,
                describe: { (outcome: ClipboardOutcome) in outcome.trajectoryInfo }
            ) {
                ClipboardPipeline.get(json: jsonOutput)
            }
            try emit(outcome)
        }
    }

    struct SetText: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Put text on the clipboard, verifying the round trip.",
            discussion: """
            Pass the text as an argument, or --stdin to read it from standard input. \
            Standard input is used VERBATIM (a trailing newline from 'echo' is kept), \
            and must be valid UTF-8.

            The text is never echoed back and is never written to a trajectory record: \
            a clipboard is a common carrier for credentials.
            """
        )

        @Argument(help: ArgumentHelp("Text to put on the clipboard.", valueName: "text"))
        var text: String?

        @Flag(help: "Read the text from standard input instead of the argument.")
        var stdin = false

        @Flag(help: "Emit machine-readable JSON output.")
        var json = false

        @OptionGroup var runOptions: RunOptions

        mutating func validate() throws {
            if text == nil, !stdin {
                throw ValidationError("Provide the text to copy, or pass --stdin to read it from standard input.")
            }
            if text != nil, stdin {
                throw ValidationError("Pass either <text> or --stdin, not both.")
            }
        }

        mutating func run() throws {
            let payload: String
            if stdin {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let decoded = String(data: data, encoding: .utf8) else {
                    // Silently substituting replacement characters would put corrupted
                    // text on the clipboard, so a non-UTF-8 stream is refused instead.
                    FileHandle.standardError.write(Data(
                        ("mtouch: standard input is not valid UTF-8 text; only text can be copied.\n").utf8
                    ))
                    throw ExitCode(MTouchExitCode.usageError.rawValue)
                }
                payload = decoded
            } else {
                payload = text ?? ""
            }

            let jsonOutput = json
            let outcome = try recorded(
                command: "clipboard",
                args: TrajectoryArgs.build([
                    "action": .string("set"),
                    // The payload itself is deliberately NOT recorded (see the
                    // discussion above); its size is enough to reconstruct the step.
                    "bytes": .int(payload.utf8.count),
                    "stdin": stdin ? .bool(true) : nil,
                    "json": jsonOutput ? .bool(true) : nil,
                ]),
                kind: .action,
                run: runOptions,
                describe: { (outcome: ClipboardOutcome) in outcome.trajectoryInfo }
            ) {
                ClipboardPipeline.set(text: payload, json: jsonOutput)
            }
            try emit(outcome)
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Empty the clipboard."
        )

        @Flag(help: "Emit machine-readable JSON output.")
        var json = false

        @OptionGroup var runOptions: RunOptions

        mutating func run() throws {
            let jsonOutput = json
            let outcome = try recorded(
                command: "clipboard",
                args: TrajectoryArgs.build([
                    "action": .string("clear"),
                    "json": jsonOutput ? .bool(true) : nil,
                ]),
                kind: .action,
                run: runOptions,
                describe: { (outcome: ClipboardOutcome) in outcome.trajectoryInfo }
            ) {
                ClipboardPipeline.clear(json: jsonOutput)
            }
            try emit(outcome)
        }
    }
}
