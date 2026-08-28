import ArgumentParser
import Foundation
import MTouchKit

struct Act: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "act",
        abstract: "Perform a UI action.",
        subcommands: [
            Press.self,
            Focus.self,
            ShowMenu.self,
            Menu.self,
            SetValue.self,
            Click.self,
            RightClick.self,
            DoubleClick.self,
            Drag.self,
            Scroll.self,
            TypeText.self,
            Key.self,
        ]
    )

    mutating func run() throws {
        // Bare `mtouch act` is a usage error (exit 64), not a help request.
        throw ValidationError("Missing action verb. See 'mtouch act --help' for the list of verbs.")
    }
}

// MARK: - Shared argument shapes

/// `--no-verify`, offered by the act verbs that synthesize input through CGEvent
/// and resolve no element reference. It trades away the post-action diff — the
/// evidence that is mtouch's reason to exist — so its help says exactly that, and
/// says when the trade is worth making.
struct VerifyOptions: ParsableArguments {
    @Flag(help: ArgumentHelp(
        "Deliver the input WITHOUT reading the accessibility tree: no diff is taken and none is "
            + "reported. Use it when the target is showing a modal panel, whose nested event loop "
            + "blocks the accessibility server so every read times out. The effect of the action is "
            + "NOT verified — run 'mtouch snapshot' afterwards to see what happened."
    ))
    var noVerify = false
}

/// Grammar shared by the ref-based verbs: `[<ref>] [<value>]` plus the criteria
/// alternative `--of <criteria>`. Exactly one of `<ref>` / `--of` targets the
/// element — validated in `runRefVerb`, where the verb is known (set-value's
/// positional payload shifts slots in `--of` mode). Only set-value consumes
/// `<value>`.
struct RefActionArguments: ParsableArguments {
    @Argument(help: ArgumentHelp(
        "Element reference from a prior snapshot. Omit it to target by criteria with --of.",
        valueName: "ref"
    ))
    var ref: String?

    @Argument(help: ArgumentHelp("Optional value payload (used by set-value).", valueName: "value"))
    var value: String?

    @Option(help: ArgumentHelp(
        "Act on the SINGLE element matching this criteria instead of a <ref> — no snapshot needed. "
            + "Same grammar as wait/read: a role plus an optional quoted substring matched over "
            + "title, value, description, and identifier, e.g. 'button \"Seven\"'. Requires --app. "
            + "Several matches, or none: the command refuses (exit 1) and acts on nothing.",
        valueName: "criteria"
    ))
    var of: String?

    @Flag(help: "Emit the resulting diff as machine-readable JSON.")
    var json = false

    /// Declared but REFUSED. A ref verb locates its target BY reading the tree, so
    /// it cannot skip that read; accepting the flag here would be a promise the
    /// verb cannot keep. It is declared (hidden, so help never advertises it) only
    /// so the refusal can say WHY and name the verbs that do take it — an agent
    /// that gets ArgumentParser's bare "unknown option" learns nothing.
    @Flag(help: .hidden)
    var noVerify = false

    @OptionGroup var appOptions: OptionalAppOptions

    @OptionGroup var runOptions: RunOptions

    mutating func validate() throws {
        if noVerify { throw ValidationError(UnverifiedDelivery.refVerbRefusal) }
    }
}

/// Maps an act outcome onto stdout/stderr + exit code, shared by every verb
/// runner so the three cases are decided in ONE place.
///
/// `.deliveredUnverified` prints its notice exactly where a diff would go and
/// exits 0: the input WAS delivered, so the command succeeded — what it cannot
/// claim is that anything was verified, and the payload says so.
///
/// `.deliveredUnconfirmed` prints its own, stronger notice in the same place and
/// also exits 0. The events went out, so a non-zero exit would invite a retry that
/// delivers them a second time; the distinguishing evidence is the payload (and the
/// trajectory's `deliveryConfirmed` field), not the exit code.
///
/// `.actedUnsettled` prints the diff it did manage to read, led by the marker that
/// says the interface had not stopped changing. Exit 0 for the same reason: the
/// action itself succeeded, and the distinguishing evidence is the payload (and the
/// trajectory's `settled` field).
func report(_ outcome: ActOutcome) throws {
    switch outcome {
    case let .acted(output), let .actedUnsettled(output),
         let .deliveredUnverified(output), let .deliveredUnconfirmed(output):
        print(output)
    case let .failed(stderr, code):
        FileHandle.standardError.write(Data((stderr + "\n").utf8))
        throw ExitCode(code.rawValue)
    }
}

/// Executes a ref-based verb through `ActPipeline` and maps its outcome to
/// stdout/stderr + exit code. The CLI layer stays thin: the resolve → re-locate →
/// act → re-walk → diff → persist flow lives in `ActPipeline` so the coordinate
/// and keyboard verbs (later features) reuse it.
///
/// The target grammar (exactly one of `<ref>` / `--of`; `--of` requires `--app`)
/// is validated HERE rather than in `RefActionArguments.validate()` because only
/// the verb knows whether the sole positional in `--of` mode is a stray ref or
/// set-value's payload; a violation is still a usage error (exit 64) decided
/// before any AX call.
func runRefVerb(_ verb: ActVerb, _ arguments: RefActionArguments) throws {
    let (ref, value) = ActTargetGrammar.normalizedPositionals(
        ref: arguments.ref, value: arguments.value, of: arguments.of,
        consumesValue: verb == .setValue
    )
    if let message = ActTargetGrammar.selectionError(ref: ref, of: arguments.of, app: arguments.appOptions.app) {
        throw ValidationError(message)
    }
    let environment = ProcessInfo.processInfo.environment
    let outcome = try recorded(
        command: "act",
        args: TrajectoryArgs.build([
            "verb": .string(verb.trajectoryName),
            "ref": ref.map(TrajectoryArgs.Value.string),
            "of": arguments.of.map(TrajectoryArgs.Value.string),
            "value": value.map(TrajectoryArgs.Value.string),
            "json": arguments.json ? .bool(true) : nil,
            "app": arguments.appOptions.app.map(TrajectoryArgs.Value.string),
            "pid": arguments.appOptions.pid.map { .int(Int($0)) },
        ]),
        kind: .action,
        run: arguments.runOptions,
        describe: { (outcome: ActOutcome) in outcome.trajectoryInfo }
    ) {
        switch ActTargetGrammar.makeMode(ref: ref, of: arguments.of, app: arguments.appOptions.app) {
        case let .ref(ref):
            return ActPipeline.run(
                ref: ref,
                verb: verb,
                value: value,
                json: arguments.json,
                environment: environment
            )
        case let .criteria(app, criteria):
            // `--pid` rides the pipeline's existing resolution seam (it applies
            // only alongside `--app`; `OptionalAppOptions` rejects a lone pid).
            return ActPipeline.runCriteria(
                criteria: criteria,
                verb: verb,
                value: value,
                app: app,
                json: arguments.json,
                environment: environment,
                resolvePID: AppTarget.resolver(pid: arguments.appOptions.pid)
            )
        }
    }
    try report(outcome)
}

// MARK: - Ref-based verbs

extension Act {
    struct Press: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "press",
            abstract: "Press (activate) the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { try runRefVerb(.press, arguments) }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "focus",
            abstract: "Give keyboard focus to the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { try runRefVerb(.focus, arguments) }
    }

    struct ShowMenu: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show-menu",
            abstract: "Open the menu of the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { try runRefVerb(.showMenu, arguments) }
    }

    struct SetValue: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-value",
            abstract: "Set the value of the referenced element."
        )

        @OptionGroup var arguments: RefActionArguments

        mutating func run() throws { try runRefVerb(.setValue, arguments) }
    }
}

// MARK: - Menu-path verb

/// Executes `act menu` through `ActPipeline.runMenu` and maps its outcome to
/// stdout/stderr + exit code, mirroring the other verb runners.
func runMenuVerb(
    _ path: MenuPath, appOverride: String?, pidOverride: pid_t?, json: Bool, run: RunOptions
) throws {
    let environment = ProcessInfo.processInfo.environment
    let outcome = try recorded(
        command: "act",
        args: TrajectoryArgs.build([
            "verb": .string("menu"),
            "path": .string(path.rendered),
            "json": json ? .bool(true) : nil,
            "app": appOverride.map(TrajectoryArgs.Value.string),
            "pid": pidOverride.map { .int(Int($0)) },
        ]),
        kind: .action,
        run: run,
        describe: { (outcome: ActOutcome) in outcome.trajectoryInfo }
    ) {
        ActPipeline.runMenu(
            path: path,
            appOverride: appOverride,
            json: json,
            environment: environment,
            resolvePID: AppTarget.resolver(pid: pidOverride)
        )
    }
    try report(outcome)
}

extension Act {
    struct Menu: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "menu",
            abstract: "Invoke a menu-bar command by its title path.",
            discussion: """
            Walks the application's menu bar by title — 'File>Save' opens File, then \
            invokes Save — pressing each level over the accessibility API and \
            returning the resulting diff like every other act verb.

            This is the reliable way to command an application whose content area is \
            not exposed over the accessibility API: its menu bar almost always is, and \
            each step is a verifiable press rather than a blind keyboard shortcut that \
            depends on winning the frontmost race.

            Titles are user-visible and may be localized ('文件>存储'). Each segment is \
            matched exactly first, then case-insensitively; a segment that matches \
            nothing exits 1 and LISTS the titles that were available at that level. A \
            disabled item, and two same-titled items, are also refused rather than \
            guessed. A failed path never leaves a menu open.

            Use the repeatable --item form for a title that itself contains '>'.
            """
        )

        @Argument(help: ArgumentHelp("Menu title path, '>'-separated, e.g. 'File>Save'.", valueName: "path"))
        var path: String?

        @Option(help: ArgumentHelp(
            "One exact menu title; repeat once per level. Use instead of <path> when a title contains '>'.",
            valueName: "title"
        ))
        var item: [String] = []

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        /// Declared but REFUSED, for the same reason as the ref verbs: this verb
        /// FINDS its command by walking the menu bar over the accessibility API.
        @Flag(help: .hidden)
        var noVerify = false

        @OptionGroup var appOptions: OptionalAppOptions

        @OptionGroup var runOptions: RunOptions

        mutating func validate() throws {
            if noVerify {
                throw ValidationError(UnverifiedDelivery.menuRefusal)
            }
            if path == nil, item.isEmpty {
                throw ValidationError("Provide a menu path such as 'File>Save', or one --item per menu level.")
            }
            if path != nil, !item.isEmpty {
                throw ValidationError("Pass either <path> or --item, not both.")
            }
        }

        mutating func run() throws {
            // Parse the path FIRST: a malformed path is a usage error (exit 64) that
            // must precede any permission/AX work (pinned 64 -> 2 -> 3 -> 1).
            let menuPath: MenuPath
            do {
                menuPath = path == nil ? try MenuPath(segments: item) : try MenuPath(parsing: path!)
            } catch let error as MenuPathError {
                FileHandle.standardError.write(Data((error.message + "\n").utf8))
                throw ExitCode(error.exitCode.rawValue)
            }
            try runMenuVerb(
                menuPath, appOverride: appOptions.app, pidOverride: appOptions.pid, json: json,
                run: runOptions
            )
        }
    }
}

// MARK: - Coordinate-based verbs

/// Executes a coordinate verb through `ActPipeline.runCoordinate` and maps its
/// outcome to stdout/stderr + exit code, mirroring `runRefVerb`/`runKeyboardVerb`.
/// The pipeline reuses the ref/keyboard verbs' back half (resolve target →
/// off-screen guard → post → re-walk → diff → persist); only the "act" step
/// differs (a mouse gesture at screen points).
///
/// Malformed coordinates (`--at foo,bar`), reference tokens passed to a
/// coordinate-only verb (`drag --from e1 --to e2`, `click e1`), and unknown verbs
/// (`act wiggle`) are all rejected by ArgumentParser as usage errors (exit 64)
/// BEFORE this runs — a ref token is not a valid `x,y`, so it fails value parsing.
func runCoordinateVerb(
    _ action: PointerAction, appOverride: String?, pidOverride: pid_t?, json: Bool,
    noVerify: Bool, run: RunOptions
) throws {
    let environment = ProcessInfo.processInfo.environment
    let outcome = try recorded(
        command: "act",
        args: coordinateArgs(
            action, appOverride: appOverride, pidOverride: pidOverride, json: json, noVerify: noVerify
        ),
        kind: .action,
        run: run,
        describe: { (outcome: ActOutcome) in outcome.trajectoryInfo }
    ) {
        // `--pid` rides the pipeline's existing resolution seam (it applies only
        // when `--app` selects the target; `OptionalAppOptions` rejects a lone pid).
        ActPipeline.runCoordinate(
            action: action,
            appOverride: appOverride,
            json: json,
            noVerify: noVerify,
            environment: environment,
            resolvePID: AppTarget.resolver(pid: pidOverride)
        )
    }
    try report(outcome)
}

/// The recorded args for a coordinate verb: the verb name plus its target points
/// (and scroll delta), mirroring the MCP `act` tool's argument vocabulary.
private func coordinateArgs(
    _ action: PointerAction, appOverride: String?, pidOverride: pid_t?, json: Bool, noVerify: Bool
) -> TrajectoryArgs {
    var pairs: [String: TrajectoryArgs.Value?] = [
        "app": appOverride.map(TrajectoryArgs.Value.string),
        "pid": pidOverride.map { .int(Int($0)) },
        "json": json ? .bool(true) : nil,
        "noVerify": noVerify ? .bool(true) : nil,
    ]
    switch action {
    case let .click(point):
        pairs["verb"] = .string("click"); pairs["at"] = .string(point.rendered)
    case let .rightClick(point):
        pairs["verb"] = .string("rightclick"); pairs["at"] = .string(point.rendered)
    case let .doubleClick(point):
        pairs["verb"] = .string("doubleclick"); pairs["at"] = .string(point.rendered)
    case let .drag(from, to):
        pairs["verb"] = .string("drag")
        pairs["from"] = .string(from.rendered); pairs["to"] = .string(to.rendered)
    case let .scroll(at, dy):
        pairs["verb"] = .string("scroll")
        pairs["at"] = .string(at.rendered); pairs["dy"] = .int(dy)
    }
    return TrajectoryArgs.build(pairs)
}

extension Act {
    struct Click: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "click",
            abstract: "Click at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to click.", valueName: "x,y"))
        var at: ScreenPoint

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        @OptionGroup var runOptions: RunOptions

        @OptionGroup var verifyOptions: VerifyOptions

        mutating func run() throws {
            try runCoordinateVerb(
                .click(at), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json,
                noVerify: verifyOptions.noVerify, run: runOptions
            )
        }
    }

    struct RightClick: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rightclick",
            abstract: "Right-click at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to right-click.", valueName: "x,y"))
        var at: ScreenPoint

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        @OptionGroup var runOptions: RunOptions

        @OptionGroup var verifyOptions: VerifyOptions

        mutating func run() throws {
            try runCoordinateVerb(
                .rightClick(at), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json,
                noVerify: verifyOptions.noVerify, run: runOptions
            )
        }
    }

    struct DoubleClick: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "doubleclick",
            abstract: "Double-click at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to double-click.", valueName: "x,y"))
        var at: ScreenPoint

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        @OptionGroup var runOptions: RunOptions

        @OptionGroup var verifyOptions: VerifyOptions

        mutating func run() throws {
            try runCoordinateVerb(
                .doubleClick(at), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json,
                noVerify: verifyOptions.noVerify, run: runOptions
            )
        }
    }

    struct Drag: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "drag",
            abstract: "Drag from one screen coordinate to another."
        )

        @Option(help: ArgumentHelp("Starting screen coordinate.", valueName: "x,y"))
        var from: ScreenPoint

        @Option(help: ArgumentHelp("Ending screen coordinate.", valueName: "x,y"))
        var to: ScreenPoint

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        @OptionGroup var runOptions: RunOptions

        @OptionGroup var verifyOptions: VerifyOptions

        mutating func run() throws {
            try runCoordinateVerb(
                .drag(from: from, to: to), appOverride: appOptions.app, pidOverride: appOptions.pid,
                json: json, noVerify: verifyOptions.noVerify, run: runOptions
            )
        }
    }

    struct Scroll: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scroll",
            abstract: "Scroll at a screen coordinate."
        )

        @Option(help: ArgumentHelp("Screen coordinate to scroll at.", valueName: "x,y"))
        var at: ScreenPoint

        // `.unconditional` so a negative delta (`--dy -300`) is taken as the value
        // rather than parsed as an option/flag — the documented idiom for a
        // dash-prefixed numeric argument. Positive `--dy` scrolls content up.
        @Option(parsing: .unconditional,
                help: ArgumentHelp("Vertical scroll delta (positive scrolls content up).", valueName: "n"))
        var dy: Int

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        @OptionGroup var runOptions: RunOptions

        @OptionGroup var verifyOptions: VerifyOptions

        mutating func run() throws {
            try runCoordinateVerb(
                .scroll(at: at, dy: dy), appOverride: appOptions.app, pidOverride: appOptions.pid,
                json: json, noVerify: verifyOptions.noVerify, run: runOptions
            )
        }
    }
}

// MARK: - Keyboard verbs

/// Executes a keyboard verb through `ActPipeline.runKeyboard` and maps its
/// outcome to stdout/stderr + exit code, mirroring `runRefVerb`. The pipeline
/// reuses the ref verbs' back half (activate → post → re-walk → diff → persist);
/// only the "act" step differs (keystrokes to the focused element).
/// `args` is supplied by the caller: the `type` verb records its `text`, and the
/// `key` verb its raw `combo` string (which the parsed `KeyCombo` does not
/// retain). A refused/failed keyboard verb has its payload stripped by the
/// recorder, so a secret never persists.
func runKeyboardVerb(
    _ action: KeyboardAction, appOverride: String?, pidOverride: pid_t?, json: Bool,
    noVerify: Bool, args: TrajectoryArgs, run: RunOptions
) throws {
    let environment = ProcessInfo.processInfo.environment
    let outcome = try recorded(
        command: "act",
        args: args,
        kind: .action,
        run: run,
        describe: { (outcome: ActOutcome) in outcome.trajectoryInfo }
    ) {
        // `--pid` rides the pipeline's existing resolution seam (it applies only
        // when `--app` selects the target; `OptionalAppOptions` rejects a lone pid).
        ActPipeline.runKeyboard(
            action: action,
            appOverride: appOverride,
            json: json,
            noVerify: noVerify,
            environment: environment,
            resolvePID: AppTarget.resolver(pid: pidOverride)
        )
    }
    try report(outcome)
}

extension Act {
    struct TypeText: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type literal text."
        )

        @Argument(help: ArgumentHelp("Text to type.", valueName: "text"))
        var text: String

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        @OptionGroup var runOptions: RunOptions

        @OptionGroup var verifyOptions: VerifyOptions

        mutating func run() throws {
            let args = TrajectoryArgs.build([
                "verb": .string("type"),
                "text": .string(text),
                "json": json ? .bool(true) : nil,
                "noVerify": verifyOptions.noVerify ? .bool(true) : nil,
                "app": appOptions.app.map(TrajectoryArgs.Value.string),
                "pid": appOptions.pid.map { .int(Int($0)) },
            ])
            try runKeyboardVerb(
                .type(text), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json,
                noVerify: verifyOptions.noVerify, args: args, run: runOptions
            )
        }
    }

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "key",
            abstract: "Send a key combination."
        )

        @Argument(help: ArgumentHelp("Key combination, e.g. 'cmd+shift+t'.", valueName: "combo"))
        var combo: String

        @Flag(help: "Emit the resulting diff as machine-readable JSON.")
        var json = false

        @OptionGroup var appOptions: OptionalAppOptions

        @OptionGroup var runOptions: RunOptions

        @OptionGroup var verifyOptions: VerifyOptions

        mutating func run() throws {
            // Parse the combo FIRST: an unknown modifier/key name is a usage error
            // (exit 64) that must precede any permission/AX work (pinned 64 -> 2 -> 3).
            let parsed: KeyCombo
            do {
                parsed = try KeyCombo(parsing: combo)
            } catch let error as KeyComboParseError {
                FileHandle.standardError.write(Data((error.message + "\n").utf8))
                throw ExitCode(error.exitCode.rawValue)
            }
            let args = TrajectoryArgs.build([
                "verb": .string("key"),
                "combo": .string(combo),
                "json": json ? .bool(true) : nil,
                "noVerify": verifyOptions.noVerify ? .bool(true) : nil,
                "app": appOptions.app.map(TrajectoryArgs.Value.string),
                "pid": appOptions.pid.map { .int(Int($0)) },
            ])
            try runKeyboardVerb(
                .key(parsed), appOverride: appOptions.app, pidOverride: appOptions.pid, json: json,
                noVerify: verifyOptions.noVerify, args: args, run: runOptions
            )
        }
    }
}
