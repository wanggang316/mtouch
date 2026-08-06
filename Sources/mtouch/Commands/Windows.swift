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

    mutating func run() throws {
        preflightOrExit(Preflight.requireAccessibility)

        let pid: pid_t
        do {
            pid = try AXWindowEnumerator.resolveRunningPID(bundleId: appOptions.app)
        } catch let error as AppNotRunningError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            throw ExitCode(MTouchExitCode.runtimeFailure.rawValue)
        }

        let windows = AXWindowEnumerator.windows(ofPID: pid)
        if json {
            print(WindowInfo.jsonArray(windows))
        } else if windows.isEmpty {
            // Zero windows is a success state; say so explicitly.
            print("no windows for \(appOptions.app)")
        } else {
            for window in windows {
                print(window.textLine)
            }
        }
    }
}
