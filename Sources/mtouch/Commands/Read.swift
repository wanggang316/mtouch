import ArgumentParser
import Foundation
import MTouchKit

struct Read: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Print the full text of an element, a criteria match, or a whole application.",
        discussion: """
        Prints every string the addressed elements carry, in document order, one \
        logical block per line. The output is NEVER truncated — unlike 'mtouch \
        snapshot', which renders one line per node under a node budget and drops \
        non-actionable nodes (a long block of static text) first.

        Three ways to address text, mutually exclusive (passing two exits 64):

          read <ref>                     the subtree of one element from the current
                                         snapshot session.
          read --app <id> --of <crit>    every element matching a criteria.
          read --app <id>                every window of the application — use it
                                         when you do not yet know the structure.

        Use --of when the text you want has no reference: references are issued only \
        to ACTIONABLE elements, and long prose usually sits under inert containers \
        that have none.

        A CRITERIA is the same grammar 'mtouch wait --of' takes: a role name \
        optionally followed by a quoted substring matched over an element's title and \
        value, e.g. 'textarea' or 'group "answer"'. Friendly role names map to AX \
        roles (group → AXGroup, statictext → AXStaticText); a raw AX role is also \
        accepted.

        SEVERAL matches are all printed, in document order, separated by a blank line \
        — never just the first one; with --json they come back as an array of \
        {role, text} objects. A match nested inside another match is not repeated \
        (its text is already inside its ancestor's). NOTHING matching exits 1 and \
        names the criteria, so "no such element" stays distinguishable from an \
        element that holds no text.

        Reading changes nothing: no window is activated, no input is sent, and the \
        session's references are left exactly as they were.

        Secure-field values are masked here exactly as in every other surface.

        Exit codes: 0 text printed; 3 the reference is stale or there is no session; \
        1 nothing matched, or the application is not running; 2 Accessibility not \
        granted; 64 a malformed invocation.
        """
    )

    @Argument(help: ArgumentHelp("Element reference from a prior snapshot.", valueName: "ref"))
    var ref: String?

    @Option(help: ArgumentHelp(
        "Read every element matching this criteria, e.g. 'group \"answer\"'. Requires --app.",
        valueName: "criteria"
    ))
    var of: String?

    @Flag(help: "Emit the text as machine-readable JSON.")
    var json = false

    @OptionGroup var appOptions: OptionalAppOptions

    /// The addressing modes are mutually exclusive, and the app-scoped ones need
    /// `--app`; both rules are usage errors (exit 64) decided BEFORE any AX call.
    mutating func validate() throws {
        if let message = ReadGrammar.selectionError(ref: ref, of: of, app: appOptions.app) {
            throw ValidationError(message)
        }
    }

    mutating func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let mode = ReadGrammar.makeMode(ref: ref, of: of, app: appOptions.app)
        let pid = appOptions.pid

        let outcome = try recorded(
            command: "read",
            args: TrajectoryArgs.build([
                "ref": ref.map(TrajectoryArgs.Value.string),
                "of": of.map(TrajectoryArgs.Value.string),
                "app": appOptions.app.map(TrajectoryArgs.Value.string),
                "pid": pid.map { .int(Int($0)) },
                "json": json ? .bool(true) : nil,
            ]),
            kind: .read,
            describe: { (outcome: ReadOutcome) in outcome.trajectoryInfo }
        ) {
            switch mode {
            case let .ref(ref):
                return ReadPipeline.run(ref: ref, json: json, environment: environment)
            case let .criteria(app, criteria):
                // `--pid` rides the pipeline's existing resolution seam.
                return ReadPipeline.runApp(
                    bundleId: app, criteria: criteria, json: json, resolvePID: AppTarget.resolver(pid: pid)
                )
            case let .wholeApp(app):
                return ReadPipeline.runApp(
                    bundleId: app, criteria: nil, json: json, resolvePID: AppTarget.resolver(pid: pid)
                )
            }
        }

        switch outcome {
        case let .read(output):
            print(output)
        case let .failed(stderr, code):
            FileHandle.standardError.write(Data((stderr + "\n").utf8))
            throw ExitCode(code.rawValue)
        }
    }
}
