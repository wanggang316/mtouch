import ApplicationServices
import CoreGraphics
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
    /// Structural path -> the CGWindowID of the OWNING top-level window, captured
    /// once per window root and propagated to every descendant. This is the STABLE,
    /// UNIQUE per-window identity `ElementRelocation` matches against a ref's
    /// stored `ownerWindowID`, so a same-hint element in a DIFFERENT (even
    /// identically-titled) window is rejected as an impostor. A root that is not a
    /// window (the menu bar) reports no id, so its subtree is simply absent here.
    let windowIDsByPath: [[Int]: CGWindowID]

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
        self.windowIDsByPath = builder.windowIDsByPath
    }

    /// Memberwise seam for tests: drive `ActPipeline`'s ref-verb back half against
    /// a hand-built tree with sentinel handles, exercising re-location → act →
    /// settle → persist WITHOUT a live AX grant. Internal (never part of the public
    /// surface): production always goes through `walk`. `windowIDsByPath` lets a
    /// regression simulate two identically-titled windows with DIFFERENT window ids
    /// (it defaults to empty for the existing single-window fixtures).
    init(
        nodes: [AXNode],
        elementsByPath: [[Int]: AXUIElement],
        attributesByPath: [[Int]: AXAttributes],
        windowIDsByPath: [[Int]: CGWindowID] = [:]
    ) {
        self.nodes = nodes
        self.elementsByPath = elementsByPath
        self.attributesByPath = attributesByPath
        self.windowIDsByPath = windowIDsByPath
    }

    /// Accumulates the two path-keyed indices while descending, mirroring
    /// `AXTreeWalker.buildNode` (same depth cap, same `descendableChildren`).
    private struct Builder<Provider: AXTreeProvider> where Provider.Element == AXUIElement {
        let provider: Provider
        var elementsByPath: [[Int]: AXUIElement] = [:]
        var attributesByPath: [[Int]: AXAttributes] = [:]
        var windowIDsByPath: [[Int]: CGWindowID] = [:]

        mutating func build() -> [AXNode] {
            elementsByPath.removeAll()
            attributesByPath.removeAll()
            windowIDsByPath.removeAll()
            return provider.roots().enumerated().map { index, element in
                // Resolve the owning-window id ONCE per root (a window's own
                // element) and propagate it down; a non-window root (the menu bar)
                // reports nil, leaving its subtree without an id.
                node(element, path: [index], depth: 0, windowID: AXSupport.windowID(of: element))
            }
        }

        private mutating func node(
            _ element: AXUIElement, path: [Int], depth: Int, windowID: CGWindowID?
        ) -> AXNode {
            let attributes = provider.attributes(of: element)
            attributesByPath[path] = attributes
            elementsByPath[path] = element
            if let windowID { windowIDsByPath[path] = windowID }
            guard depth < AXTreeWalker.maxDepth else {
                return AXNode(attributes: attributes, children: [])
            }
            let children = AXTreeWalker
                .descendableChildren(provider: provider, ownerRole: attributes.role, of: element)
                .enumerated()
                .map { childIndex, child in
                    node(child, path: path + [childIndex], depth: depth + 1, windowID: windowID)
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
/// owning-window CGWindowID (authoritative) and ancestor identity must also match,
/// so a positional collision alone never wins.
public enum ElementRelocation {
    /// The path whose element the ref resolves to, or nil when it can no longer
    /// be found (stale). Strategy:
    ///   1. POSITIONAL: the ref's own path still holds an element whose own hints
    ///      (role, subrole, title), owning-window id, AND ancestor chain all match
    ///      — the common case where an unrelated action left the target in place.
    ///      All must match: a same-hint element now at this path but under a
    ///      different owning window is an impostor (e.g. a sibling window closed
    ///      and slid this one into the vacated slot).
    ///   2. HINT FALLBACK: otherwise, among all elements whose own hints, owning
    ///      window, AND ancestor chain match, resolve iff EXACTLY ONE remains — the
    ///      element merely moved. Zero or multiple matches is ambiguous, so the ref
    ///      is treated as stale rather than risk acting on the wrong element.
    ///
    /// `windowIDsByPath` (from `LiveElementTree`) supplies each live element's
    /// owning-window CGWindowID; the owning-window gate is the AUTHORITY. Two
    /// untitled windows share a title, so the ancestor chain cannot tell them
    /// apart, but their window ids differ. The gate is applied only when BOTH the
    /// ref's stored id and the live id are known, so a handle-free fixture or an
    /// older (pre-window-id) session degrades to ancestor/positional matching.
    public static func locatePath(
        _ entry: RefEntry,
        in attributesByPath: [[Int]: AXAttributes],
        windowIDsByPath: [[Int]: CGWindowID] = [:]
    ) -> [Int]? {
        if let occupant = attributesByPath[entry.path],
           hintsMatch(occupant, entry),
           windowMatches(entry, at: entry.path, in: windowIDsByPath),
           ancestorsMatch(entry, at: entry.path, in: attributesByPath) {
            return entry.path
        }
        let matches = attributesByPath.filter { path, attributes in
            hintsMatch(attributes, entry)
                && windowMatches(entry, at: path, in: windowIDsByPath)
                && ancestorsMatch(entry, at: path, in: attributesByPath)
        }
        guard matches.count == 1 else { return nil }
        return matches.first?.key
    }

    /// Whether the live element at `path` sits under the SAME owning window the ref
    /// recorded, by its STABLE, UNIQUE CGWindowID — the authoritative window
    /// discriminator (titles are not: two untitled windows share one). Applied only
    /// when BOTH ids are known: a ref with no stored id (an older session, or a
    /// handle-free fixture) or a path with no live id is not gated here, so it falls
    /// back to ancestor/positional matching rather than being wrongly rejected.
    /// When both are known they must be EQUAL — a same-hint element under a
    /// different window id is an impostor and never chosen.
    static func windowMatches(
        _ entry: RefEntry, at path: [Int], in windowIDsByPath: [[Int]: CGWindowID]
    ) -> Bool {
        guard let stored = entry.ownerWindowID, let live = windowIDsByPath[path] else { return true }
        return stored == live
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
