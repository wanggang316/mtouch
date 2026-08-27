import ArgumentParser
import MTouchKit

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report environment health and permission status."
    )

    @Flag(help: "Emit machine-readable JSON output.")
    var json = false

    @OptionGroup var runOptions: RunOptions

    mutating func run() throws {
        let jsonOutput = json
        // Doctor always produces its report (a read); the exit code reflects
        // permission health, so the record's outcome carries it.
        let report = try recorded(
            command: "doctor",
            args: TrajectoryArgs.build(["json": json ? .bool(true) : nil]),
            kind: .read,
            run: runOptions,
            describe: { (report: DoctorReport) in
                let code = report.exitCode
                return TrajectoryOutcomeInfo(
                    ok: code == .success, exit: code.rawValue, errorClass: code.trajectoryErrorClass
                )
            }
        ) { () -> DoctorReport in
            let report = DoctorReport(provider: LivePermissionProvider())
            if jsonOutput {
                print(report.jsonString())
            } else {
                print(report.textLines().joined(separator: "\n"))
            }
            return report
        }
        if report.exitCode != .success {
            throw ExitCode(report.exitCode.rawValue)
        }
    }
}
