import CoreGraphics

/// Computes the post-action diff between a PRE snapshot and a freshly walked POST
/// tree, and carries refs across so the resulting session stays act-able.
///
/// ## Identity heuristic
/// Elements are matched POSITIONALLY: the stable identity is `role` + structural
/// PATH, judged over the same noise-filtered view the renderers use. Title,
/// value, enabled, and frame are treated as CHANGEABLE attributes, NOT identity —
/// so an element whose title or value changed but whose role and path are stable
/// is reported as CHANGED (keeping its ref), never as remove+add. `value` alone
/// (the thing that most often changes) never drives identity. When the role at a
/// path differs, the element is considered replaced: the PRE node is REMOVED and
/// the POST node ADDED.
///
/// This positional heuristic is deliberately simple and deterministic. It does
/// NOT re-pair an element that shifted to a different path (e.g. because a
/// sibling was inserted before it); such a shift reads as an add plus a
/// remove/change at the affected positions. That is an accepted trade-off for a
/// stable, auditable diff.
///
/// ## Ref lifecycle (pinned)
/// - A matched (unchanged or changed) element KEEPS its PRE ref.
/// - An ADDED actionable element gets a FRESH ref continuing the PRE counter
///   (never reusing a freed number), so it is immediately act-able from the diff.
/// - A REMOVED/replaced element's PRE ref becomes STALE: it is simply absent from
///   the new ref table, so a later `resolve` returns `.stale`.
public enum DiffEngine {
    /// Diff `post` against `pre`, returning the rendered `diff` plus the
    /// `newSnapshot` (POST tree carrying the reconciled ref table) the act layer
    /// persists as the session's new current state.
    public static func diff(
        pre: Snapshot, post: [AXNode], postWindowIDsByPath: [[Int]: CGWindowID] = [:]
    ) -> DiffResult {
        // A naive POST snapshot is used ONLY to obtain the noise-filtered,
        // path-annotated traversal; its refs are discarded in favour of the
        // carried/fresh table computed below.
        let preRendered = pre.renderedNodes()
        let postRendered = Snapshot(roots: post).renderedNodes()

        var preByPath: [[Int]: RenderedNode] = [:]
        for item in preRendered { preByPath[item.path] = item }
        var postByPath: [[Int]: RenderedNode] = [:]
        for item in postRendered { postByPath[item.path] = item }

        let newSnapshot = reconciledSnapshot(
            pre: pre, post: post, postRendered: postRendered,
            postWindowIDsByPath: postWindowIDsByPath
        )
        let staleRefs = pre.refs.keys.filter { newSnapshot.refs[$0] == nil }.sorted()

        // ADDED / CHANGED classified in POST pre-order; refs come from the
        // reconciled table so added nodes surface their fresh act-able refs.
        var added: [Diff.Entry] = []
        var changed: [Diff.Entry] = []
        for item in postRendered {
            let ref = newSnapshot.ref(atPath: item.path)
            if let preItem = preByPath[item.path], preItem.node.role == item.node.role {
                if rendersDifferently(preItem.node, item.node) {
                    changed.append(Diff.Entry(
                        node: item.node, previous: preItem.node,
                        ref: ref, depth: item.depth, path: item.path
                    ))
                }
                // Otherwise unchanged: deliberately not emitted.
            } else {
                added.append(Diff.Entry(
                    node: item.node, previous: nil,
                    ref: ref, depth: item.depth, path: item.path
                ))
            }
        }

        // REMOVED classified in PRE pre-order: any PRE node without a same-role
        // POST node at its path. Its PRE ref (if any) is recorded so the caller
        // sees which ref went stale.
        var removed: [Diff.Entry] = []
        for item in preRendered {
            if let postItem = postByPath[item.path], postItem.node.role == item.node.role {
                continue
            }
            removed.append(Diff.Entry(
                node: item.node, previous: nil,
                ref: pre.ref(atPath: item.path), depth: item.depth, path: item.path
            ))
        }

        let diff = Diff(added: added, removed: removed, changed: changed, staleRefs: staleRefs)
        return DiffResult(diff: diff, newSnapshot: newSnapshot)
    }

    /// A deterministic, byte-stable fingerprint of a snapshot's rendered (masked)
    /// tree. This REUSES the session-store digest (`Session.digest`, FNV-1a over
    /// the masked snapshot JSON) — a single scheme so the recorder's chain and
    /// the diff engine agree: identical rendered trees hash equal, and any
    /// rendered change (including added/removed nodes) flips the hash. Secure
    /// values are masked before hashing, so a secret never affects the digest and
    /// never leaks.
    public static func digest(of snapshot: Snapshot) -> String { Session.digest(of: snapshot) }

    /// Digest of a raw tree (numbered afresh), for callers holding roots.
    public static func digest(of roots: [AXNode]) -> String { digest(of: Snapshot(roots: roots)) }

    // MARK: - Internals

    /// Builds the POST snapshot carrying the reconciled ref table: matched
    /// actionable nodes keep their PRE ref; added actionable nodes get fresh refs
    /// continuing the PRE counter, assigned in POST pre-order for determinism.
    ///
    /// Carry-over is owning-window-AWARE: a PRE ref keeps its number ONLY when the
    /// positionally-matched POST element sits under the SAME owning window. After a
    /// sibling window closes and slides another (even identically-titled) window
    /// into the vacated position, the PRE ref would otherwise be re-homed onto that
    /// impostor; instead it goes STALE (absent here) and the surviving element gets
    /// a fresh ref (VAL-ACT-011). A genuinely-surviving ref has its owning-window id
    /// re-derived from the post walk, so the identity is PRESERVED across the
    /// snapshot round-trip rather than dropped (which would defeat the act-layer
    /// gate on the next action).
    static func reconciledSnapshot(
        pre: Snapshot, post: [AXNode], postRendered: [RenderedNode],
        postWindowIDsByPath: [[Int]: CGWindowID]
    ) -> Snapshot {
        var newRefs: [String: RefEntry] = [:]
        var nextFresh = maxRefIndex(pre.refs) + 1

        for item in postRendered where item.node.actionable {
            // The POST element's owning-window id, derived from its root prefix
            // (a window's descendants inherit their root's id).
            let postWindowID = postWindowIDsByPath[Array(item.path.prefix(1))]
            if let preRef = pre.ref(atPath: item.path),
               let preEntry = pre.refs[preRef],
               preEntry.role == item.node.role,
               windowCarryAllowed(stored: preEntry.ownerWindowID, post: postWindowID) {
                // Carry the PRE ref across, refreshing the re-resolution hints from
                // the POST node (frame/title may have moved) and re-deriving the
                // owning window id so the identity survives the round-trip.
                newRefs[preRef] = RefEntry(
                    node: item.node, ref: preRef, path: item.path,
                    ownerWindowID: postWindowID ?? preEntry.ownerWindowID
                )
            } else {
                let ref = Snapshot.refToken(nextFresh)
                nextFresh += 1
                newRefs[ref] = RefEntry(
                    node: item.node, ref: ref, path: item.path, ownerWindowID: postWindowID
                )
            }
        }

        return Snapshot(roots: post, refs: newRefs)
    }

    /// Whether a PRE ref may carry forward onto a positionally-matched POST element,
    /// judged by owning-window identity. The gate applies ONLY when BOTH ids are
    /// known: a ref with no stored id (an older/handle-free session) or a POST
    /// element with no known id (a non-window subtree, or a walk that captured no
    /// ids) degrades to the plain positional carry, exactly as before. When both are
    /// known they must be EQUAL — a same-hint element that slid in from a DIFFERENT
    /// window is an impostor, so the ref goes STALE rather than being re-homed.
    static func windowCarryAllowed(stored: CGWindowID?, post: CGWindowID?) -> Bool {
        guard let stored, let post else { return true }
        return stored == post
    }

    /// Whether two positionally-matched nodes render differently — i.e. any
    /// attribute the snapshot surfaces (and the digest hashes) changed: subrole,
    /// title, MASKED value, enabled, frame, or a scroll container's position.
    /// Value is compared through the `SecureField` mask chokepoint, so a secure
    /// field's underlying secret change is (correctly) invisible.
    static func rendersDifferently(_ a: AXNode, _ b: AXNode) -> Bool {
        a.role != b.role
            || a.subrole != b.subrole
            || a.title != b.title
            || SecureField.renderedValue(of: a) != SecureField.renderedValue(of: b)
            || a.enabled != b.enabled
            || a.frame != b.frame
            || scrollSignature(a) != scrollSignature(b)
    }

    /// The scroll position a node contributes to the rendered view (only scroll
    /// containers expose one), so a non-scroll node never spuriously "changes".
    static func scrollSignature(_ node: AXNode) -> CGPoint? {
        node.isScrollArea ? node.scrollPosition : nil
    }

    /// The highest numeric ref index issued in a table (0 when empty), so fresh
    /// refs continue the counter monotonically without reusing a freed number.
    static func maxRefIndex(_ refs: [String: RefEntry]) -> Int {
        refs.keys.compactMap { key in
            guard key.hasPrefix(Snapshot.refPrefix) else { return nil }
            return Int(key.dropFirst(Snapshot.refPrefix.count))
        }.max() ?? 0
    }
}
