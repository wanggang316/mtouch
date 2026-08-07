import ArgumentParser
import Foundation
import MTouchKit

struct Windows: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List windows of an application."
    )

    @OptionGroup var appOptions: RequiredAppOptions

    @Flag(help: "Emit machine-readable JSON output.")
    var json = false

    /// The observable outcome, kept as a value so the recorder observes both the
    /// success and the failure paths (a bare `exit()` in the middle would bypass
    /// recording). Mirrors the pipeline commands' outcome/side-effect split.
    private enum Outcome {
        case listed(String)
        case failed(stderr: String, code: MTouchExitCode)
    }

    mutating func run() throws {
        let app = appOptions.app
        let jsonOutput = json
        let outcome = try recorded(
            command: "windows",
            args: TrajectoryArgs.build(["app": .string(app), "json": json ? .bool(true) : nil]),
            kind: .read,
            describe: { (outcome: Outcome) in
                switch outcome {
                case .listed:
                    return TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil)
                case let .failed(_, code):
                    return TrajectoryOutcomeInfo(ok: false, exit: code.rawValue, errorClass: code.trajectoryErrorClass)
                }
            }
        ) { () -> Outcome in
            // Preflight/resolve/enumerate/render live in the shared pipeline so the
            // CLI and MCP surfaces stay byte-for-byte in parity by construction.
            switch WindowsPipeline.run(bundleId: app, json: jsonOutput) {
            case let .listed(output):
                return .listed(output)
            case let .failed(stderr, code):
                return .failed(stderr: stderr, code: code)
            }
        }

        switch outcome {
        case let .listed(output):
            print(output)
        case let .failed(stderr, code):
            FileHandle.standardError.write(Data((stderr + "\n").utf8))
            throw ExitCode(code.rawValue)
        }
    }
}
