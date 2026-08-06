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
/// attributes of a fresh walk. Separated from the handle-bearing walk so the
/// crux behaviour (VAL-ACT-011/017: a ref survives an unrelated action but is
/// rejected once its element is gone — never acting on a positional impostor) is
/// unit-testable without any AX access.
public enum ElementRelocation {
    /// The path whose element the ref resolves to, or nil when it can no longer
    /// be found (stale). Strategy:
    ///   1. POSITIONAL: if the ref's own path still holds an element whose hints
    ///      (role, subrole, title) match, that IS the element — the common case
    ///      where an unrelated action left the target in place.
    ///   2. HINT FALLBACK: otherwise, if EXACTLY ONE element anywhere matches the
    ///      hints, the element merely moved — use it. Zero or multiple matches is
    ///      ambiguous, so the ref is treated as stale rather than risk acting on
    ///      the wrong element.
    /// A positional occupant whose hints DIFFER is an impostor and never chosen.
    public static func locatePath(_ entry: RefEntry, in attributesByPath: [[Int]: AXAttributes]) -> [Int]? {
        if let occupant = attributesByPath[entry.path], hintsMatch(occupant, entry) {
            return entry.path
        }
        let matches = attributesByPath.filter { hintsMatch($0.value, entry) }
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
}
