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

    /// The subset of `actVerbs` that can target an element BY CRITERIA (`of`), and
    /// therefore the only ones for which `wait`/`interval` mean anything: the rest
    /// address screen points, the focused element, or a menu title path.
    public static let criteriaVerbs = ["press", "focus", "show-menu", "set-value"]

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
                + "assigning element references (e.g. e5) usable by the act tool. "
                + "Each line labels its element with the first of title, value, "
                + "accessibility description, or developer identifier that it has; a "
                + "label taken from the last two is marked @desc or @id, so 'AXButton "
                + "\"Seven\"@id' is a button with no title whose identifier is Seven. "
                + "Quote that same label in a wait/read criteria to address it. With "
                + "json every attribute is a separate field instead.",
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
                + "target an element reference from a prior snapshot, or — via of — the single "
                + "element matching a criteria, with no snapshot at all; coordinate verbs "
                + "(click, rightclick, doubleclick, drag, scroll) target screen points; "
                + "keyboard verbs (type, key) target the focused element; menu invokes a "
                + "menu-bar command by title path (the reliable way to drive an application "
                + "whose content area is not exposed over the accessibility API).",
            properties: [
                Property(name: "verb", type: "string",
                         description: "The action to perform.", enumValues: actVerbs),
                Property(name: "ref", type: "string",
                         description: "Element reference from a prior snapshot (ref verbs)."),
                Property(name: "of", type: "string",
                         description: "Criteria alternative to ref for the ref verbs: act on the SINGLE "
                             + "element matching it (same grammar as wait/read, e.g. 'button \"Seven\"'), "
                             + "resolved against a fresh walk — no snapshot needed. Requires app; mutually "
                             + "exclusive with ref. Several matches, or none: the tool refuses and acts "
                             + "on nothing."),
                Property(name: "wait", type: "string",
                         description: "Wait up to this long (e.g. 5s, 500ms) for 'of' to match exactly "
                             + "one actionable element, then act on it — one call instead of a wait "
                             + "followed by an act, with the criteria written once. Requires of; a ref "
                             + "addresses a snapshot already taken, so there is nothing to wait for. "
                             + "SEVERAL matches keep waiting too (duplicates are often transient while a "
                             + "screen renders); on expiry the error says whether the criteria never "
                             + "appeared or was ambiguous, and lists the candidates when it was. Without "
                             + "wait, zero or several matches refuse immediately as they always have."),
                Property(name: "interval", type: "string",
                         description: "Polling interval for wait (default 100ms). Requires wait."),
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
                Property(
                    name: "noVerify", type: "boolean",
                    description: "Deliver the input WITHOUT reading the accessibility tree: no diff is taken "
                        + "and none is reported. Use it when the target is showing a modal panel, whose "
                        + "nested event loop blocks the accessibility server so every read times out. The "
                        + "effect of the action is NOT verified — snapshot afterwards to see what happened. "
                        + "Accepted only by the verbs that synthesize input directly ("
                        + UnverifiedDelivery.verbs.joined(separator: ", ") + "); the ref verbs and menu "
                        + "refuse it, because they read the tree to find their target."
                ),
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
                         description: "Wait until an element matching this criteria appears, e.g. "
                             + "'button \"Save\"'. The quoted substring is matched over the element's "
                             + "title, value, description, and identifier — including a label snapshot "
                             + "marked @desc or @id."),
                Property(name: "disappears", type: "string",
                         description: "Wait until an element matching this criteria disappears."),
                Property(name: "text", type: "string",
                         description: "Wait until this text becomes visible. Matched over title and "
                             + "value only — the strings a user can see — never over a developer "
                             + "identifier."),
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
            description: "Print the full, untruncated text of a referenced element, of every element "
                + "matching a criteria, or of a whole application, in document order. Use it when the "
                + "snapshot's node budget has dropped the text you need: snapshot renders one line per "
                + "node and drops non-actionable nodes (long static text) first. Address the text one of "
                + "three mutually exclusive ways: 'ref'; 'app' + 'of'; or 'app' alone for every window. "
                + "Prefer 'of' when the text has no reference — references are issued only to ACTIONABLE "
                + "elements, and long prose usually sits under inert containers that have none. "
                + "Reading changes nothing — no activation, no input, and the session's references are "
                + "left as they were.",
            properties: [
                Property(name: "ref", type: "string",
                         description: "Element reference from a prior snapshot, e.g. e5."),
                Property(name: "app", type: "string",
                         description: "Bundle identifier of the target application. Required by 'of', and "
                             + "on its own reads every window of the application."),
                pidProperty,
                Property(name: "of", type: "string",
                         description: "Read every element matching this criteria, e.g. 'group \"answer\"' "
                             + "(the same criteria grammar the wait tool takes, matched over title, "
                             + "value, description, and identifier). EVERY match is returned, "
                             + "in document order — several matches are separated by a blank line, or come "
                             + "back as an array of {role, text} with json. Nothing matching is an error "
                             + "naming the criteria, never an empty result."),
                jsonProperty,
            ],
            // No property is required: the addressing grammar (exactly one of ref /
            // app+of / app) is richer than a required-set can express, so it is
            // enforced at call time with a message that names the conflict.
            required: []
        ),
    ]

    /// The advertised tool names, in catalog order.
    public static var toolNames: [String] { tools.map(\.name) }
}
