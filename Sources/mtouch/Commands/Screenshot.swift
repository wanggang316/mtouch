import ArgumentParser
import Foundation
import MTouchKit

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot of the screen or a window.",
        discussion: """
        Captures the main display, or a single window when --window is given, to a
        PNG via ScreenCaptureKit. The bytes are ALWAYS PNG regardless of the --out
        extension (e.g. --out shot.jpg still writes PNG). Without --out, a
        timestamped file is written in the current directory and its path is
        printed. Requires the Screen Recording permission (run 'mtouch doctor').
        """
    )

    @Option(help: ArgumentHelp(
        "CGWindowID of the window to capture (from 'mtouch windows'). Omit to capture the main display.",
        valueName: "id"
    ))
    var window: String?

    @Option(help: ArgumentHelp(
        "Destination path. PNG bytes are written regardless of extension; missing parent directories are created.",
        valueName: "path"
    ))
    var out: String?

    @OptionGroup var runOptions: RunOptions

    mutating func run() throws {
        // The whole flow (preflight → resolve → capture → backstop → encode →
        // write) lives in `ScreenshotPipeline` as a testable value; this command
        // only executes the outcome. A failure prints to stderr and exits
        // non-zero, never leaving a file behind.
        let outcome = try recorded(
            command: "screenshot",
            args: TrajectoryArgs.build([
                "window": window.map(TrajectoryArgs.Value.string),
                "out": out.map(TrajectoryArgs.Value.string),
            ]),
            kind: .screenshot,
            run: runOptions,
            describe: { (outcome: ScreenshotOutcome) in outcome.trajectoryInfo }
        ) {
            ScreenshotPipeline.run(
                window: window,
                out: out,
                // The merged environment, so --run-dir is honoured the same way
                // the trajectory record is.
                liveRecording: { RunRecordingGuard.liveRecording(environment: runOptions.environment()) }
            )
        }
        switch outcome {
        case let .written(_, message):
            print(message)
        case let .failed(stderr, code):
            FileHandle.standardError.write(Data((stderr + "\n").utf8))
            throw ExitCode(code.rawValue)
        }
    }
}
