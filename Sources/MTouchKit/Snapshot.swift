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
        // `ancestors` accumulates the hint chain from the owning top-level window
        // down to (but excluding) the current node, so each ref records the
        // identity of every node above it — see `RefEntry.ancestors`.
        func assign(_ node: AXNode, path: [Int], ancestors: [NodeHint]) {
            if node.actionable {
                counter += 1
                let ref = Snapshot.refToken(counter)
                refs[ref] = RefEntry(node: node, ref: ref, path: path, ancestors: ancestors)
                byPath[path] = ref
            }
            let childAncestors = ancestors + [NodeHint(node: node)]
            for (index, child) in node.children.enumerated() {
                assign(child, path: path + [index], ancestors: childAncestors)
            }
        }
        for (index, root) in roots.enumerated() {
            assign(root, path: [index], ancestors: [])
        }

        self.refs = refs
        self.refByPath = byPath
    }

    /// Build a snapshot around a PRECOMPUTED ref table instead of numbering
    /// afresh. The post-action diff engine carries the PRE snapshot's refs across
    /// to matched POST nodes and issues fresh (continuing) refs for added nodes;
    /// the resulting POST snapshot must therefore keep those exact refs rather
    /// than re-running naive pre-order numbering (which would renumber survivors).
    /// The reverse `path -> ref` index is derived from each entry's `path`, so
    /// renderers resolve refs identically to a normally-numbered snapshot.
    public init(roots: [AXNode], refs: [String: RefEntry]) {
        self.roots = roots

        // The ancestor identity of a ref is a FUNCTION of the tree plus its path,
        // so re-derive it authoritatively from `roots` rather than trusting the
        // incoming entries. The diff engine builds carried/added refs from a node
        // and path alone (it has no ancestor chain to pass), so without this the
        // persisted POST refs would carry no ancestor identity and the act layer's
        // relocation would wrongly reject every surviving ref.
        let hints = Snapshot.hintsByPath(of: roots)
        var rebuilt: [String: RefEntry] = [:]
        var byPath: [[Int]: String] = [:]
        for entry in refs.values {
            rebuilt[entry.ref] = entry.withAncestors(Snapshot.ancestorChain(forPath: entry.path, in: hints))
            byPath[entry.path] = entry.ref
        }
        self.refs = rebuilt
        self.refByPath = byPath
    }

    // MARK: - Ancestor identity derivation

    /// A path -> node-hint index over the whole tree, so a ref's ancestor chain can
    /// be read off by prefix without re-walking per ref.
    private static func hintsByPath(of roots: [AXNode]) -> [[Int]: NodeHint] {
        var index: [[Int]: NodeHint] = [:]
        func visit(_ node: AXNode, path: [Int]) {
            index[path] = NodeHint(node: node)
            for (childIndex, child) in node.children.enumerated() {
                visit(child, path: path + [childIndex])
            }
        }
        for (index0, root) in roots.enumerated() { visit(root, path: [index0]) }
        return index
    }

    /// The hint chain from the owning top-level window (path prefix of length 1)
    /// down to the node's parent (prefix of length `path.count - 1`), in that
    /// order — the identity `ElementRelocation` compares to reject a same-hint
    /// impostor that now sits at this path inside a DIFFERENT window.
    private static func ancestorChain(forPath path: [Int], in hints: [[Int]: NodeHint]) -> [NodeHint] {
        guard path.count > 1 else { return [] }
        return (1..<path.count).compactMap { hints[Array(path.prefix($0))] }
    }

    /// The ref assigned to the node reached by `path` (index path from `roots`),
    /// or nil when that node is not actionable. Renderers pass the path they are
    /// already tracking; the diff engine reuses it for ref carry-over.
    public func ref(atPath path: [Int]) -> String? { refByPath[path] }
}

/// The handle-free identity of ONE node on a ref's ancestor path: the same stable
/// role/subrole/title triple `ElementRelocation.hintsMatch` trusts for the element
/// itself. Value-free by construction — only role/subrole/title, never a node
/// `value` (a possible secret). Ancestor TITLES are fine: they are window/group
/// captions, not secure-field values.
public struct NodeHint: Equatable, Sendable, Codable {
    public let role: String
    public let subrole: String?
    public let title: String?

    public init(role: String, subrole: String? = nil, title: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
    }

    public init(node: AXNode) {
        self.init(role: node.role, subrole: node.subrole, title: node.title)
    }

    public init(attributes: AXAttributes) {
        self.init(role: attributes.role, subrole: attributes.subrole, title: attributes.title)
    }
}

/// AX-handle-free re-resolution hints for one ref. Codable so `session-store`
/// can persist the ref table and, on a later walk, re-locate the element for the
/// act layer. Deliberately EXCLUDES the node's `value`: a value may be a secret
/// (secure field), and a value is not needed to re-locate an element — role,
/// subrole, title, frame, the structural `path`, and the ancestor identity are
/// the stable hints.
public struct RefEntry: Equatable, Sendable, Codable {
    public let ref: String
    public let role: String
    public let subrole: String?
    public let title: String?
    public let frame: CGRect?
    /// Index path from the snapshot roots to this node — a deterministic,
    /// handle-free breadcrumb the act layer can follow on a fresh walk.
    public let path: [Int]
    /// The hint chain from the owning top-level window down to this node's parent,
    /// in that order (empty for a top-level node). It pins the ref to a SPECIFIC
    /// window/subtree so that, after a sibling window closes and slides another
    /// window into this ref's old position, a same-hint element there is rejected
    /// as an impostor rather than acted on (VAL-ACT-011). Still value-free: only
    /// role/subrole/title per ancestor.
    public let ancestors: [NodeHint]

    public init(
        ref: String, role: String, subrole: String?, title: String?,
        frame: CGRect?, path: [Int], ancestors: [NodeHint] = []
    ) {
        self.ref = ref
        self.role = role
        self.subrole = subrole
        self.title = title
        self.frame = frame
        self.path = path
        self.ancestors = ancestors
    }

    public init(node: AXNode, ref: String, path: [Int], ancestors: [NodeHint] = []) {
        self.init(
            ref: ref, role: node.role, subrole: node.subrole, title: node.title,
            frame: node.frame, path: path, ancestors: ancestors
        )
    }

    /// A copy of this entry with its ancestor identity replaced — used when the
    /// snapshot re-derives the chain authoritatively from the tree.
    func withAncestors(_ ancestors: [NodeHint]) -> RefEntry {
        RefEntry(
            ref: ref, role: role, subrole: subrole, title: title,
            frame: frame, path: path, ancestors: ancestors
        )
    }

    private enum CodingKeys: String, CodingKey {
        case ref, role, subrole, title, frame, path, ancestors
    }

    /// Tolerant decode: a session written before ancestor identity existed simply
    /// decodes with an empty chain (its nested refs then relocate conservatively as
    /// stale — safe — while every fresh snapshot carries the full identity).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(String.self, forKey: .ref)
        role = try container.decode(String.self, forKey: .role)
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        frame = try container.decodeIfPresent(CGRect.self, forKey: .frame)
        path = try container.decode([Int].self, forKey: .path)
        ancestors = try container.decodeIfPresent([NodeHint].self, forKey: .ancestors) ?? []
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
