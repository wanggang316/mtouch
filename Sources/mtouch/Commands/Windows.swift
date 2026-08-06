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
            do {
                try Preflight.requireAccessibility()
            } catch let error as PermissionError {
                return .failed(stderr: error.diagnostic, code: .permissionMissing)
            } catch {
                return .failed(stderr: "mtouch: preflight failed: \(error)", code: .runtimeFailure)
            }

            let pid: pid_t
            do {
                pid = try AXWindowEnumerator.resolveRunningPID(bundleId: app)
            } catch let error as AppNotRunningError {
                return .failed(stderr: error.message, code: .runtimeFailure)
            } catch {
                return .failed(stderr: "mtouch: could not resolve application '\(app)': \(error)", code: .runtimeFailure)
            }

            let windows = AXWindowEnumerator.windows(ofPID: pid)
            if jsonOutput {
                return .listed(WindowInfo.jsonArray(windows))
            } else if windows.isEmpty {
                // Zero windows is a success state; say so explicitly.
                return .listed("no windows for \(app)")
            } else {
                return .listed(windows.map(\.textLine).joined(separator: "\n"))
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
