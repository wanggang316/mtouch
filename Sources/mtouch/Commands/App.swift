import ArgumentParser
import Foundation
import MTouchKit

struct App: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Launch, activate, or quit an application.",
        discussion: """
        Controls an application's lifecycle so a session can start from a known \
        state instead of assuming the app is already running and frontmost.

        Every verb VERIFIES its effect by polling rather than trusting the request: \
        'launch --wait-ready' waits until the app reports a window, 'activate' waits \
        until it really holds the foreground, and 'quit' waits until its process is \
        actually gone.

        Exit codes: 0 done; 1 the request failed (not installed, never became \
        frontmost, refused); 2 Accessibility not granted (activate, and launch \
        --wait-ready); 4 timed out; 64 a malformed invocation.
        """,
        subcommands: [
            Launch.self,
            Activate.self,
            Quit.self,
        ]
    )

    mutating func run() throws {
        // Bare `mtouch app` is a usage error (exit 64), not a help request.
        throw ValidationError("Missing verb. See 'mtouch app --help' for the list of verbs.")
    }
}

/// Maps an `AppOutcome` to stdout/stderr + exit code. Shared by the three verbs so
/// they cannot drift apart.
private func emit(_ outcome: AppOutcome) throws {
    switch outcome {
    case let .reported(output):
        print(output)
    case let .failed(stderr, code):
        FileHandle.standardError.write(Data((stderr + "\n").utf8))
        throw ExitCode(code.rawValue)
    }
}

extension App {
    struct Launch: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch",
            abstract: "Launch an application and report its pid.",
            discussion: """
            An application that is ALREADY running is never relaunched: its pid is \
            reported with "launched": false, so repeating this step is idempotent \
            rather than spawning a second instance. When the bundle id names several \
            running processes it is refused (they are listed) rather than guessed.

            --wait-ready polls until the application reports at least one window over \
            the accessibility API — the point at which 'mtouch snapshot' can actually \
            see it — and exits 4 if that never happens. It reads the accessibility \
            API, so it requires the Accessibility permission.
            """
        )

        @Option(help: ArgumentHelp("Bundle identifier of the application to launch.", valueName: "bundleId"))
        var app: String

        @Option(help: ArgumentHelp(
            "Wait until the application reports at least one window (e.g. 15s, 500ms).",
            valueName: "duration"
        ))
        var waitReady: WaitDuration?

        @Flag(help: "Emit machine-readable JSON output.")
        var json = false

        mutating func validate() throws {
            guard !app.isEmpty else {
                throw ValidationError(
                    "--app value must not be empty; pass a bundle identifier such as 'com.apple.Safari'."
                )
            }
        }

        mutating func run() throws {
            let bundleId = app
            let readyBudget = waitReady?.seconds
            let jsonOutput = json
            let outcome = try recorded(
                command: "app",
                args: TrajectoryArgs.build([
                    "action": .string("launch"),
                    "app": .string(bundleId),
                    "waitReady": readyBudget.map(TrajectoryArgs.Value.double),
                    "json": jsonOutput ? .bool(true) : nil,
                ]),
                kind: .action,
                describe: { (outcome: AppOutcome) in outcome.trajectoryInfo }
            ) {
                AppLifecycle.launch(bundleId: bundleId, waitReady: readyBudget, json: jsonOutput)
            }
            try emit(outcome)
        }
    }

    struct Activate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "activate",
            abstract: "Bring an application frontmost, verifying that it got there.",
            discussion: """
            Activation is asynchronous and is routinely lost when the invoking \
            terminal is itself foreground, so this polls until the target really is \
            the frontmost application. If it never becomes frontmost this exits 1 and \
            names whatever holds the foreground instead — never a silent success, \
            because keystrokes and clicks land in the FRONTMOST app.

            Both the activation and the check that it took go through the \
            accessibility API, so this requires the Accessibility permission \
            (run 'mtouch doctor').
            """
        )

        @OptionGroup var appOptions: RequiredAppOptions

        @Flag(help: "Emit machine-readable JSON output.")
        var json = false

        mutating func run() throws {
            let bundleId = appOptions.app
            let pid = appOptions.pid
            let jsonOutput = json
            let outcome = try recorded(
                command: "app",
                args: TrajectoryArgs.build([
                    "action": .string("activate"),
                    "app": .string(bundleId),
                    "pid": pid.map { .int(Int($0)) },
                    "json": jsonOutput ? .bool(true) : nil,
                ]),
                kind: .action,
                describe: { (outcome: AppOutcome) in outcome.trajectoryInfo }
            ) {
                // `--pid` rides the same resolution seam every other command uses.
                AppLifecycle.activate(
                    bundleId: bundleId, json: jsonOutput,
                    resolvePID: AppTarget.resolver(pid: pid)
                )
            }
            try emit(outcome)
        }
    }

    struct Quit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "quit",
            abstract: "Quit an application, waiting until its process is gone.",
            discussion: """
            DESTRUCTIVE: quitting an application discards any unsaved work in it. The \
            application is always asked to quit gracefully first, so it can present a \
            save dialog; if it is still running when --timeout expires this exits 4 \
            and leaves it alone.

            --force escalates to a forced termination AFTER the graceful request \
            expired. It is never implicit, and it kills the application outright: \
            unsaved work is lost with no dialog.

            mtouch refuses to quit its own process or any ancestor of it (the terminal \
            it was invoked from), which would kill this command mid-run.
            """
        )

        @OptionGroup var appOptions: RequiredAppOptions

        @Flag(help: "Force-terminate the application if it does not quit within --timeout. Unsaved work is lost.")
        var force = false

        @Option(help: ArgumentHelp("How long to wait for a graceful quit (default 10s).", valueName: "duration"))
        var timeout: WaitDuration?

        @Flag(help: "Emit machine-readable JSON output.")
        var json = false

        mutating func run() throws {
            let bundleId = appOptions.app
            let pid = appOptions.pid
            let jsonOutput = json
            let forced = force
            let budget = timeout?.seconds ?? AppLifecycle.quitBudget
            let outcome = try recorded(
                command: "app",
                args: TrajectoryArgs.build([
                    "action": .string("quit"),
                    "app": .string(bundleId),
                    "pid": pid.map { .int(Int($0)) },
                    "force": forced ? .bool(true) : nil,
                    "timeout": .double(budget),
                    "json": jsonOutput ? .bool(true) : nil,
                ]),
                kind: .action,
                describe: { (outcome: AppOutcome) in outcome.trajectoryInfo }
            ) {
                AppLifecycle.quit(
                    bundleId: bundleId, force: forced, timeout: budget, json: jsonOutput,
                    resolvePID: AppTarget.resolver(pid: pid)
                )
            }
            try emit(outcome)
        }
    }
}
