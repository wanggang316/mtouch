import CoreGraphics
import Foundation

/// A rendered perception snapshot: the walked `AXNode` tree paired with a ref
/// table. Pure value type — no AX handles escape into it — so it can be built in
/// tests and (by `session-store`) persisted without any AX/TCC access.
///
/// Refs (`e1`, `e2`, …) are assigned to ACTIONABLE nodes in a deterministic
/// pre-order traversal at construction time. The table is the single source of
/// truth for the numbering; renderers resolve a node's ref via `ref(atPath:)`
/// rather than recomputing, so text, JSON, and (later) diff output all agree.
///
/// The stored `roots` are the UNCHANGED model (noise filtering happens only in
/// the renderers). Because filtering never drops an actionable node or an
/// ancestor of one, every ref remains resolvable in the filtered views too.
public struct Snapshot: Equatable, Sendable {
    /// The walked tree, exactly as produced by the walker (model unchanged).
    public let roots: [AXNode]
    /// Ref string (`e5`) -> re-resolution hints. Consumed by `session-store` to
    /// persist and later re-locate the element for the act layer.
    public let refs: [String: RefEntry]
    /// Reverse index (node path -> ref) so renderers that walk the tree can look
    /// up each actionable node's ref without re-running the numbering. Derived
    /// from `refs`; not part of the persisted form.
    private let refByPath: [[Int]: String]

    /// Ref numbering prefix. Kept as a constant so `session-store` / the diff
    /// engine can recognise refs without hard-coding the letter.
    public static let refPrefix = "e"

    /// The ref string for the Nth (1-based) actionable node in pre-order.
    public static func refToken(_ index: Int) -> String { "\(refPrefix)\(index)" }

    public init(roots: [AXNode]) {
        self.roots = roots

        var refs: [String: RefEntry] = [:]
        var byPath: [[Int]: String] = [:]
        var counter = 0

        // Deterministic pre-order (parent before children, roots in order).
        func assign(_ node: AXNode, path: [Int]) {
            if node.actionable {
                counter += 1
                let ref = Snapshot.refToken(counter)
                refs[ref] = RefEntry(node: node, ref: ref, path: path)
                byPath[path] = ref
            }
            for (index, child) in node.children.enumerated() {
                assign(child, path: path + [index])
            }
        }
        for (index, root) in roots.enumerated() {
            assign(root, path: [index])
        }

        self.refs = refs
        self.refByPath = byPath
    }

    /// The ref assigned to the node reached by `path` (index path from `roots`),
    /// or nil when that node is not actionable. Renderers pass the path they are
    /// already tracking; the diff engine reuses it for ref carry-over.
    public func ref(atPath path: [Int]) -> String? { refByPath[path] }
}

/// AX-handle-free re-resolution hints for one ref. Codable so `session-store`
/// can persist the ref table and, on a later walk, re-locate the element for the
/// act layer. Deliberately EXCLUDES the node's `value`: a value may be a secret
/// (secure field), and a value is not needed to re-locate an element — role,
/// subrole, title, frame, and the structural `path` are the stable hints.
public struct RefEntry: Equatable, Sendable, Codable {
    public let ref: String
    public let role: String
    public let subrole: String?
    public let title: String?
    public let frame: CGRect?
    /// Index path from the snapshot roots to this node — a deterministic,
    /// handle-free breadcrumb the act layer can follow on a fresh walk.
    public let path: [Int]

    public init(node: AXNode, ref: String, path: [Int]) {
        self.ref = ref
        self.role = node.role
        self.subrole = node.subrole
        self.title = node.title
        self.frame = node.frame
        self.path = path
    }
}

// MARK: - Convenience entry points

/// Render a snapshot to compact ref-annotated text. Free-function form of
/// `SnapshotText.render(_:)` matching the feature's `renderText(_:)` contract.
public func renderText(_ snapshot: Snapshot) -> String { SnapshotText.render(snapshot) }

/// Build a snapshot from a raw tree and render it to text.
public func renderText(_ roots: [AXNode]) -> String { renderText(Snapshot(roots: roots)) }

/// Render a snapshot to byte-stable JSON. Free-function form of
/// `SnapshotJSON.render(_:)` matching the feature's `renderJSON(_:)` contract.
public func renderJSON(_ snapshot: Snapshot) -> String { SnapshotJSON.render(snapshot) }

/// Build a snapshot from a raw tree and render it to JSON.
public func renderJSON(_ roots: [AXNode]) -> String { renderJSON(Snapshot(roots: roots)) }
