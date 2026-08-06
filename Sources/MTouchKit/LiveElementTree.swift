import ApplicationServices
import Foundation

/// A live AX walk that retains element HANDLES alongside the derived `AXNode`
/// tree, produced in ONE pass so the act layer can, from a single walk:
///   1. build the pre-action `AXNode` tree the diff engine needs, and
///   2. re-locate a specific element by its ref's structural path + hints.
///
/// It mirrors `AXTreeWalker`'s descent EXACTLY — same `descendableChildren`
/// menu-collapse policy, same single-shot AXManualAccessibility fallback — so the
/// `path` indices it records line up with the ones the snapshot used to assign
/// refs. Because it carries raw `AXUIElement` handles it is `@unchecked Sendable`;
/// the handles are only read/acted-on (never mutated) and are safe to pass across
/// the `BoundedWalk` queue boundary.
public struct LiveElementTree: @unchecked Sendable {
    /// The derived tree, identical in shape to `AXTreeWalker.walk(pid:).nodes`.
    public let nodes: [AXNode]
    /// Structural path -> live handle for every walked node. The path scheme is
    /// the walker's (root index, then `descendableChildren` index per level).
    let elementsByPath: [[Int]: AXUIElement]
    /// Structural path -> the raw attributes read at that node. Kept separate from
    /// the handles so the (pure) re-location decision can be made and unit-tested
    /// without any AX handle.
    let attributesByPath: [[Int]: AXAttributes]

    /// Walk a live application by pid, retaining handles. Runs one pass; if the
    /// result is effectively empty, enables the AXManualAccessibility fallback
    /// ONCE and re-walks — matching `AXTreeWalker.walk` so the pre-action tree and
    /// the snapshot agree.
    public static func walk(pid: pid_t) -> LiveElementTree {
        walk(provider: LiveTreeProvider(pid: pid))
    }

    /// Provider-generic over any tree whose elements ARE AX handles, so the
    /// descent reuses the walker's exact policy. The pure re-location decision is
    /// factored into `ElementRelocation` and tested independently, so this stays
    /// tied to the AX element type (its whole reason to exist is retaining them).
    static func walk<Provider: AXTreeProvider>(
        provider: Provider
    ) -> LiveElementTree where Provider.Element == AXUIElement {
        var builder = Builder(provider: provider)
        var nodes = builder.build()
        guard isEffectivelyEmpty(nodes) else {
            return LiveElementTree(nodes: nodes, builder: builder)
        }
        provider.enableManualAccessibilityFallback()
        builder = Builder(provider: provider)
        nodes = builder.build()
        return LiveElementTree(nodes: nodes, builder: builder)
    }

    private init<Provider: AXTreeProvider>(
        nodes: [AXNode], builder: Builder<Provider>
    ) where Provider.Element == AXUIElement {
        self.nodes = nodes
        self.elementsByPath = builder.elementsByPath
        self.attributesByPath = builder.attributesByPath
    }

    /// Memberwise seam for tests: drive `ActPipeline`'s ref-verb back half against
    /// a hand-built tree with sentinel handles, exercising re-location → act →
    /// settle → persist WITHOUT a live AX grant. Internal (never part of the public
    /// surface): production always goes through `walk`.
    init(
        nodes: [AXNode],
        elementsByPath: [[Int]: AXUIElement],
        attributesByPath: [[Int]: AXAttributes]
    ) {
        self.nodes = nodes
        self.elementsByPath = elementsByPath
        self.attributesByPath = attributesByPath
    }

    /// Accumulates the two path-keyed indices while descending, mirroring
    /// `AXTreeWalker.buildNode` (same depth cap, same `descendableChildren`).
    private struct Builder<Provider: AXTreeProvider> where Provider.Element == AXUIElement {
        let provider: Provider
        var elementsByPath: [[Int]: AXUIElement] = [:]
        var attributesByPath: [[Int]: AXAttributes] = [:]

        mutating func build() -> [AXNode] {
            elementsByPath.removeAll()
            attributesByPath.removeAll()
            return provider.roots().enumerated().map { index, element in
                node(element, path: [index], depth: 0)
            }
        }

        private mutating func node(_ element: AXUIElement, path: [Int], depth: Int) -> AXNode {
            let attributes = provider.attributes(of: element)
            attributesByPath[path] = attributes
            elementsByPath[path] = element
            guard depth < AXTreeWalker.maxDepth else {
                return AXNode(attributes: attributes, children: [])
            }
            let children = AXTreeWalker
                .descendableChildren(provider: provider, ownerRole: attributes.role, of: element)
                .enumerated()
                .map { childIndex, child in
                    node(child, path: path + [childIndex], depth: depth + 1)
                }
            return AXNode(attributes: attributes, children: children)
        }
    }
}

/// Pure re-location: which live element a ref now points at, given the per-path
/// attributes of a fresh walk. Separated from the handle-bearing walk so the crux
/// behaviour is unit-testable without any AX access: a ref survives an unrelated
/// action but is rejected the moment its element is gone (VAL-ACT-011/017), and a
/// same-hint element that has slid into the ref's old position inside a DIFFERENT
/// window is rejected as an impostor rather than acted on — the ref's stored
/// ancestor identity must also match, so a positional collision alone never wins.
public enum ElementRelocation {
    /// The path whose element the ref resolves to, or nil when it can no longer
    /// be found (stale). Strategy:
    ///   1. POSITIONAL: the ref's own path still holds an element whose own hints
    ///      (role, subrole, title) AND whose ancestor chain both match — the common
    ///      case where an unrelated action left the target in place. Both must
    ///      match: a same-hint element now at this path but under a different owning
    ///      window is an impostor (e.g. a sibling window closed and slid this one
    ///      into the vacated slot).
    ///   2. HINT FALLBACK: otherwise, among all elements whose own hints AND
    ///      ancestor chain match, resolve iff EXACTLY ONE remains — the element
    ///      merely moved. Zero or multiple matches is ambiguous, so the ref is
    ///      treated as stale rather than risk acting on the wrong element.
    public static func locatePath(_ entry: RefEntry, in attributesByPath: [[Int]: AXAttributes]) -> [Int]? {
        if let occupant = attributesByPath[entry.path],
           hintsMatch(occupant, entry),
           ancestorsMatch(entry, at: entry.path, in: attributesByPath) {
            return entry.path
        }
        let matches = attributesByPath.filter { path, attributes in
            hintsMatch(attributes, entry) && ancestorsMatch(entry, at: path, in: attributesByPath)
        }
        guard matches.count == 1 else { return nil }
        return matches.first?.key
    }

    /// Whether a live element's hints identify it as the ref's element. Uses the
    /// stable, handle-free identity the diff engine also trusts — role + subrole +
    /// title. `value` is deliberately excluded (it is not persisted, and it is the
    /// attribute most likely to change); frame is excluded because a surviving
    /// element routinely moves.
    public static func hintsMatch(_ attributes: AXAttributes, _ entry: RefEntry) -> Bool {
        attributes.role == entry.role
            && attributes.subrole == entry.subrole
            && attributes.title == entry.title
    }

    /// Whether the live element at `path` has the SAME ancestor identity the ref
    /// recorded at snapshot time: the hint chain from the owning top-level window
    /// down to the parent, compared position-for-position. A different length (the
    /// element now sits at a different depth) or any differing/absent ancestor is a
    /// mismatch — the candidate is in a different subtree and must not be chosen.
    static func ancestorsMatch(_ entry: RefEntry, at path: [Int], in attributesByPath: [[Int]: AXAttributes]) -> Bool {
        guard path.count - 1 == entry.ancestors.count else { return false }
        for depth in 1..<path.count {
            guard let attributes = attributesByPath[Array(path.prefix(depth))] else { return false }
            if NodeHint(attributes: attributes) != entry.ancestors[depth - 1] { return false }
        }
        return true
    }
}
