import Foundation

/// A single JSON-RPC argument value, narrowed to the primitives the tools accept.
/// The MCP entry converts the SDK's `Value` into this so `MCPToolDispatch` stays
/// free of any SDK dependency and fully unit-testable.
public enum ToolArgumentValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    /// Any value that is not one of the accepted primitives (null / array / object).
    case other
}

/// A tool call's arguments, with lenient typed accessors: a client may send a
/// number as a JSON number or a string, a flag as a bool or a string, so the
/// accessors coerce across the obvious forms rather than rejecting on shape.
public struct ToolArguments: Sendable {
    private let values: [String: ToolArgumentValue]

    public init(_ values: [String: ToolArgumentValue] = [:]) {
        self.values = values
    }

    /// Whether the key is present at all (any type).
    public func isPresent(_ key: String) -> Bool { values[key] != nil }

    /// The raw argument values, for a cross-cutting OBSERVER (trajectory recording)
    /// that needs to serialize what the client sent. Dispatch itself uses the typed
    /// accessors above; this is not part of the coercion contract.
    public var rawValues: [String: ToolArgumentValue] { values }

    /// The value as a string. Numbers and bools are stringified so a client that
    /// sends `window: 42` or `json: "true"` still works.
    public func string(_ key: String) -> String? {
        switch values[key] {
        case let .string(value): return value
        case let .int(value): return String(value)
        case let .double(value): return String(value)
        case let .bool(value): return String(value)
        case .other, nil: return nil
        }
    }

    /// The value as a bool. Accepts a JSON bool, `0`/`1`, or the usual string
    /// spellings; returns nil when absent or unrecognized.
    public func bool(_ key: String) -> Bool? {
        switch values[key] {
        case let .bool(value): return value
        case let .int(value):
            switch value { case 0: return false; case 1: return true; default: return nil }
        case let .string(value):
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        case .double, .other, nil: return nil
        }
    }

    /// The value as an integer. Accepts a JSON int, an exact-integral double, or a
    /// parseable string; returns nil otherwise.
    public func int(_ key: String) -> Int? {
        switch values[key] {
        case let .int(value): return value
        case let .double(value): return Int(exactly: value)
        case let .string(value): return Int(value)
        case .bool, .other, nil: return nil
        }
    }
}

/// One piece of a tool result: a text payload identical to what the CLI prints,
/// or an image payload (base64) the screenshot tool returns alongside its path.
public enum ToolPayload: Equatable, Sendable {
    case text(String)
    case image(base64: String, mimeType: String)
}

/// The outcome of a tool call, mapped by the MCP entry to a `CallTool.Result`.
/// `isError: true` marks a DOMAIN failure (bad bundle id, missing/invalid
/// argument, wait timeout, stale ref, unknown tool) — a well-formed result, never
/// a JSON-RPC protocol error. Protocol errors (unknown method, malformed frame,
/// pre-initialize call) are handled by the SDK, not here.
public struct ToolResult: Equatable, Sendable {
    public let payloads: [ToolPayload]
    public let isError: Bool
    /// `false` when the tool POSTED input whose arrival could not be confirmed
    /// (see `InputDeliveryFlush`). nil — the overwhelmingly common case — means the
    /// question does not arise: the tool delivered nothing, or delivery was
    /// confirmed. A field rather than a payload convention, because a recorder must
    /// not have to pattern-match prose to learn it.
    public let deliveryConfirmed: Bool?

    public init(payloads: [ToolPayload], isError: Bool, deliveryConfirmed: Bool? = nil) {
        self.payloads = payloads
        self.isError = isError
        self.deliveryConfirmed = deliveryConfirmed
    }

    /// A single-text result (the common case).
    public static func text(_ message: String, isError: Bool = false) -> ToolResult {
        ToolResult(payloads: [.text(message)], isError: isError)
    }
}

/// Maps an MCP tool name + arguments onto the SAME MTouchKit pipelines the CLI
/// commands drive, returning the IDENTICAL text/JSON payload the CLI prints for
/// the same state (payload parity — an agent must not re-learn parsing when it
/// switches between the CLI and MCP surfaces). It never re-implements
/// snapshot/act/wait/screenshot logic: each handler delegates to the pipeline and
/// only maps the outcome to a `ToolResult`.
///
/// This is a pure function of its inputs (env + injected permissions), so the
/// dispatch mapping and the isError-vs-clean classification are unit-testable with
/// a stubbed permission provider — no AX/TCC/SCK access required. AX and
/// screenshot work still happens on whatever thread the caller runs it on; the MCP
/// entry hops to the main actor first so the run loop can service it.
public enum MCPToolDispatch {
    /// `dispatch`, wrapped so an active `MTOUCH_TRAJECTORY` records the tool call
    /// through the SAME `TrajectoryRecorder` (and the SAME record model) the CLI
    /// uses — guaranteeing field-name parity across surfaces. When recording is
    /// off, this is exactly `dispatch`. A trajectory path that is unusable surfaces
    /// as a domain error (`isError`) rather than a silent, unrecorded success.
    public static func dispatchRecorded(
        tool: String,
        arguments: ToolArguments,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider()
    ) -> ToolResult {
        let kind = trajectoryKind(forTool: tool, arguments: arguments)
        // A tool result is just text, so the fact that a delivery was UNVERIFIED
        // has to come from what the client asked for. Mirrors the CLI, where the
        // flag is likewise known at the call site.
        let unverified = tool == "act" && (arguments.bool("noVerify") ?? false)
        do {
            return try TrajectoryRecorder.record(
                command: tool,
                args: trajectoryArgs(arguments),
                kind: kind,
                environment: environment,
                operation: {
                    dispatch(tool: tool, arguments: arguments, environment: environment, permissions: permissions)
                },
                describe: { $0.trajectoryInfo(kind: kind, unverified: unverified) }
            )
        } catch let error as TrajectoryError {
            return .text(error.diagnostic, isError: true)
        } catch let error as RunBundleError {
            // An unusable run directory is surfaced with the SAME pinned wording the
            // CLI prints, so both surfaces name the offending path identically.
            return .text(error.diagnostic, isError: true)
        } catch {
            return .text("mtouch: trajectory recording failed: \(error)", isError: true)
        }
    }

    /// The record class for a tool: act and app mutate, snapshot fingerprints a
    /// tree, screenshot writes a file, everything else (wait/apps/windows/doctor and
    /// any unknown tool) is a read.
    static func trajectoryKind(forTool tool: String) -> TrajectoryKind {
        switch tool {
        case "act", "app": return .action
        case "snapshot": return .snapshot
        case "screenshot": return .screenshot
        default: return .read
        }
    }

    /// The record class refined by the tool's ARGUMENTS, for the one tool whose
    /// class depends on them: `clipboard` reads with `get` and mutates with
    /// `set`/`clear`. Keeps each MCP record in the same class as the CLI command it
    /// mirrors (`clipboard get` is a read on both surfaces), which is the parity the
    /// record model promises.
    static func trajectoryKind(forTool tool: String, arguments: ToolArguments) -> TrajectoryKind {
        guard tool == "clipboard" else { return trajectoryKind(forTool: tool) }
        return arguments.string("action") == "get" ? .read : .action
    }

    /// Serialize the tool's arguments into recorder args, preserving each value's
    /// natural JSON type and dropping non-primitive values.
    static func trajectoryArgs(_ arguments: ToolArguments) -> TrajectoryArgs {
        var values: [String: TrajectoryArgs.Value] = [:]
        for (key, value) in arguments.rawValues {
            switch value {
            case let .string(string): values[key] = .string(string)
            case let .bool(bool): values[key] = .bool(bool)
            case let .int(int): values[key] = .int(int)
            case let .double(double): values[key] = .double(double)
            case .other: break
            }
        }
        return TrajectoryArgs(values)
    }

    /// Whether a tool MUST run on the main thread. AX reads/act and screenshot
    /// need it (screenshot for its window-server connection + run-loop-pump
    /// bridge), so they default to the main thread — and so does any future or
    /// unknown tool, which is the safe choice. `wait` is the sole exception: it
    /// only SLEEPS its timeout budget between polls while its AX walk runs
    /// off-main via `GuardedWalk`, so running it on the main thread would park
    /// the shared MCP run loop for the whole timeout and head-of-line-block every
    /// concurrent tool call. It therefore runs off the main thread.
    ///
    /// This is a pure classification (no SDK dependency), so the routing decision
    /// is unit-testable without the transport.
    public static func requiresMainThread(tool: String) -> Bool {
        tool != "wait"
    }

    public static func dispatch(
        tool: String,
        arguments: ToolArguments,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider()
    ) -> ToolResult {
        switch tool {
        case "snapshot": return snapshot(arguments, environment: environment, permissions: permissions)
        case "act": return act(arguments, environment: environment, permissions: permissions)
        case "wait": return wait(arguments, permissions: permissions)
        case "screenshot": return screenshot(arguments, environment: environment, permissions: permissions)
        case "apps": return apps(arguments)
        case "windows": return windows(arguments, permissions: permissions)
        case "doctor": return doctor(arguments, permissions: permissions)
        case "app": return app(arguments, permissions: permissions)
        case "clipboard": return clipboard(arguments)
        case "read": return read(arguments, environment: environment, permissions: permissions)
        default:
            // Unknown tool name is a DOMAIN failure (isError), not a JSON-RPC
            // method-not-found — the method (tools/call) exists; the argument
            // (the tool name) does not.
            return .text(
                "mtouch: unknown tool '\(tool)'. Available tools: "
                    + MCPToolCatalog.toolNames.joined(separator: ", ") + ".",
                isError: true
            )
        }
    }

    // MARK: - snapshot

    private static func snapshot(
        _ args: ToolArguments, environment: [String: String], permissions: PermissionProvider
    ) -> ToolResult {
        guard let app = args.string("app"), !app.isEmpty else {
            return invalidArgs("snapshot requires an 'app' argument (a bundle identifier such as com.apple.TextEdit).")
        }
        guard let resolvePID = resolvePIDSeam(args) else { return invalidPID() }
        let outcome = SnapshotPipeline.run(
            bundleId: app, json: args.bool("json") ?? false,
            environment: environment, permissions: permissions, resolvePID: resolvePID
        )
        switch outcome {
        case let .rendered(output): return .text(output)
        case let .failed(stderr, _): return .text(stderr, isError: true)
        }
    }

    // MARK: - act

    private static func act(
        _ args: ToolArguments, environment: [String: String], permissions: PermissionProvider
    ) -> ToolResult {
        guard let verb = args.string("verb") else {
            return invalidArgs("act requires a 'verb' argument. Valid verbs: "
                + MCPToolCatalog.actVerbs.joined(separator: ", ") + ".")
        }
        let json = args.bool("json") ?? false
        let app = args.string("app")
        // Same rule as the CLI's `OptionalAppOptions`: a pid with no bundle id to
        // check it against is refused rather than trusted blindly.
        if args.isPresent("pid"), (app ?? "").isEmpty {
            return invalidArgs(AppTarget.pidRequiresAppMessage)
        }
        guard let resolvePID = resolvePIDSeam(args) else { return invalidPID() }
        // The CLI's `--no-verify`, mirrored argument-for-argument. Refused on the
        // verbs that must read the tree to find their target, with the SAME pinned
        // wording the CLI's exit-64 refusal prints.
        let noVerify = args.bool("noVerify") ?? false

        switch verb {
        case "press", "focus", "show-menu", "set-value":
            if noVerify { return invalidArgs(UnverifiedDelivery.refVerbRefusal) }
            guard let ref = args.string("ref") else {
                return invalidArgs("act \(verb) requires a 'ref' argument (an element reference from a prior snapshot).")
            }
            let actVerb: ActVerb
            switch verb {
            case "press": actVerb = .press
            case "focus": actVerb = .focus
            case "show-menu": actVerb = .showMenu
            default: actVerb = .setValue
            }
            // A missing set-value payload is caught by the pipeline (usage error),
            // reusing the CLI's exact diagnostic.
            return fromAct(ActPipeline.run(
                ref: ref, verb: actVerb, value: args.string("value"),
                json: json, environment: environment, permissions: permissions
            ))

        case "click", "rightclick", "doubleclick", "scroll":
            guard let at = point(args, "at") else {
                return invalidArgs("act \(verb) requires an 'at' coordinate as 'x,y'.")
            }
            let action: PointerAction
            switch verb {
            case "click": action = .click(at)
            case "rightclick": action = .rightClick(at)
            case "doubleclick": action = .doubleClick(at)
            default:
                guard let dy = args.int("dy") else {
                    return invalidArgs("act scroll requires a 'dy' integer (vertical scroll delta).")
                }
                action = .scroll(at: at, dy: dy)
            }
            return fromAct(ActPipeline.runCoordinate(
                action: action, appOverride: app, json: json, noVerify: noVerify,
                environment: environment, permissions: permissions, resolvePID: resolvePID
            ))

        case "drag":
            guard let from = point(args, "from"), let to = point(args, "to") else {
                return invalidArgs("act drag requires 'from' and 'to' coordinates as 'x,y'.")
            }
            return fromAct(ActPipeline.runCoordinate(
                action: .drag(from: from, to: to), appOverride: app, json: json, noVerify: noVerify,
                environment: environment, permissions: permissions, resolvePID: resolvePID
            ))

        case "type":
            guard let text = args.string("text") else {
                return invalidArgs("act type requires a 'text' argument.")
            }
            return fromAct(ActPipeline.runKeyboard(
                action: .type(text), appOverride: app, json: json, noVerify: noVerify,
                environment: environment, permissions: permissions, resolvePID: resolvePID
            ))

        case "menu":
            if noVerify { return invalidArgs(UnverifiedDelivery.menuRefusal) }
            guard let raw = args.string("path"), !raw.isEmpty else {
                return invalidArgs("act menu requires a 'path' argument, e.g. 'File>Save'.")
            }
            let menuPath: MenuPath
            do {
                menuPath = try MenuPath(parsing: raw)
            } catch let error as MenuPathError {
                // A malformed path is a domain (invalid-argument) failure, reusing the
                // CLI's exact diagnostic.
                return .text(error.message, isError: true)
            } catch {
                return .text("mtouch: invalid menu path '\(raw)'.", isError: true)
            }
            return fromAct(ActPipeline.runMenu(
                path: menuPath, appOverride: app, json: json,
                environment: environment, permissions: permissions, resolvePID: resolvePID
            ))

        case "key":
            guard let combo = args.string("combo") else {
                return invalidArgs("act key requires a 'combo' argument, e.g. 'cmd+shift+t'.")
            }
            let parsed: KeyCombo
            do {
                parsed = try KeyCombo(parsing: combo)
            } catch let error as KeyComboParseError {
                // A malformed combo is a domain (invalid-argument) failure.
                return .text(error.message, isError: true)
            } catch {
                return .text("mtouch: invalid key combination '\(combo)'.", isError: true)
            }
            return fromAct(ActPipeline.runKeyboard(
                action: .key(parsed), appOverride: app, json: json, noVerify: noVerify,
                environment: environment, permissions: permissions, resolvePID: resolvePID
            ))

        default:
            return invalidArgs("act: unknown verb '\(verb)'. Valid verbs: "
                + MCPToolCatalog.actVerbs.joined(separator: ", ") + ".")
        }
    }

    /// The unverified case carries the SAME rendered notice the CLI prints, so the
    /// two surfaces stay byte-identical; the record — not the payload — is what
    /// marks it unverified (see `dispatchRecorded`).
    ///
    /// An UNCONFIRMED delivery cannot be read off the request the way `noVerify`
    /// can — the client did not ask for it, the window server caused it — so the
    /// result carries the fact on `deliveryConfirmed` for the recorder to pick up.
    private static func fromAct(_ outcome: ActOutcome) -> ToolResult {
        switch outcome {
        case let .acted(output), let .deliveredUnverified(output):
            return .text(output)
        case let .deliveredUnconfirmed(output):
            return ToolResult(payloads: [.text(output)], isError: false, deliveryConfirmed: false)
        case let .failed(stderr, _):
            return .text(stderr, isError: true)
        }
    }

    private static func point(_ args: ToolArguments, _ key: String) -> ScreenPoint? {
        guard let raw = args.string(key) else { return nil }
        return ScreenPoint(parsing: raw)
    }

    // MARK: - wait

    private static func wait(_ args: ToolArguments, permissions: PermissionProvider) -> ToolResult {
        guard let app = args.string("app"), !app.isEmpty else {
            return invalidArgs("wait requires an 'app' argument (a bundle identifier).")
        }
        guard let resolvePID = resolvePIDSeam(args) else { return invalidPID() }
        let appears = args.string("appears")
        let disappears = args.string("disappears")
        let text = args.string("text")
        let valueEquals = args.string("valueEquals")
        let of = args.string("of")
        let stable = args.bool("stable") ?? false

        // The timeout is parsed BEFORE the grammar check because the grammar needs
        // it: a `stableFor` longer than the budget is a usage error.
        guard let timeoutRaw = args.string("timeout"), let timeout = WaitDuration(parsing: timeoutRaw) else {
            return invalidArgs("wait requires a valid 'timeout' (e.g. 5s, 500ms, or a bare number of seconds).")
        }
        var stableFor: WaitDuration?
        if let raw = args.string("stableFor") {
            guard let parsed = WaitDuration(parsing: raw) else {
                return invalidArgs("'stableFor' must be a valid duration (e.g. 500ms).")
            }
            stableFor = parsed
        }

        if let message = WaitGrammar.selectionError(
            appears: appears, disappears: disappears, text: text, valueEquals: valueEquals, of: of,
            stable: stable, stableFor: stableFor?.seconds, timeout: timeout.seconds
        ) {
            return invalidArgs(message)
        }

        let interval: WaitDuration
        if let intervalRaw = args.string("interval") {
            guard let parsed = WaitDuration(parsing: intervalRaw) else {
                return invalidArgs("'interval' must be a valid duration (e.g. 100ms).")
            }
            interval = parsed
        } else {
            interval = WaitDuration(seconds: 0.1)
        }

        let condition = WaitGrammar.makeCondition(
            appears: appears, disappears: disappears, text: text, valueEquals: valueEquals, of: of,
            stable: stable, stableFor: stableFor?.seconds
        )
        let outcome = WaitPipeline.run(
            bundleId: app, condition: condition,
            timeout: timeout.seconds, interval: interval.seconds,
            permissions: permissions, resolvePID: resolvePID
        )
        switch outcome {
        case .satisfied:
            // The CLI signals success via exit 0 with no stdout; MCP has no exit
            // code, so it reports success as a clean confirmation echoing what held.
            return .text("condition met: \(condition.description)")
        case let .failed(stderr, _):
            return .text(stderr, isError: true)
        }
    }

    // MARK: - read

    private static func read(
        _ args: ToolArguments, environment: [String: String], permissions: PermissionProvider
    ) -> ToolResult {
        // An empty string addresses nothing, so it is treated as absent and answered
        // by the grammar below rather than sent to a pipeline as a blank target.
        let ref = nonEmpty(args.string("ref"))
        let of = nonEmpty(args.string("of"))
        let app = nonEmpty(args.string("app"))
        // Same rule as the CLI's `OptionalAppOptions`: a pid with no bundle id to
        // check it against is refused rather than trusted blindly.
        if args.isPresent("pid"), app == nil {
            return invalidArgs(AppTarget.pidRequiresAppMessage)
        }
        // The addressing modes are mutually exclusive, enforced by the SAME grammar
        // the CLI validates with, so both surfaces refuse the same combinations with
        // the same message.
        if let message = ReadGrammar.selectionError(ref: ref, of: of, app: app) {
            return invalidArgs(message)
        }
        guard let resolvePID = resolvePIDSeam(args) else { return invalidPID() }
        let json = args.bool("json") ?? false

        let outcome: ReadOutcome
        switch ReadGrammar.makeMode(ref: ref, of: of, app: app) {
        case let .ref(ref):
            outcome = ReadPipeline.run(
                ref: ref, json: json, environment: environment, permissions: permissions
            )
        case let .criteria(app, criteria):
            outcome = ReadPipeline.runApp(
                bundleId: app, criteria: criteria, json: json,
                permissions: permissions, resolvePID: resolvePID
            )
        case let .wholeApp(app):
            outcome = ReadPipeline.runApp(
                bundleId: app, criteria: nil, json: json,
                permissions: permissions, resolvePID: resolvePID
            )
        }
        switch outcome {
        case let .read(output): return .text(output)
        case let .failed(stderr, _): return .text(stderr, isError: true)
        }
    }

    // MARK: - screenshot

    private static func screenshot(
        _ args: ToolArguments,
        environment: [String: String],
        permissions: PermissionProvider
    ) -> ToolResult {
        let outcome = ScreenshotPipeline.run(
            window: args.string("window"), out: args.string("out"), permissions: permissions,
            // Same refusal as the CLI: an MCP client must not be able to destroy
            // the recording of the run it is being observed in either.
            liveRecording: { RunRecordingGuard.liveRecording(environment: environment) }
        )
        switch outcome {
        case let .written(path, message):
            guard let data = FileManager.default.contents(atPath: path) else {
                return .text(
                    "mtouch: screenshot written to \(path) but its bytes could not be read back for the image payload.",
                    isError: true
                )
            }
            return ToolResult(
                payloads: [.text(message), .image(base64: data.base64EncodedString(), mimeType: "image/png")],
                isError: false
            )
        case let .failed(stderr, _):
            return .text(stderr, isError: true)
        }
    }

    // MARK: - apps

    private static func apps(_ args: ToolArguments) -> ToolResult {
        let apps = RunningAppInfo.currentRegularApps()
        if args.bool("json") ?? false {
            return .text(RunningAppInfo.jsonArray(apps))
        }
        return .text(apps.map(\.textLine).joined(separator: "\n"))
    }

    // MARK: - windows

    private static func windows(_ args: ToolArguments, permissions: PermissionProvider) -> ToolResult {
        // The empty-`app` guard belongs only here: the CLI's `RequiredAppOptions`
        // enforces presence at parse time, so the shared pipeline never sees it.
        guard let app = args.string("app"), !app.isEmpty else {
            return invalidArgs("windows requires an 'app' argument (a bundle identifier).")
        }
        guard let resolvePID = resolvePIDSeam(args) else { return invalidPID() }
        switch WindowsPipeline.run(
            bundleId: app, json: args.bool("json") ?? false,
            permissions: permissions, resolvePID: resolvePID
        ) {
        case let .listed(output):
            return .text(output)
        case let .failed(stderr, _):
            return .text(stderr, isError: true)
        }
    }

    // MARK: - doctor

    private static func doctor(_ args: ToolArguments, permissions: PermissionProvider) -> ToolResult {
        // Doctor is a health REPORT: producing it is always a success, even when a
        // permission is missing (the ungranted status is the payload, not a failure).
        let report = DoctorReport(provider: permissions)
        if args.bool("json") ?? false {
            return .text(report.jsonString())
        }
        return .text(report.textLines().joined(separator: "\n"))
    }

    // MARK: - app

    private static func app(_ args: ToolArguments, permissions: PermissionProvider) -> ToolResult {
        guard let action = args.string("action") else {
            return invalidArgs("app requires an 'action' argument. Valid actions: launch, activate, quit.")
        }
        guard let bundleId = args.string("app"), !bundleId.isEmpty else {
            return invalidArgs("app requires an 'app' argument (a bundle identifier).")
        }
        let json = args.bool("json") ?? false

        switch action {
        case "launch":
            // A pid cannot select an instance that does not exist yet, so it is
            // refused rather than silently ignored (the CLI has no --pid here).
            if args.isPresent("pid") {
                return invalidArgs("'pid' does not apply to app launch; drop it, or use action 'activate'.")
            }
            var waitReady: TimeInterval?
            if let raw = args.string("waitReady") {
                guard let parsed = WaitDuration(parsing: raw) else {
                    return invalidArgs("'waitReady' must be a valid duration (e.g. 15s).")
                }
                waitReady = parsed.seconds
            }
            return fromApp(AppLifecycle.launch(
                bundleId: bundleId, waitReady: waitReady, json: json, permissions: permissions
            ))

        case "activate":
            guard let resolvePID = resolvePIDSeam(args) else { return invalidPID() }
            return fromApp(AppLifecycle.activate(
                bundleId: bundleId, json: json, permissions: permissions, resolvePID: resolvePID
            ))

        case "quit":
            guard let resolvePID = resolvePIDSeam(args) else { return invalidPID() }
            var timeout = AppLifecycle.quitBudget
            if let raw = args.string("timeout") {
                guard let parsed = WaitDuration(parsing: raw) else {
                    return invalidArgs("'timeout' must be a valid duration (e.g. 10s).")
                }
                timeout = parsed.seconds
            }
            return fromApp(AppLifecycle.quit(
                bundleId: bundleId, force: args.bool("force") ?? false, timeout: timeout,
                json: json, resolvePID: resolvePID
            ))

        default:
            return invalidArgs("app: unknown action '\(action)'. Valid actions: launch, activate, quit.")
        }
    }

    private static func fromApp(_ outcome: AppOutcome) -> ToolResult {
        switch outcome {
        case let .reported(output): return .text(output)
        case let .failed(stderr, _): return .text(stderr, isError: true)
        }
    }

    // MARK: - clipboard

    private static func clipboard(_ args: ToolArguments) -> ToolResult {
        guard let action = args.string("action") else {
            return invalidArgs("clipboard requires an 'action' argument. Valid actions: get, set, clear.")
        }
        let json = args.bool("json") ?? false

        switch action {
        case "get":
            return fromClipboard(ClipboardPipeline.get(json: json))
        case "set":
            guard let text = args.string("text") else {
                return invalidArgs("clipboard set requires a 'text' argument.")
            }
            return fromClipboard(ClipboardPipeline.set(text: text, json: json))
        case "clear":
            return fromClipboard(ClipboardPipeline.clear(json: json))
        default:
            return invalidArgs("clipboard: unknown action '\(action)'. Valid actions: get, set, clear.")
        }
    }

    /// A silent CLI success (`.rendered(nil)`) has no exit code to speak for it over
    /// MCP, so it becomes an explicit confirmation rather than an empty payload a
    /// client would have to interpret.
    private static func fromClipboard(_ outcome: ClipboardOutcome) -> ToolResult {
        switch outcome {
        case let .rendered(output): return .text(output ?? "ok")
        case let .failed(stderr, _): return .text(stderr, isError: true)
        }
    }

    // MARK: - Helpers

    /// The pid-resolution seam for an app-scoped tool, built from the OPTIONAL
    /// `pid` argument so the MCP surface targets a specific instance exactly as
    /// `--pid` does on the CLI (same resolver, same diagnostics, same payloads).
    /// nil ⇒ `pid` was present but not a usable process id, which the caller maps
    /// to a domain failure — the analogue of the CLI's parse-time usage error.
    private static func resolvePIDSeam(_ args: ToolArguments) -> ((String) throws -> pid_t)? {
        guard args.isPresent("pid") else { return AppTarget.resolver(pid: nil) }
        guard let raw = args.int("pid"), let pid = pid_t(exactly: raw) else { return nil }
        return AppTarget.resolver(pid: pid)
    }

    /// An argument that is present but EMPTY carries no target, so it is treated as
    /// absent — a blank string must not be mistaken for a selected addressing mode.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func invalidPID() -> ToolResult {
        invalidArgs("'pid' must be the process id of a running application (an integer).")
    }

    /// A domain (invalid-argument) failure: the SDK does not validate tool
    /// arguments, so a missing/malformed argument surfaces as an isError result,
    /// not a JSON-RPC error.
    private static func invalidArgs(_ message: String) -> ToolResult {
        .text("mtouch: invalid arguments: \(message)", isError: true)
    }
}
