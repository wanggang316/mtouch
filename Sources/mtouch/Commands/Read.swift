import ArgumentParser
import Foundation
import MTouchKit

struct Read: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Print the full text of a referenced element's subtree.",
        discussion: """
        Resolves <ref> against the current snapshot session and prints every string \
        its subtree carries, in document order, one logical block per line. The \
        output is NEVER truncated — unlike 'mtouch snapshot', which renders one line \
        per node under a node budget and drops non-actionable nodes (a long block of \
        static text) first.

        Reading changes nothing: no window is activated, no input is sent, and the \
        session's references are left exactly as they were.

        Secure-field values are masked here exactly as in every other surface.

        Exit codes: 0 text printed; 3 the reference is stale or there is no session; \
        1 the application is no longer running; 2 Accessibility not granted; \
        64 the argument is not a reference.
        """
    )

    @Argument(help: ArgumentHelp("Element reference from a prior snapshot.", valueName: "ref"))
    var ref: String

    @Flag(help: "Emit the text as machine-readable JSON.")
    var json = false

    mutating func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let outcome = try recorded(
            command: "read",
            args: TrajectoryArgs.build([
                "ref": .string(ref),
                "json": json ? .bool(true) : nil,
            ]),
            kind: .read,
            describe: { (outcome: ReadOutcome) in outcome.trajectoryInfo }
        ) {
            ReadPipeline.run(ref: ref, json: json, environment: environment)
        }

        switch outcome {
        case let .read(output):
            print(output)
        case let .failed(stderr, code):
            FileHandle.standardError.write(Data((stderr + "\n").utf8))
            throw ExitCode(code.rawValue)
        }
    }
}
