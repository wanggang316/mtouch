import Foundation
import Testing
@testable import MTouchKit

// MARK: - Stubs

/// A permission provider with both grants individually settable, so the
/// permission-gated branches of dispatch are exercised without any live TCC.
private struct StubPermissions: PermissionProvider {
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool
}

private let ungranted = StubPermissions(accessibilityGranted: false, screenRecordingGranted: false)
private let axOnly = StubPermissions(accessibilityGranted: true, screenRecordingGranted: false)

private func text(_ result: ToolResult) -> String? {
    for payload in result.payloads {
        if case let .text(value) = payload { return value }
    }
    return nil
}

private func call(_ tool: String, _ args: [String: ToolArgumentValue],
                  permissions: PermissionProvider = ungranted,
                  environment: [String: String] = [:]) -> ToolResult {
    MCPToolDispatch.dispatch(tool: tool, arguments: ToolArguments(args),
                             environment: environment, permissions: permissions)
}

// MARK: - Catalog

/// The advertised tool set, in catalog order. New tools are APPENDED so an
/// existing client's view of the earlier ones never shifts.
private let advertisedTools = [
    "snapshot", "act", "wait", "screenshot", "apps", "windows", "doctor", "app", "clipboard", "read",
]

@Suite struct MCPToolCatalogTests {
    @Test func advertisesExactlyTheDeclaredTools() {
        #expect(MCPToolCatalog.toolNames == advertisedTools)
    }

    @Test func eachToolHasADescriptionAndProperties() {
        for spec in MCPToolCatalog.tools {
            #expect(!spec.description.isEmpty)
            // Every required name is a declared property.
            let propertyNames = Set(spec.properties.map(\.name))
            for required in spec.required {
                #expect(propertyNames.contains(required))
            }
        }
    }

    @Test func requiredArgumentsMatchTheCLIContract() {
        func spec(_ name: String) -> MCPToolCatalog.Spec { MCPToolCatalog.tools.first { $0.name == name }! }
        #expect(spec("snapshot").required == ["app"])
        #expect(spec("act").required == ["verb"])
        #expect(spec("wait").required == ["app", "timeout"])
        #expect(spec("windows").required == ["app"])
        #expect(spec("screenshot").required.isEmpty)
        #expect(spec("apps").required.isEmpty)
        #expect(spec("doctor").required.isEmpty)
        #expect(spec("app").required == ["action", "app"])
        #expect(spec("clipboard").required == ["action"])
        // `read` requires NO property: its addressing grammar (exactly one of ref /
        // app+of / app) is richer than a required-set can express, so it is enforced
        // at call time with a message naming the conflict.
        #expect(spec("read").required.isEmpty)
    }

    /// The action-shaped tools constrain their verb to an enum, so a client cannot
    /// invent one and discover the refusal only at call time.
    @Test func lifecycleAndClipboardActionsAreEnumerated() throws {
        let app = try #require(MCPToolCatalog.tools.first { $0.name == "app" })
        let appAction = try #require(app.properties.first { $0.name == "action" })
        #expect(appAction.enumValues == ["launch", "activate", "quit"])

        let clipboard = try #require(MCPToolCatalog.tools.first { $0.name == "clipboard" })
        let clipboardAction = try #require(clipboard.properties.first { $0.name == "action" })
        #expect(clipboardAction.enumValues == ["get", "set", "clear"])
    }

    /// `--pid` parity: every app-scoped tool advertises an OPTIONAL integer `pid`,
    /// so an MCP client can disambiguate two instances exactly as the CLI does.
    @Test func appScopedToolsAdvertiseAnOptionalIntegerPid() throws {
        for name in ["snapshot", "act", "wait", "windows", "app", "read"] {
            let spec = try #require(MCPToolCatalog.tools.first { $0.name == name })
            let pid = try #require(spec.properties.first { $0.name == "pid" },
                                   "\(name) should advertise a pid property")
            #expect(pid.type == "integer")
            #expect(!pid.description.isEmpty)
            // Optional: adding it must not change what a client MUST send.
            #expect(!spec.required.contains("pid"))
        }
    }

    /// Adding a property must not add, rename, or remove a TOOL (VAL-MCP-002).
    @Test func addingPropertiesChangesNoToolName() {
        #expect(MCPToolCatalog.tools.count == advertisedTools.count)
        #expect(Set(MCPToolCatalog.toolNames) == Set(advertisedTools))
        // Tools with no app argument gain nothing.
        for name in ["screenshot", "apps", "doctor", "clipboard"] {
            let spec = MCPToolCatalog.tools.first { $0.name == name }
            #expect(spec?.properties.contains { $0.name == "pid" } == false)
        }
    }

    /// `--stable` reaches the MCP surface with the same vocabulary as the CLI, so
    /// an agent does not have to re-learn the grammar when it switches surfaces.
    @Test func waitAdvertisesTheQuiescenceArguments() throws {
        let spec = try #require(MCPToolCatalog.tools.first { $0.name == "wait" })
        let stable = try #require(spec.properties.first { $0.name == "stable" })
        #expect(stable.type == "boolean")
        let stableFor = try #require(spec.properties.first { $0.name == "stableFor" })
        #expect(stableFor.type == "string")
        // Optional: the tool's required set is unchanged.
        #expect(spec.required == ["app", "timeout"])
    }

    /// `read` mirrors the CLI's three addressing modes, so an agent does not have to
    /// re-learn the grammar when it switches surfaces.
    @Test func readAdvertisesAllThreeAddressingModes() throws {
        let spec = try #require(MCPToolCatalog.tools.first { $0.name == "read" })
        #expect(spec.properties.map(\.name) == ["ref", "app", "pid", "of", "json"])
        for name in ["ref", "app", "of"] {
            let property = try #require(spec.properties.first { $0.name == name })
            #expect(property.type == "string")
            #expect(!property.description.isEmpty)
        }
        // The multi-match contract is documented where a client will read it.
        let of = try #require(spec.properties.first { $0.name == "of" })
        #expect(of.description.contains("EVERY match"))
    }

    /// The `act` tool mirrors the CLI's `--of` criteria target: an optional
    /// string property on the SAME tool — no tool added or renamed, no change to
    /// the required set (VAL-MCP-002).
    @Test func actAdvertisesTheCriteriaTarget() throws {
        let spec = try #require(MCPToolCatalog.tools.first { $0.name == "act" })
        let of = try #require(spec.properties.first { $0.name == "of" })
        #expect(of.type == "string")
        // The single-match contract is documented where a client will read it.
        #expect(of.description.contains("SINGLE"))
        #expect(spec.required == ["verb"])
    }

    @Test func actVerbEnumCoversTheGrammar() {
        let actSpec = MCPToolCatalog.tools.first { $0.name == "act" }!
        let verb = actSpec.properties.first { $0.name == "verb" }!
        #expect(verb.enumValues == [
            "press", "focus", "show-menu", "set-value",
            "click", "rightclick", "doubleclick", "drag", "scroll",
            "type", "key", "menu",
        ])
    }
}

// MARK: - Thread routing

@Suite struct MCPToolThreadRoutingTests {
    // `wait` is the sole tool that runs OFF the main thread: it only sleeps its
    // timeout budget while its AX walk runs off-main via GuardedWalk, so hopping
    // it to main would head-of-line-block concurrent tool calls.
    @Test func waitRunsOffTheMainThread() {
        #expect(MCPToolDispatch.requiresMainThread(tool: "wait") == false)
    }

    // Every other advertised tool needs the main thread (AX reads/act, and the
    // screenshot window-server + run-loop-pump bridge).
    @Test func allNonWaitToolsRequireTheMainThread() {
        for tool in MCPToolCatalog.toolNames where tool != "wait" {
            #expect(MCPToolDispatch.requiresMainThread(tool: tool), "\(tool) should require the main thread")
        }
    }

    // An unknown tool defaults to the safe main-thread path (it only produces an
    // isError string, so the thread is immaterial — but the default must not
    // accidentally send future tools off-main).
    @Test func unknownToolDefaultsToMainThread() {
        #expect(MCPToolDispatch.requiresMainThread(tool: "does-not-exist"))
    }
}

// MARK: - ToolArguments coercion

@Suite struct ToolArgumentsTests {
    @Test func stringAcceptsStringNumberAndBool() {
        let args = ToolArguments([
            "s": .string("hi"), "i": .int(42), "d": .double(1.5), "b": .bool(true),
        ])
        #expect(args.string("s") == "hi")
        #expect(args.string("i") == "42")
        #expect(args.string("d") == "1.5")
        #expect(args.string("b") == "true")
        #expect(args.string("missing") == nil)
    }

    @Test func boolAcceptsBoolIntAndString() {
        #expect(ToolArguments(["j": .bool(true)]).bool("j") == true)
        #expect(ToolArguments(["j": .int(1)]).bool("j") == true)
        #expect(ToolArguments(["j": .int(0)]).bool("j") == false)
        #expect(ToolArguments(["j": .string("true")]).bool("j") == true)
        #expect(ToolArguments(["j": .string("false")]).bool("j") == false)
        #expect(ToolArguments([:]).bool("j") == nil)
    }

    @Test func intAcceptsIntExactDoubleAndString() {
        #expect(ToolArguments(["n": .int(-300)]).int("n") == -300)
        #expect(ToolArguments(["n": .double(-300)]).int("n") == -300)
        #expect(ToolArguments(["n": .double(1.5)]).int("n") == nil)
        #expect(ToolArguments(["n": .string("7")]).int("n") == 7)
    }
}

// MARK: - Dispatch classification (isError vs clean)

@Suite struct MCPDispatchClassificationTests {
    // Unknown tool name is a DOMAIN failure (isError), not a protocol error.
    @Test func unknownToolIsError() {
        let result = call("nope", [:])
        #expect(result.isError)
        #expect(text(result)?.contains("unknown tool 'nope'") == true)
    }

    // MARK: snapshot

    @Test func snapshotMissingAppIsInvalidArgs() {
        let result = call("snapshot", [:])
        #expect(result.isError)
        #expect(text(result)?.contains("invalid arguments") == true)
    }

    @Test func snapshotUngrantedNamesAccessibility() {
        let result = call("snapshot", ["app": .string("com.apple.TextEdit")], permissions: ungranted)
        #expect(result.isError)
        // Parity: the exact diagnostic the pipeline would print to stderr.
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    // MARK: act

    @Test func actMissingVerbIsInvalidArgs() {
        let result = call("act", [:])
        #expect(result.isError)
        #expect(text(result)?.contains("requires a 'verb'") == true)
    }

    @Test func actUnknownVerbIsError() {
        let result = call("act", ["verb": .string("wiggle")])
        #expect(result.isError)
        #expect(text(result)?.contains("unknown verb 'wiggle'") == true)
    }

    @Test func actRefVerbWithNoTargetNamesBothModes() {
        // Neither ref nor of: the refusal teaches BOTH target modes, so an agent
        // that only knew refs learns the criteria mode from the message itself.
        let result = call("act", ["verb": .string("press")])
        #expect(result.isError)
        #expect(text(result)?.contains("exactly one target") == true)
        #expect(text(result)?.contains("--of") == true)
    }

    @Test func actRefVerbRefusesRefAndOfTogether() {
        let result = call("act", [
            "verb": .string("press"), "ref": .string("e1"),
            "of": .string("button \"Seven\""), "app": .string("com.example.App"),
        ])
        #expect(result.isError)
        // The SAME grammar message the CLI's exit-64 refusal prints.
        #expect(text(result)?.contains("cannot be combined with --of") == true)
    }

    @Test func actOfWithoutAppIsInvalidArgs() {
        let result = call("act", ["verb": .string("press"), "of": .string("button \"Seven\"")])
        #expect(result.isError)
        #expect(text(result)?.contains("--of requires --app") == true)
    }

    @Test func actOfUngrantedNamesAccessibility() {
        // A well-formed criteria target passes the usage gate, so the permission
        // gate fires with the same pinned diagnostic as every other surface —
        // proving the criteria mode routes into the pipeline.
        let result = call("act", [
            "verb": .string("press"), "of": .string("button \"Seven\""),
            "app": .string("com.example.App"),
        ], permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func actSetValueViaOfWithoutValueIsUsageError() {
        // The payload rule outranks the permission gate (usage before permission),
        // and the diagnostic names the --of form.
        let result = call("act", [
            "verb": .string("set-value"), "of": .string("textfield \"Name\""),
            "app": .string("com.example.App"),
        ], permissions: ungranted)
        #expect(result.isError)
        #expect(text(result)?.contains("requires a value") == true)
        #expect(text(result)?.contains("--of") == true)
    }

    @Test func actRefVerbUngrantedNamesAccessibility() {
        // A valid ref token passes the usage gate, so the permission gate fires.
        let result = call("act", ["verb": .string("press"), "ref": .string("e1")], permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func actCoordinateMissingAtIsInvalidArgs() {
        let result = call("act", ["verb": .string("click")])
        #expect(result.isError)
        #expect(text(result)?.contains("requires an 'at'") == true)
    }

    @Test func actMalformedCoordinateIsError() {
        let result = call("act", ["verb": .string("click"), "at": .string("not-a-point")])
        #expect(result.isError)
    }

    @Test func actKeyBadComboIsError() {
        let result = call("act", ["verb": .string("key"), "combo": .string("cmd+nope")])
        #expect(result.isError)
        #expect(text(result)?.contains("invalid key combination") == true)
    }

    // MARK: wait

    @Test func waitMissingAppIsInvalidArgs() {
        let result = call("wait", ["timeout": .string("1s"), "text": .string("hi")])
        #expect(result.isError)
    }

    @Test func waitNoConditionIsInvalidArgs() {
        let result = call("wait", ["app": .string("com.apple.TextEdit"), "timeout": .string("1s")])
        #expect(result.isError)
        #expect(text(result)?.contains("exactly one condition") == true)
    }

    @Test func waitBadTimeoutIsInvalidArgs() {
        let result = call("wait", ["app": .string("com.apple.TextEdit"),
                                    "text": .string("hi"), "timeout": .string("soon")])
        #expect(result.isError)
        #expect(text(result)?.contains("timeout") == true)
    }

    @Test func waitUngrantedNamesAccessibility() {
        let result = call("wait", ["app": .string("com.apple.TextEdit"),
                                    "text": .string("hi"), "timeout": .string("1s")],
                          permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    // MARK: windows

    @Test func windowsMissingAppIsInvalidArgs() {
        let result = call("windows", [:])
        #expect(result.isError)
    }

    @Test func windowsUngrantedNamesAccessibility() {
        let result = call("windows", ["app": .string("com.apple.TextEdit")], permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    // MARK: screenshot (split-grant)

    @Test func screenshotUngrantedScreenRecordingNamesScreenRecording() {
        // Accessibility present but Screen Recording missing: the screenshot tool
        // must name Screen Recording (VAL-MCP-011 split-grant).
        let result = call("screenshot", [:], permissions: axOnly)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .screenRecording).diagnostic)
    }

    // MARK: doctor (report — never isError)

    @Test func doctorIsNeverErrorEvenUngranted() {
        let result = call("doctor", [:], permissions: ungranted)
        #expect(!result.isError)
        // Parity: identical to what the CLI doctor prints.
        #expect(text(result) == DoctorReport(provider: ungranted).textLines().joined(separator: "\n"))
        #expect(text(result)?.contains("Accessibility: missing") == true)
    }

    @Test func doctorJSONMatchesReport() {
        let result = call("doctor", ["json": .bool(true)], permissions: axOnly)
        #expect(!result.isError)
        #expect(text(result) == DoctorReport(provider: axOnly).jsonString())
    }

    // MARK: act menu
    //
    // Only the argument-validation and permission paths are exercised here: a
    // well-formed menu call would drive a real application's menu bar.

    @Test func actMenuMissingPathIsInvalidArgs() {
        let result = call("act", ["verb": .string("menu")])
        #expect(result.isError)
        #expect(text(result)?.contains("requires a 'path'") == true)
    }

    @Test func actMenuMalformedPathIsError() {
        let result = call("act", ["verb": .string("menu"), "path": .string("File>>Save")])
        #expect(result.isError)
        #expect(text(result)?.contains("empty menu segment") == true)
    }

    @Test func actMenuUngrantedNamesAccessibility() {
        let result = call("act", ["verb": .string("menu"), "path": .string("File>Save")],
                          permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    // MARK: app

    @Test func appMissingActionIsInvalidArgs() {
        let result = call("app", ["app": .string("com.apple.TextEdit")])
        #expect(result.isError)
        #expect(text(result)?.contains("requires an 'action'") == true)
    }

    @Test func appMissingBundleIdIsInvalidArgs() {
        let result = call("app", ["action": .string("launch")])
        #expect(result.isError)
        #expect(text(result)?.contains("requires an 'app'") == true)
    }

    @Test func appUnknownActionIsError() {
        let result = call("app", ["action": .string("restart"), "app": .string("com.apple.TextEdit")])
        #expect(result.isError)
        #expect(text(result)?.contains("unknown action 'restart'") == true)
    }

    @Test func appLaunchRefusesAPidRatherThanIgnoringIt() {
        // A pid cannot select an instance that does not exist yet, so silently
        // dropping it would answer a question the client did not ask.
        let result = call("app", ["action": .string("launch"), "app": .string("com.apple.TextEdit"),
                                  "pid": .int(42)])
        #expect(result.isError)
        #expect(text(result)?.contains("does not apply to app launch") == true)
    }

    @Test func appLaunchBadWaitReadyIsInvalidArgs() {
        let result = call("app", ["action": .string("launch"), "app": .string("com.apple.TextEdit"),
                                  "waitReady": .string("soon")])
        #expect(result.isError)
        #expect(text(result)?.contains("waitReady") == true)
    }

    /// A non-running target fails in the SHARED resolver, so the payload is the
    /// CLI's stderr line verbatim — and nothing is activated or terminated.
    @Test func appActivateOfAMissingApplicationMatchesTheCLIDiagnostic() {
        let result = call("app", ["action": .string("activate"), "app": .string("com.example.nope")],
                          permissions: axOnly)
        #expect(result.isError)
        #expect(text(result) == AppNotRunningError(bundleId: "com.example.nope").message)
    }

    /// Activation is accessibility-driven end to end, so the grant gates it.
    @Test func appActivateUngrantedNamesAccessibility() {
        let result = call("app", ["action": .string("activate"), "app": .string("com.example.nope")],
                          permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func appQuitOfAMissingApplicationMatchesTheCLIDiagnostic() {
        let result = call("app", ["action": .string("quit"), "app": .string("com.example.nope")])
        #expect(result.isError)
        #expect(text(result) == AppNotRunningError(bundleId: "com.example.nope").message)
    }

    @Test func appQuitBadTimeoutIsInvalidArgs() {
        let result = call("app", ["action": .string("quit"), "app": .string("com.example.nope"),
                                  "timeout": .string("soon")])
        #expect(result.isError)
        #expect(text(result)?.contains("timeout") == true)
    }

    // MARK: clipboard
    //
    // Only the argument-validation paths are exercised: every other path would
    // read or WRITE the real system pasteboard, which a test run must not clobber.

    @Test func clipboardMissingActionIsInvalidArgs() {
        let result = call("clipboard", [:])
        #expect(result.isError)
        #expect(text(result)?.contains("requires an 'action'") == true)
    }

    @Test func clipboardUnknownActionIsError() {
        let result = call("clipboard", ["action": .string("paste")])
        #expect(result.isError)
        #expect(text(result)?.contains("unknown action 'paste'") == true)
    }

    @Test func clipboardSetWithoutTextIsInvalidArgs() {
        let result = call("clipboard", ["action": .string("set")])
        #expect(result.isError)
        #expect(text(result)?.contains("requires a 'text'") == true)
    }

    // MARK: wait --stable

    @Test func waitStableIsAcceptedAsACondition() {
        // It reaches the permission gate, so the grammar accepted it as the single
        // condition rather than rejecting it as "no condition".
        let result = call("wait", ["app": .string("com.apple.TextEdit"),
                                   "stable": .bool(true), "timeout": .string("1s")],
                          permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func waitStableWithAnotherConditionIsInvalidArgs() {
        let result = call("wait", ["app": .string("com.apple.TextEdit"), "timeout": .string("1s"),
                                   "stable": .bool(true), "text": .string("hi")])
        #expect(result.isError)
        #expect(text(result)?.contains("only one condition") == true)
    }

    @Test func waitStableForLongerThanTimeoutIsInvalidArgs() {
        let result = call("wait", ["app": .string("com.apple.TextEdit"), "timeout": .string("1s"),
                                   "stable": .bool(true), "stableFor": .string("5s")])
        #expect(result.isError)
        #expect(text(result)?.contains("--stable-for") == true)
    }

    @Test func waitStableForWithoutStableIsInvalidArgs() {
        let result = call("wait", ["app": .string("com.apple.TextEdit"), "timeout": .string("5s"),
                                   "text": .string("hi"), "stableFor": .string("1s")])
        #expect(result.isError)
        #expect(text(result)?.contains("--stable-for is only valid") == true)
    }

    @Test func waitStableForMustBeAValidDuration() {
        let result = call("wait", ["app": .string("com.apple.TextEdit"), "timeout": .string("5s"),
                                   "stable": .bool(true), "stableFor": .string("soon")])
        #expect(result.isError)
        #expect(text(result)?.contains("stableFor") == true)
    }

    // MARK: read

    @Test func readWithNoAddressingModeIsInvalidArgs() {
        let result = call("read", [:])
        #expect(result.isError)
        #expect(text(result)?.contains("addressing mode") == true)
    }

    /// The three modes are mutually exclusive on BOTH surfaces, refused by the same
    /// grammar with the same message.
    @Test func readWithTwoAddressingModesNamesTheConflict() {
        let result = call("read", ["ref": .string("e1"), "of": .string("textarea"),
                                   "app": .string("com.example.App")], permissions: axOnly)
        #expect(result.isError)
        #expect(text(result)?.contains("pass only one") == true)
    }

    @Test func readCriteriaWithoutAnAppIsInvalidArgs() {
        let result = call("read", ["of": .string("textarea")], permissions: axOnly)
        #expect(result.isError)
        #expect(text(result)?.contains("--of requires --app") == true)
    }

    /// An empty string selects nothing, so it must not be mistaken for a mode.
    @Test func readWithAnEmptyRefIsNotAnAddressingMode() {
        let result = call("read", ["ref": .string("")], permissions: axOnly)
        #expect(result.isError)
        #expect(text(result)?.contains("addressing mode") == true)
    }

    @Test func readPidWithoutAnAppIsRefused() {
        let result = call("read", ["ref": .string("e1"), "pid": .int(4242)], permissions: axOnly)
        #expect(result.isError)
        #expect(text(result) == "mtouch: invalid arguments: " + AppTarget.pidRequiresAppMessage)
    }

    /// The criteria mode reaches the app-scoped pipeline (not the ref one), so the
    /// permission gate — not a missing-ref complaint — is what answers.
    @Test func readByCriteriaRoutesToTheAppPipeline() {
        let result = call("read", ["app": .string("com.example.App"), "of": .string("group \"answer\"")],
                          permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func readWholeAppRoutesToTheAppPipeline() {
        let result = call("read", ["app": .string("com.example.App")], permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func readUnknownTokenCarriesTheCLIDiagnosticVerbatim() {
        let result = call("read", ["ref": .string("banana")], permissions: axOnly)
        #expect(result.isError)
        #expect(text(result) == ActPipeline.unknownRefDiagnostic("banana"))
    }

    @Test func readUngrantedNamesAccessibility() {
        let result = call("read", ["ref": .string("e1")], permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    @Test func readNoSessionCarriesTheCLIDiagnosticVerbatim() {
        let result = call("read", ["ref": .string("e1")], permissions: axOnly,
                          environment: [MTouchEnvironment.sessionKey: "/nonexistent/mtouch-mcp/none.json"])
        #expect(result.isError)
        #expect(text(result) == ActPipeline.noSessionDiagnostic("e1"))
    }
}

// MARK: - read payload parity (MCP vs CLI pipeline)

@Suite struct MCPReadParityTests {
    /// The MCP tool must return the pipeline's payload byte for byte — the whole
    /// point of the surface being a thin mirror. Driven through a REAL session file
    /// (so the ref resolves) whose recorded process cannot exist, which lands both
    /// surfaces on the same exit-1 diagnostic without any AX access.
    @Test func mcpAndTheCLIPipelineProduceTheIdenticalPayload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtouch-mcp-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("session.json").path
        let tree = [AXNode(role: "AXWindow", title: "W", children: [
            AXNode(role: "AXButton", title: "Save", actionable: true),
        ])]
        try SessionStore.save(Snapshot(roots: tree), app: "com.example.NotReal", pid: 4242, to: path)
        let environment = [MTouchEnvironment.sessionKey: path]

        let pipeline = ReadPipeline.run(
            ref: "e1", json: false, environment: environment, permissions: axOnly
        )
        guard case let .failed(stderr, _) = pipeline else {
            Issue.record("expected the recorded process to be gone"); return
        }
        let result = call("read", ["ref": .string("e1")], permissions: axOnly, environment: environment)
        #expect(result.isError)
        #expect(text(result) == stderr)
    }

    /// The same parity for the criteria mode: a bundle id that names no running
    /// process lands both surfaces on the identical resolution diagnostic, with no
    /// AX access involved.
    @Test func criteriaModeAlsoProducesTheIdenticalPayload() throws {
        let pipeline = ReadPipeline.runApp(
            bundleId: "com.example.NotReal", criteria: WaitCriteria(parsing: "group \"answer\""),
            json: false, permissions: axOnly
        )
        guard case let .failed(stderr, _) = pipeline else {
            Issue.record("expected an unresolvable bundle id"); return
        }
        let result = call("read", ["app": .string("com.example.NotReal"), "of": .string("group \"answer\"")],
                          permissions: axOnly)
        #expect(result.isError)
        #expect(text(result) == stderr)
    }
}

// MARK: - Trajectory classification of the new tools

@Suite struct MCPToolRecordClassTests {
    @Test func lifecycleCallsAreRecordedAsActions() {
        #expect(MCPToolDispatch.trajectoryKind(forTool: "app") == .action)
    }

    /// `clipboard` is the one tool whose record class depends on its arguments, so
    /// `clipboard get` stays a READ on both surfaces (CLI parity) while the write
    /// verbs are actions.
    @Test func clipboardReadsAndWritesAreClassifiedByAction() {
        #expect(MCPToolDispatch.trajectoryKind(
            forTool: "clipboard", arguments: ToolArguments(["action": .string("get")])) == .read)
        #expect(MCPToolDispatch.trajectoryKind(
            forTool: "clipboard", arguments: ToolArguments(["action": .string("set")])) == .action)
        #expect(MCPToolDispatch.trajectoryKind(
            forTool: "clipboard", arguments: ToolArguments(["action": .string("clear")])) == .action)
    }

    @Test func theArgumentAwareClassifierAgreesWithTheNameOnlyOneElsewhere() {
        for tool in ["snapshot", "act", "screenshot", "wait", "apps", "windows", "doctor", "app", "read"] {
            #expect(MCPToolDispatch.trajectoryKind(forTool: tool, arguments: ToolArguments())
                == MCPToolDispatch.trajectoryKind(forTool: tool), "\(tool) must classify identically")
        }
    }
}

// MARK: - pid targeting over MCP (CLI parity)

/// A pid no process can hold (pids stay far below Int32.max), so these exercise
/// the targeting seam without any live process, AX call, or TCC grant.
private let absentPID: pid_t = 2_147_483_647

@Suite struct MCPPidTargetingTests {
    /// The pid reaches the SAME resolver the CLI uses, so the payload is the CLI's
    /// stderr line verbatim — an agent switching surfaces re-learns nothing.
    @Test func unknownPidYieldsTheSameDiagnosticTheCLIPrints() {
        let result = call("windows", ["app": .string("com.google.Chrome"), "pid": .int(Int(absentPID))],
                          permissions: axOnly)
        #expect(result.isError)
        #expect(text(result) == PidNotRunningError(pid: absentPID).message)
    }

    /// The permission gate still precedes targeting, so a pid cannot smuggle a
    /// tool past a missing grant.
    @Test func pidDoesNotBypassThePermissionGate() {
        let result = call("windows", ["app": .string("com.google.Chrome"), "pid": .int(Int(absentPID))],
                          permissions: ungranted)
        #expect(result.isError)
        #expect(text(result) == PermissionError(permission: .accessibility).diagnostic)
    }

    /// Same seam on the other app-scoped tools.
    @Test func snapshotAndWaitAcceptThePidToo() {
        let snapshot = call("snapshot", ["app": .string("com.google.Chrome"), "pid": .int(Int(absentPID))],
                            permissions: axOnly)
        #expect(snapshot.isError)
        #expect(text(snapshot) == PidNotRunningError(pid: absentPID).message)

        let wait = call("wait", ["app": .string("com.google.Chrome"), "pid": .int(Int(absentPID)),
                                 "text": .string("hi"), "timeout": .string("1s")],
                        permissions: axOnly)
        #expect(wait.isError)
        #expect(text(wait) == PidNotRunningError(pid: absentPID).message)
    }

    /// A pid sent as a JSON string still coerces (the lenient accessor contract).
    @Test func pidAcceptsAStringifiedInteger() {
        let result = call("windows", ["app": .string("com.google.Chrome"), "pid": .string("\(absentPID)")],
                          permissions: axOnly)
        #expect(result.isError)
        #expect(text(result) == PidNotRunningError(pid: absentPID).message)
    }

    /// A non-integer pid is a domain (invalid-argument) failure, the analogue of
    /// the CLI's parse-time usage error.
    @Test func nonIntegerPidIsInvalidArgs() {
        let result = call("windows", ["app": .string("com.google.Chrome"), "pid": .string("nope")],
                          permissions: axOnly)
        #expect(result.isError)
        #expect(text(result)?.contains("invalid arguments") == true)
        #expect(text(result)?.contains("'pid'") == true)
    }

    /// A pid out of process-id range cannot name a process, so it is refused
    /// rather than truncated into some OTHER process's id.
    @Test func outOfRangePidIsInvalidArgs() {
        let result = call("windows", ["app": .string("com.google.Chrome"), "pid": .int(9_999_999_999)],
                          permissions: axOnly)
        #expect(result.isError)
        #expect(text(result)?.contains("invalid arguments") == true)
    }

    /// `act` mirrors the CLI's `OptionalAppOptions`: a pid with no app to check it
    /// against is refused, not trusted blindly.
    @Test func actRefusesAPidWithoutAnApp() {
        let result = call("act", ["verb": .string("click"), "at": .string("10,10"), "pid": .int(Int(absentPID))],
                          permissions: axOnly)
        #expect(result.isError)
        #expect(text(result)?.contains(AppTarget.pidRequiresAppMessage) == true)
    }

    /// With an app, `act`'s coordinate verb resolves through the same seam.
    @Test func actCoordinateVerbHonorsThePid() {
        let result = call("act", ["verb": .string("click"), "at": .string("10,10"),
                                  "app": .string("com.google.Chrome"), "pid": .int(Int(absentPID))],
                          permissions: axOnly, environment: [MTouchEnvironment.sessionKey: "/nonexistent/session.json"])
        #expect(result.isError)
        #expect(text(result) == PidNotRunningError(pid: absentPID).message)
    }
}
