import ApplicationServices
import Foundation

/// The observable outcome of a `read` invocation, kept SEPARATE from the side
/// effects (printing, exiting) so the exit-code mapping is unit-testable. A
/// failure NEVER carries stdout, so a `--json` error keeps stdout empty.
public enum ReadOutcome: Equatable, Sendable {
    /// The text (or JSON) to write to stdout; exit 0.
    case read(String)
    /// A stderr diagnostic paired with its non-zero exit code.
    case failed(stderr: String, code: MTouchExitCode)
}

/// The text an element's subtree carries, in document order.
///
/// This is the "what does this element SAY" projection, deliberately distinct
/// from the snapshot's "what is in this tree" projection: no roles, no geometry,
/// no refs, no node budget — just the readable strings, one logical block per
/// line. It exists because the snapshot text surface renders one line per NODE
/// under a node budget (`SnapshotText.maxNodes`), and a long answer is a pile of
/// non-actionable `AXStaticText` nodes — exactly what that budget drops first.
public enum ElementText {
    /// The subtree's text blocks in pre-order (parent before children, children
    /// left to right), with empty blocks skipped and a block that exactly repeats
    /// the one before it collapsed.
    ///
    /// The collapse is load-bearing, not cosmetic: real trees routinely label a
    /// container with the very string its only text child carries (an
    /// `AXGroup "Copy"` wrapping an `AXStaticText "Copy"`), and emitting both would
    /// double every such label in the middle of the prose an agent is trying to
    /// read. Only IMMEDIATELY-consecutive repeats collapse, so genuinely separated
    /// repetitions of the same string all survive.
    public static func blocks(of node: AXNode) -> [String] {
        var out: [String] = []
        func visit(_ node: AXNode) {
            if let block = block(of: node), block != out.last { out.append(block) }
            for child in node.children { visit(child) }
        }
        visit(node)
        return out
    }

    /// The subtree's text blocks joined one per line.
    public static func render(_ node: AXNode) -> String {
        blocks(of: node).joined(separator: "\n")
    }

    /// One node's own text: its VALUE when it has a non-blank one, else its TITLE.
    /// Value wins because it is the element's CONTENT while a title is typically
    /// its label — reading a text area should yield what is typed in it, not the
    /// word next to it. Blank/whitespace-only strings contribute nothing.
    ///
    /// The value is read through `SecureField.renderedValue`, so a secure field
    /// contributes its MASK and never its secret — this surface leaks no more than
    /// snapshot text or JSON does.
    static func block(of node: AXNode) -> String? {
        if let value = SecureField.renderedValue(of: node), !isBlank(value) { return value }
        if let title = node.title, !isBlank(title) { return title }
        return nil
    }

    private static func isBlank(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Which elements a criteria/whole-app read renders, chosen from a walked tree.
///
/// Pure and AX-free so the selection rules — outermost-match-wins, windows-only
/// for the whole-app mode — are unit-testable with literal `AXNode` fixtures.
public enum ReadSelection {
    /// The elements to render, in document order.
    ///
    /// With a criteria: every element matching it (same predicate `wait` uses),
    /// except that a match INSIDE another match is skipped — its text is already
    /// contained in its ancestor's rendering, so emitting both would print the same
    /// prose twice. Nothing is lost by the skip; a duplicated answer would be the
    /// quiet wrong result.
    ///
    /// Without a criteria: the application's WINDOW roots. The menu bar is app
    /// chrome that every application carries, so dumping it into "everything on
    /// screen as text" would bury the content the caller asked for. A criteria,
    /// being explicit, may still reach into it.
    public static func elements(in roots: [AXNode], matching criteria: WaitCriteria?) -> [AXNode] {
        guard let criteria else { return roots.filter { $0.role != kAXMenuBarRole } }
        var matched: [AXNode] = []
        func visit(_ node: AXNode) {
            if WaitEvaluator.matches(node, criteria) {
                matched.append(node)
                return
            }
            for child in node.children { visit(child) }
        }
        for root in roots { visit(root) }
        return matched
    }
}

/// Composes `read` end-to-end: resolve the ref against the session → confirm the
/// process is alive → walk → re-locate the element → render its subtree's text.
///
/// It reuses `ActPipeline`'s ref machinery wholesale (`resolveRefTarget`,
/// `ElementRelocation`, and every diagnostic string), so an agent that knows how
/// `act` fails already knows how `read` fails: the same malformed token is exit
/// 64, the same stale ref is exit 3, the same absent session is exit 3, the same
/// dead process is exit 1 — byte for byte.
///
/// It is a pure READ: it never activates the app, never synthesizes input, and —
/// unlike every `act` verb — never persists a new session. Reading must not
/// renumber the refs an agent is holding.
///
/// `runApp` is the non-ref half of the same command (read by criteria, or the whole
/// application); both halves share `ElementText` for the rendering itself.
public enum ReadPipeline {
    /// Printed when the element's subtree carries no text at all, so output is
    /// never silently blank (mirroring `SnapshotText.emptyTreeMarker`).
    public static let emptyMarker = "(no text content)"

    public static func run(
        ref: String,
        json: Bool,
        environment: [String: String],
        permissions: PermissionProvider = LivePermissionProvider(),
        loadSession: (String) -> Session? = { SessionStore.load(from: $0) },
        isRunning: (pid_t, String) -> Bool = { ActProcess.isRunning(pid: $0, bundleId: $1) },
        walkLive: (pid_t) -> LiveElementTree? = { pid in BoundedWalk.run { LiveElementTree.walk(pid: pid) } }
    ) -> ReadOutcome {
        let entry: RefEntry
        let session: Session
        switch ActPipeline.resolveRefTarget(
            ref: ref, environment: environment, permissions: permissions, loadSession: loadSession
        ) {
        case let .terminal(outcome):
            return fromAct(outcome)
        case let .resolved(resolvedEntry, resolvedSession, _):
            entry = resolvedEntry
            session = resolvedSession
        }

        // The ref namespace is session-scoped, so the target app is the one the
        // snapshot was taken from.
        let pid = session.pid
        let app = session.app

        // Runtime (exit 1): the snapshotted process is gone.
        guard isRunning(pid, app) else {
            return .failed(stderr: ActPipeline.notRunningDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }

        // A wedged target surfaces as an explicit bounded timeout, never a hang.
        guard let liveTree = walkLive(pid) else {
            return .failed(stderr: ActPipeline.timeoutDiagnostic(app: app, pid: pid), code: .runtimeFailure)
        }

        // Re-locate the SAME element by its hints. A miss means the element is gone:
        // exit 3, exactly as act reports it — we never read the impostor now
        // occupying that position.
        guard let path = ElementRelocation.locatePath(
                  entry, in: liveTree.attributesByPath, windowIDsByPath: liveTree.windowIDsByPath
              ),
              let node = node(at: path, in: liveTree.nodes) else {
            return .failed(stderr: ActPipeline.goneRefDiagnostic(ref), code: .refError)
        }

        let text = ElementText.render(node)
        if json {
            return .read(
                "{\"ref\":\(JSONText.string(ref)),"
                    + "\"role\":\(JSONText.string(node.role)),"
                    + "\"text\":\(JSONText.string(text))}"
            )
        }
        return .read(text.isEmpty ? emptyMarker : text)
    }

    /// Reads text WITHOUT a ref: every element matching `criteria` inside the
    /// application, or — when `criteria` is nil — every one of its windows.
    ///
    /// This exists because refs are issued only to ACTIONABLE elements (a pinned
    /// rule: issuing one per node would explode the ref space), while long prose
    /// routinely sits under a chain of inert containers whose refs are all nil up to
    /// the window. That text is unreachable by ref, so it is addressed by criteria
    /// instead — the SAME criteria grammar `wait --of` uses, matched by the same
    /// predicate, rendered by the same `ElementText`. It shares the render step with
    /// `run(ref:)`, so the two modes cannot drift.
    ///
    /// Precedence matches the rest of the CLI: the addressing grammar (exit 64) is
    /// rejected by the command layer BEFORE this runs; here the permission gate
    /// (exit 2) precedes app resolution (exit 1), which precedes the walk and the
    /// match (exit 0, or exit 1 when nothing matched).
    ///
    /// Like every `read` mode this is a pure READ: no activation, no input, no
    /// session written — the refs an agent is holding survive it untouched.
    public static func runApp(
        bundleId: String,
        criteria: WaitCriteria?,
        json: Bool,
        permissions: PermissionProvider = LivePermissionProvider(),
        resolvePID: (String) throws -> pid_t = { try AXWindowEnumerator.resolveRunningPID(bundleId: $0) },
        walk: (pid_t) -> WalkResult? = { pid in BoundedWalk.run { AXTreeWalker.walk(pid: pid) } },
        diagnoseEmptyTree: (pid_t) -> AXReadFailure? = { AXWindowEnumerator.readFailure(ofPID: $0) }
    ) -> ReadOutcome {
        // 1. Preflight FIRST (exit 2): a missing grant fails fast with the
        //    doctor-pointing diagnostic, never as an empty read.
        guard permissions.accessibilityGranted else {
            return .failed(
                stderr: PermissionError(permission: .accessibility).diagnostic,
                code: .permissionMissing
            )
        }

        // 2. Resolve the bundle id to a running pid; each resolution failure carries
        //    its own exit code (1 for a missing/ambiguous target, 64 for a `--pid`
        //    that contradicts `--app`).
        let pid: pid_t
        do {
            pid = try resolvePID(bundleId)
        } catch let error as MTouchDiagnosticError {
            return .failed(stderr: error.message, code: error.exitCode)
        } catch {
            return .failed(
                stderr: "mtouch: could not resolve application '\(bundleId)': \(error)",
                code: .runtimeFailure
            )
        }

        // 3. A wedged target surfaces as an explicit bounded timeout, never a hang.
        guard let result = walk(pid) else {
            return .failed(stderr: appTimeoutDiagnostic(app: bundleId, pid: pid), code: .runtimeFailure)
        }

        // 4. NO roots at all is ambiguous — an app that exposes nothing looks exactly
        //    like one whose accessibility interface refused every read — so ask the
        //    app element directly and name a REFUSED read instead of reporting
        //    "nothing matched" for a question that was never answered.
        if result.nodes.isEmpty, let failure = diagnoseEmptyTree(pid) {
            return .failed(
                stderr: failure.diagnostic(reading: "the accessibility tree", of: bundleId),
                code: .runtimeFailure
            )
        }

        // 5. Zero matches is a FAILURE (exit 1), not an empty success: an agent must
        //    be able to tell "this element holds no text" from "no such element".
        let matched = ReadSelection.elements(in: result.nodes, matching: criteria)
        guard !matched.isEmpty else {
            return .failed(
                stderr: noMatchDiagnostic(criteria: criteria, app: bundleId, roots: result.nodes),
                code: .runtimeFailure
            )
        }
        return render(matched, json: json)
    }

    /// Renders the matched elements: text mode joins each one's rendering with a
    /// BLANK LINE between matches (so an agent can tell where one ends), JSON mode
    /// emits an ARRAY of `{role, text}` — never a silently-chosen first match.
    ///
    /// A match whose subtree carries no text contributes nothing to the text join
    /// (it would only add blank lines); the JSON array still carries it with an
    /// empty string, keeping the machine surface complete. All matches textless ⇒
    /// the empty marker, exactly as `read <ref>` reports a textless subtree.
    static func render(_ matched: [AXNode], json: Bool) -> ReadOutcome {
        if json {
            let objects = matched.map { node in
                "{\"role\":\(JSONText.string(node.role)),"
                    + "\"text\":\(JSONText.string(ElementText.render(node)))}"
            }
            return .read("[" + objects.joined(separator: ",") + "]")
        }
        let blocks = matched.map(ElementText.render).filter { !$0.isEmpty }
        return .read(blocks.isEmpty ? emptyMarker : blocks.joined(separator: "\n\n"))
    }

    /// The node reached by a structural path (root index, then child index per
    /// level) — the same path scheme the walk and the ref table share.
    static func node(at path: [Int], in roots: [AXNode]) -> AXNode? {
        guard let first = path.first, roots.indices.contains(first) else { return nil }
        var node = roots[first]
        for index in path.dropFirst() {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    // MARK: - Diagnostics (criteria / whole-app modes)

    /// Exit 1 when the walk was bounded out. Named for `read` rather than reusing
    /// act's wording: this mode never resolves a ref, so "act timed out" would send
    /// an agent looking for a stale reference it never used.
    static func appTimeoutDiagnostic(app: String, pid: pid_t) -> String {
        "mtouch: read timed out reading the accessibility tree of '\(app)' (pid \(pid)); "
            + "the application appears unresponsive. Bounded to avoid an indefinite hang."
    }

    /// Exit 1 when nothing matched. It ECHOES the criteria and summarizes what the
    /// tree did contain (the same summary a wait timeout reports), so the criteria
    /// can be corrected without a blind retry — and so an empty read is never
    /// mistaken for an application that simply says nothing.
    static func noMatchDiagnostic(criteria: WaitCriteria?, app: String, roots: [AXNode]) -> String {
        let summary = WaitPipeline.lastSeenSummary(roots)
        guard let criteria else {
            return "mtouch: '\(app)' exposes no window to read. Last seen: \(summary). "
                + "Run 'mtouch windows --app \(app)' to check whether it has one open."
        }
        return "mtouch: no element matching \(criteria.description) in '\(app)'. Last seen: \(summary). "
            + "Check the criteria against 'mtouch snapshot --app \(app)', or wait for the element first "
            + "with 'mtouch wait --app \(app) --appears <criteria>'."
    }

    /// Carry an act-layer terminal outcome across unchanged. Resolution only ever
    /// produces failures here (the success cases are unreachable — `read` delivers
    /// no input), but the mapping is total so a future act-side change cannot
    /// silently become an empty read.
    private static func fromAct(_ outcome: ActOutcome) -> ReadOutcome {
        switch outcome {
        case let .acted(output), let .deliveredUnverified(output): return .read(output)
        case let .failed(stderr, code): return .failed(stderr: stderr, code: code)
        }
    }
}
