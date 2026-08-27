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

    /// Carry an act-layer terminal outcome across unchanged. Resolution only ever
    /// produces failures here (`.acted` is unreachable), but the mapping is total
    /// so a future act-side change cannot silently become an empty read.
    private static func fromAct(_ outcome: ActOutcome) -> ReadOutcome {
        switch outcome {
        case let .acted(output): return .read(output)
        case let .failed(stderr, code): return .failed(stderr: stderr, code: code)
        }
    }
}
