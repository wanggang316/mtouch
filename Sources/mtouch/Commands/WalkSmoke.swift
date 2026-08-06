import ArgumentParser
import Foundation
import MTouchKit

/// DEV-ONLY smoke command for the AX tree walker. Hidden from `--help`
/// (`shouldDisplay: false`) and NOT one of the eight public subcommands. It
/// exists to manually exercise `AXTreeWalker` against a live app; production
/// snapshot output lands in the snapshot/textualizer features, not here.
struct WalkSmoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__walk-smoke",
        abstract: "DEV-ONLY: walk an app's AX tree and print a summary. Not a public command.",
        shouldDisplay: false
    )

    @OptionGroup var appOptions: RequiredAppOptions

    mutating func run() throws {
        preflightOrExit(Preflight.requireAccessibility)

        let pid: pid_t
        do {
            pid = try AXWindowEnumerator.resolveRunningPID(bundleId: appOptions.app)
        } catch let error as AppNotRunningError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            throw ExitCode(MTouchExitCode.runtimeFailure.rawValue)
        }

        let result = AXTreeWalker.walk(pid: pid)
        let all = result.nodes.flatMap(\.flattened)

        print("roots: \(result.nodes.count)")
        print("nodes: \(all.count)")
        print("actionable: \(all.filter(\.actionable).count)")
        print("fallbackFired: \(result.fallbackFired)  fallbackHelped: \(result.fallbackHelped)  truncated: \(result.truncated)")
        print("sample roles: " + all.prefix(12).map(\.role).joined(separator: ", "))
    }
}
