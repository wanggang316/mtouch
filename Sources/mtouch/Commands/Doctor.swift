import ArgumentParser
import MTouchKit

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report environment health and permission status."
    )

    @Flag(help: "Emit machine-readable JSON output.")
    var json = false

    mutating func run() throws {
        let report = DoctorReport(provider: LivePermissionProvider())
        if json {
            print(report.jsonString())
        } else {
            print(report.textLines().joined(separator: "\n"))
        }
        if report.exitCode != .success {
            throw ExitCode(report.exitCode.rawValue)
        }
    }
}
