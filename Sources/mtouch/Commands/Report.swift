import ArgumentParser
import Foundation
import MTouchKit

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Render a run evidence bundle as a readable HTML report.",
        discussion: """
        Turns a run directory — the one MTOUCH_RUN_DIR / --run-dir collected into — \
        into a single self-contained report.html: a step timeline built from \
        trajectory.jsonl (command, arguments, wall-clock and monotonic timestamps, \
        outcome, exit code, error class, and the resulting diff), each step's \
        before/after screenshots embedded inline, an embed slot for a screen \
        recording, and a header summarizing the label, duration, step count, and \
        pass/fail tally.

        The page is OFFLINE: every stylesheet rule and every screenshot is inlined, \
        so it opens from file:// with no network access. It is also DETERMINISTIC — \
        nothing in it comes from the moment of rendering — so two renders of one \
        bundle are byte-identical and can be diffed.

        Steps recorded while a screen recording was live carry no screenshot — one \
        would have invalidated the recording — but a marker naming the moment. \
        Rendering CUTS those stills out of the movie into steps/ and labels them \
        'extracted from the recording', so their provenance is never confused with \
        a directly captured one. An already-extracted still is reused rather than \
        cut again, which is what keeps two renders byte-identical.

        Anything absent is stated rather than faked: a missing run.json, an empty or \
        damaged trajectory, a missing screenshot, a frame that could not be cut out \
        of the movie, and an absent recording each render as a plain note.

        A report carries whatever was on screen, and the trajectory strips payload \
        arguments only from FAILED records — so a SUCCESSFUL 'act type <secret>' is \
        in the log verbatim. The report says so on its face; --redact drops the \
        screenshots and the recording and keeps only the structured log.
        """
    )

    @Argument(help: ArgumentHelp("Run directory to render (from MTOUCH_RUN_DIR / --run-dir).", valueName: "run-dir"))
    var runDir: String

    @Option(help: ArgumentHelp(
        "Destination path for the HTML. Defaults to <run-dir>/report.html; missing parents are created.",
        valueName: "file"
    ))
    var out: String?

    @Flag(help: "Omit screenshots and the screen recording, keeping only the structured log.")
    var redact = false

    mutating func validate() throws {
        guard !runDir.isEmpty else {
            throw ValidationError("<run-dir> must not be empty; pass the directory a run was recorded into.")
        }
    }

    mutating func run() throws {
        // `report` READS a bundle and writes a derived artifact, so it is
        // deliberately not itself recorded: appending to the trajectory it just
        // rendered would leave the report disagreeing with its own bundle.
        switch ReportPipeline.run(runDirectory: runDir, out: out, redact: redact) {
        case let .rendered(_, message):
            print(message)
        case let .failed(stderr, code):
            FileHandle.standardError.write(Data((stderr + "\n").utf8))
            throw ExitCode(code.rawValue)
        }
    }
}
