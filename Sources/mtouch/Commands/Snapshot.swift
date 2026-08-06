import ArgumentParser
import Foundation
import MTouchKit

struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Capture an accessibility snapshot of an application."
    )

    @OptionGroup var appOptions: RequiredAppOptions

    @Flag(help: "Emit machine-readable JSON output.")
    var json = false

    mutating func run() throws {
        // The whole flow (preflight → resolve → walk → enrich → render → persist)
        // lives in `SnapshotPipeline` as a testable value; this command only
        // executes the outcome. A failure prints to stderr and exits non-zero,
        // never to stdout — so `--json` errors keep stdout clean.
        let environment = ProcessInfo.processInfo.environment
        let outcome = try recorded(
            command: "snapshot",
            args: TrajectoryArgs.build(["app": .string(appOptions.app), "json": json ? .bool(true) : nil]),
            kind: .snapshot,
            describe: { (outcome: SnapshotOutcome) in outcome.trajectoryInfo }
        ) {
            SnapshotPipeline.run(bundleId: appOptions.app, json: json, environment: environment)
        }
        switch outcome {
        case let .rendered(output):
            print(output)
        case let .failed(stderr, code):
            FileHandle.standardError.write(Data((stderr + "\n").utf8))
            throw ExitCode(code.rawValue)
        }
    }
}
