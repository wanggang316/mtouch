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
        // Process enumeration via NSWorkspace is not TCC-gated: no preflight.
        let apps = RunningAppInfo.currentRegularApps()
        if json {
            print(RunningAppInfo.jsonArray(apps))
        } else {
            for app in apps {
                print(app.textLine)
            }
        }
    }
}
