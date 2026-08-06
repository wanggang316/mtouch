import ArgumentParser
import MTouchKit

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "List running applications."
    )

    @Flag(help: "Emit machine-readable JSON output.")
    var json = false

    mutating func run() throws {
        // Process enumeration via NSWorkspace is not TCC-gated: no preflight. apps
        // has no failure path, so its record is always a clean read.
        let jsonOutput = json
        try recorded(
            command: "apps",
            args: TrajectoryArgs.build(["json": json ? .bool(true) : nil]),
            kind: .read,
            describe: { (_: Void) in TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil) }
        ) {
            let apps = RunningAppInfo.currentRegularApps()
            if jsonOutput {
                print(RunningAppInfo.jsonArray(apps))
            } else {
                for app in apps {
                    print(app.textLine)
                }
            }
        }
    }
}
