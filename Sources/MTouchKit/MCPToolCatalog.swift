/// The static description of the tools the MCP surface exposes.
///
/// The catalog is the SINGLE source of truth for the tool set: the executable's
/// MCP entry renders each `ToolSpec` into the SDK's hand-written JSON-Schema
/// `Value` for `tools/list`, and `MCPToolDispatch` switches on the same names for
/// `tools/call`. Keeping it here (MCP-SDK-free) makes the tool set — names,
/// required arguments, schema shape — unit-testable without the transport.
public enum MCPToolCatalog {
    /// One property of a tool's input schema. `type` is a JSON-Schema primitive
    /// (`string` / `boolean` / `integer`); `enumValues`, when present, constrains
    /// the accepted strings (used by `act.verb`).
    public struct Property: Equatable, Sendable {
        public let name: String
        public let type: String
        public let description: String
        public let enumValues: [String]?

        public init(name: String, type: String, description: String, enumValues: [String]? = nil) {
            self.name = name
            self.type = type
            self.description = description
            self.enumValues = enumValues
        }
    }

    /// One tool: its name, human description, input properties, and the subset of
    /// property names that are required. Mirrors the corresponding CLI command.
    public struct Spec: Equatable, Sendable {
        public let name: String
        public let description: String
        public let properties: [Property]
        public let required: [String]

        public init(name: String, description: String, properties: [Property], required: [String]) {
            self.name = name
            self.description = description
            self.properties = properties
            self.required = required
        }
    }

    /// The verbs the `act` tool accepts, mirroring the CLI `act` grammar
    /// (ref-based, coordinate-based, keyboard, and menu-path verbs).
    public static let actVerbs = [
        "press", "focus", "show-menu", "set-value",
        "click", "rightclick", "doubleclick", "drag", "scroll",
        "type", "key", "menu",
    ]

    /// A reusable `--json` flag property.
    private static let jsonProperty = Property(
        name: "json", type: "boolean",
        description: "Emit machine-readable JSON output instead of the compact text format."
    )

    /// The optional `--pid` disambiguator, mirroring the CLI. Every app-scoped tool
    /// carries it: a bundle id can name several live processes, and the tool refuses
    /// to guess between them. Adding this property changes no tool's NAME and no
    /// tool's `required` set — the advertised toolset is unchanged.
    private static let pidProperty = Property(
        name: "pid", type: "integer",
        description: "Process id of the target instance. Overrides bundle-id resolution; required when "
            + "several running processes share the bundle id (the apps tool lists them)."
    )

    /// The tools, in a stable order. EXACTLY this set is advertised by
    /// `tools/list` — no more, no fewer. New tools are APPENDED so an existing
    /// client's view of the earlier ones never shifts.
    public static let tools: [Spec] = [
        Spec(
            name: "snapshot",
            description: "Capture an accessibility snapshot of an application, "
                + "assigning element references (e.g. e5) usable by the act tool.",
            properties: [
                Property(name: "app", type: "string",
                         description: "Bundle identifier of the target application, e.g. com.apple.TextEdit."),
                pidProperty,
                jsonProperty,
            ],
            required: ["app"]
        ),
        Spec(
            name: "act",
            description: "Perform a UI action. Ref verbs (press, focus, show-menu, set-value) "
                + "target an element reference from a prior snapshot; coordinate verbs "
                + "(click, rightclick, doubleclick, drag, scroll) target screen points; "
                + "keyboard verbs (type, key) target the focused element; menu invokes a "
                + "menu-bar command by title path (the reliable way to drive an application "
                + "whose content area is not exposed over the accessibility API).",
            properties: [
                Property(name: "verb", type: "string",
                         description: "The action to perform.", enumValues: actVerbs),
                Property(name: "ref", type: "string",
                         description: "Element reference from a prior snapshot (ref verbs)."),
                Property(name: "value", type: "string",
                         description: "Value payload for set-value."),
                Property(name: "at", type: "string",
                         description: "Screen coordinate 'x,y' for click/rightclick/doubleclick/scroll."),
                Property(name: "from", type: "string",
                         description: "Start screen coordinate 'x,y' for drag."),
                Property(name: "to", type: "string",
                         description: "End screen coordinate 'x,y' for drag."),
                Property(name: "dy", type: "integer",
                         description: "Vertical scroll delta for scroll (positive scrolls content up)."),
                Property(name: "text", type: "string",
                         description: "Literal text to type."),
                Property(name: "combo", type: "string",
                         description: "Key combination for key, e.g. 'cmd+shift+t'."),
                Property(name: "path", type: "string",
                         description: "Menu title path for menu, '>'-separated, e.g. 'File>Save'. "
                             + "Titles are user-visible and may be localized; they are matched "
                             + "exactly first, then case-insensitively."),
                Property(name: "app", type: "string",
                         description: "Bundle identifier override for coordinate/keyboard verbs."),
                pidProperty,
                jsonProperty,
            ],
            required: ["verb"]
        ),
        Spec(
            name: "wait",
            description: "Wait for a UI condition in an application. Provide exactly one of "
                + "appears, disappears, text, valueEquals, or stable.",
            properties: [
                Property(name: "app", type: "string",
                         description: "Bundle identifier of the target application."),
                pidProperty,
                Property(name: "appears", type: "string",
                         description: "Wait until an element matching this criteria appears, e.g. 'button \"Save\"'."),
                Property(name: "disappears", type: "string",
                         description: "Wait until an element matching this criteria disappears."),
                Property(name: "text", type: "string",
                         description: "Wait until this text becomes visible."),
                Property(name: "valueEquals", type: "string",
                         description: "Wait until an element's value equals this string."),
                Property(name: "stable", type: "boolean",
                         description: "Wait until the watched tree STOPS CHANGING (quiescence). Use this after "
                             + "text/appears when content streams in: text matches the first fragment, so "
                             + "reading straight after it yields a half-written result. Any change restarts "
                             + "the quiet window, and an 'of' criteria that matches nothing keeps waiting "
                             + "rather than succeeding."),
                Property(name: "of", type: "string",
                         description: "Restrict valueEquals or stable to elements matching this criteria."),
                Property(name: "stableFor", type: "string",
                         description: "How long stable requires the tree to stay unchanged (default 500ms). "
                             + "May equal timeout but not exceed it."),
                Property(name: "timeout", type: "string",
                         description: "Maximum time to wait, e.g. 5s or 500ms."),
                Property(name: "interval", type: "string",
                         description: "Polling interval (default 100ms)."),
            ],
            required: ["app", "timeout"]
        ),
        Spec(
            name: "screenshot",
            description: "Capture a PNG screenshot of the main display or a single window. "
                + "Returns the written file path and the image bytes.",
            properties: [
                Property(name: "window", type: "string",
                         description: "CGWindowID of the window to capture (from the windows tool). "
                             + "Omit to capture the main display."),
                Property(name: "out", type: "string",
                         description: "Destination path. PNG bytes are written regardless of extension."),
            ],
            required: []
        ),
        Spec(
            name: "apps",
            description: "List running applications with their bundle identifiers and pids.",
            properties: [jsonProperty],
            required: []
        ),
        Spec(
            name: "windows",
            description: "List the windows of an application with their ids, titles, and frames.",
            properties: [
                Property(name: "app", type: "string",
                         description: "Bundle identifier of the target application."),
                pidProperty,
                jsonProperty,
            ],
            required: ["app"]
        ),
        Spec(
            name: "doctor",
            description: "Report environment health and permission (Accessibility, Screen Recording) status.",
            properties: [jsonProperty],
            required: []
        ),
        Spec(
            name: "app",
            description: "Control an application's lifecycle: launch it (reporting its pid), bring it "
                + "frontmost (verified — it fails rather than reporting an activation that did not "
                + "take), or quit it (waiting until its process is gone).",
            properties: [
                Property(name: "action", type: "string",
                         description: "The lifecycle verb to perform.",
                         enumValues: ["launch", "activate", "quit"]),
                Property(name: "app", type: "string",
                         description: "Bundle identifier of the target application."),
                pidProperty,
                Property(name: "waitReady", type: "string",
                         description: "For launch: wait until the application reports at least one "
                             + "window, e.g. 15s. Requires the Accessibility permission."),
                Property(name: "force", type: "boolean",
                         description: "For quit: force-terminate if the application does not quit "
                             + "within timeout. DESTRUCTIVE — unsaved work is lost."),
                Property(name: "timeout", type: "string",
                         description: "For quit: how long to wait for a graceful quit (default 10s)."),
                jsonProperty,
            ],
            required: ["action", "app"]
        ),
        Spec(
            name: "clipboard",
            description: "Read, write, or clear the clipboard's text — the reliable way to move text "
                + "into an application whose text area is not addressable (write it here, then paste "
                + "with act key cmd+v). Every write is read back and verified.",
            properties: [
                Property(name: "action", type: "string",
                         description: "The clipboard verb to perform.",
                         enumValues: ["get", "set", "clear"]),
                Property(name: "text", type: "string",
                         description: "Text to put on the clipboard (set)."),
                jsonProperty,
            ],
            required: ["action"]
        ),
        Spec(
            name: "read",
            description: "Print the full, untruncated text of a referenced element's subtree, in document "
                + "order. Use it when the snapshot's node budget has dropped the text you need: snapshot "
                + "renders one line per node and drops non-actionable nodes (long static text) first. "
                + "Reading changes nothing — no activation, no input, and the session's references are "
                + "left as they were.",
            properties: [
                Property(name: "ref", type: "string",
                         description: "Element reference from a prior snapshot, e.g. e5."),
                jsonProperty,
            ],
            required: ["ref"]
        ),
    ]

    /// The advertised tool names, in catalog order.
    public static var toolNames: [String] { tools.map(\.name) }
}
