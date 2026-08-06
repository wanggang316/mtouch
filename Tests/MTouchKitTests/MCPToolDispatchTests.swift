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

@Suite struct MCPToolCatalogTests {
    @Test func advertisesExactlyTheSevenTools() {
        #expect(MCPToolCatalog.toolNames == [
            "snapshot", "act", "wait", "screenshot", "apps", "windows", "doctor",
        ])
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
    }

    @Test func actVerbEnumCoversTheGrammar() {
        let actSpec = MCPToolCatalog.tools.first { $0.name == "act" }!
        let verb = actSpec.properties.first { $0.name == "verb" }!
        #expect(verb.enumValues == [
            "press", "focus", "show-menu", "set-value",
            "click", "rightclick", "doubleclick", "drag", "scroll",
            "type", "key",
        ])
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

    @Test func actRefVerbMissingRefIsInvalidArgs() {
        let result = call("act", ["verb": .string("press")])
        #expect(result.isError)
        #expect(text(result)?.contains("requires a 'ref'") == true)
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
}
