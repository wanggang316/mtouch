import Foundation

/// One validated batch step: an MCP-shaped tool call. `tool` names one of the ten
/// MCP tools and `arguments` carries exactly what a `tools/call` client would
/// send, so a step's payload is byte-identical to both existing surfaces and
/// every current capability works in a batch with no per-verb work.
public struct BatchStep: Sendable {
    /// 1-based PHYSICAL line in the input (blank lines count), so a runtime
    /// diagnostic can point back at the file the user wrote.
    public let line: Int
    public let tool: String
    public let arguments: ToolArguments

    public init(line: Int, tool: String, arguments: ToolArguments) {
        self.line = line
        self.tool = tool
        self.arguments = arguments
    }
}

/// A batch input that failed validation. Always a USAGE error (exit 64), raised
/// before any step runs: a typo must not leave a half-executed flow.
public struct BatchScriptError: Error, Equatable {
    /// Stderr diagnostic, in the project's `mtouch: …` voice, naming the line.
    public let diagnostic: String

    public init(_ diagnostic: String) {
        self.diagnostic = diagnostic
    }
}

/// Parses a batch script — JSON Lines, one `{"tool":…,"arguments":{…}}` object
/// per line — validating the WHOLE input up front. Any malformed line, unknown
/// tool, unknown key, or non-object `arguments` value rejects the entire batch
/// (nothing executes), and zero steps is the same usage error: an empty batch is
/// an invocation mistake, not a successful no-op.
public enum BatchScript {
    /// The keys a step object may carry. Anything else is rejected — an
    /// unrecognized key is most likely a misspelling of one of these, and a
    /// misspelled `arguments` silently becoming an empty argument set would fail
    /// only MID-RUN, exactly the half-executed flow validation exists to prevent.
    private static let stepKeys: Set<String> = ["tool", "arguments"]

    public static func parse(_ input: String) throws -> [BatchStep] {
        var steps: [BatchStep] = []
        // Physical line numbering: blank lines are skipped but still counted, so
        // a diagnostic's "line 3" is line 3 of the file the user is looking at.
        for (index, rawLine) in input.components(separatedBy: "\n").enumerated() {
            let line = index + 1
            guard !rawLine.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            steps.append(try parseStep(rawLine, line: line))
        }
        guard !steps.isEmpty else {
            throw BatchScriptError(
                "mtouch: batch: no steps; provide one JSON object per line: {\"tool\":\"…\",\"arguments\":{…}}."
            )
        }
        return steps
    }

    private static func parseStep(_ rawLine: String, line: Int) throws -> BatchStep {
        // `.fragmentsAllowed` so a scalar line ("42") parses and is answered by
        // the shape check below, distinguishing "not JSON" from "not an object".
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(rawLine.utf8), options: [.fragmentsAllowed])
        } catch {
            throw BatchScriptError("mtouch: batch: line \(line) is not valid JSON.")
        }
        guard let object = parsed as? [String: Any] else {
            throw BatchScriptError(
                "mtouch: batch: line \(line) is not a JSON object; expected {\"tool\":\"…\",\"arguments\":{…}}."
            )
        }
        for key in object.keys.sorted() where !stepKeys.contains(key) {
            throw BatchScriptError(
                "mtouch: batch: line \(line): unknown key '\(key)'; a step has only 'tool' and 'arguments'."
            )
        }
        guard let toolValue = object["tool"] else {
            throw BatchScriptError("mtouch: batch: line \(line): missing 'tool'.")
        }
        guard let tool = toolValue as? String else {
            throw BatchScriptError("mtouch: batch: line \(line): 'tool' must be a string.")
        }
        // The valid set is EXACTLY the MCP catalog: batch adds throughput, never
        // vocabulary. Same wording as the MCP surface's unknown-tool refusal.
        guard MCPToolCatalog.toolNames.contains(tool) else {
            throw BatchScriptError(
                "mtouch: batch: line \(line): unknown tool '\(tool)'. Available tools: "
                    + MCPToolCatalog.toolNames.joined(separator: ", ") + "."
            )
        }
        var arguments = ToolArguments()
        if let argumentsValue = object["arguments"] {
            guard let argumentsObject = argumentsValue as? [String: Any] else {
                throw BatchScriptError("mtouch: batch: line \(line): 'arguments' must be a JSON object.")
            }
            arguments = ToolArguments(argumentsObject.mapValues(convert))
        }
        return BatchStep(line: line, tool: tool, arguments: arguments)
    }

    /// Narrow a parsed JSON value to the primitives `ToolArguments` accepts —
    /// the SAME narrowing the MCP entry applies to the SDK's values, so a payload
    /// means the same thing on both surfaces (null/array/object become `.other`).
    private static func convert(_ value: Any) -> ToolArgumentValue {
        if let string = value as? String { return .string(string) }
        if let number = value as? NSNumber {
            // A JSON bool bridges to NSNumber too, so the boolean type is checked
            // FIRST — `true` must stay a bool, not collapse into the int 1.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            if let int = Int(exactly: number) { return .int(int) }
            return .double(number.doubleValue)
        }
        return .other
    }
}
