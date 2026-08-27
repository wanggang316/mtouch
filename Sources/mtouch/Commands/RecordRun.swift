import ArgumentParser
import Foundation
import MTouchKit

/// DEV-ONLY blocking recorder. Hidden from `--help` (`shouldDisplay: false`) and
/// not one of the public subcommands: `mtouch record start` spawns it.
///
/// It is a separate command rather than a thread inside `record start` on
/// purpose. Blocking makes the recorder driveable straight from a shell —
/// `mtouch __record-run --out x.mp4` then Ctrl-C — which is the only way to
/// exercise capture and finalization without the process-management layer in the
/// way. Everything `record start|stop` does is management around this.
struct RecordRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: RecordRunCommand.name,
        abstract: "DEV-ONLY: record the screen until SIGINT/SIGTERM, then finalize. Not a public command.",
        shouldDisplay: false
    )

    @Option(help: ArgumentHelp("Destination movie path (H.264/MP4).", valueName: "path"))
    var out: String

    @Option(help: ArgumentHelp(
        "Control file to publish once capture is live. Defaults to record.json beside --out.",
        valueName: "path"
    ))
    var control: String?

    @Option(help: ArgumentHelp("CGDirectDisplayID to record. Omit for the main display.", valueName: "id"))
    var display: UInt32?

    @Option(help: ArgumentHelp(
        "Ceiling after which the recording finalizes by itself (default 10m, maximum 4h).",
        valueName: "duration"
    ))
    var maxDuration: String?

    mutating func validate() throws {
        guard !out.isEmpty else {
            throw ValidationError("--out value must not be empty; pass a file path.")
        }
        if let control, control.isEmpty {
            throw ValidationError("--control value must not be empty; pass a file path.")
        }
        if let maxDuration, RecordDuration(parsing: maxDuration) == nil {
            throw ValidationError(RecordDuration.usageMessage(maxDuration))
        }
    }

    mutating func run() throws {
        let controlPath = control ?? URL(fileURLWithPath: out)
            .deletingLastPathComponent()
            .appendingPathComponent(RecordPlan.controlFileName).path
        // The control file is deliberately LEFT BEHIND on exit. It is what lets a
        // recorder that finished on its own — reaching --max-duration, or dying —
        // still be resolved by `record stop`, which verifies the movie instead of
        // reporting "nothing was recording" over a file it never looked at.
        // `record stop` clears it once the recording's fate is settled.
        try emit(LiveScreenRecorder.run(
            output: out,
            controlPath: controlPath,
            display: display,
            maxDuration: maxDuration.flatMap(RecordDuration.init(parsing:)) ?? .default
        ))
    }
}
