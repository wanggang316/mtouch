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
/// the POST node ADDED. The positional match is owning-window-AWARE: a same-path
/// role match between two KNOWN-DIFFERENT windows (a sibling window that slid into
/// a vacated slot) is NOT the same element and is left unmatched.
///
/// ## Cross-path fallback
/// A pure positional match misreads a subtree that SHIFTED to a new path (a root
/// insert/remove — e.g. closing a window while the menu bar is a sibling root, or
/// a sheet appearing) as remove+re-add of the shifted subtrees. After the
/// positional pass, a CROSS-PATH fallback re-pairs a still-unmatched PRE node with
/// a still-unmatched POST node when their `role` + `title` match UNIQUELY — and,
/// when both nodes' owning-window ids are known, those ids are EQUAL too. A
/// re-paired node carries its ref across the shift (treated like a matched node —
/// CHANGED if any rendered attribute differs, else unchanged), instead of
/// remove+add. The pass is deliberately conservative: any ambiguity (two
/// same-role+title candidates) leaves the nodes as remove+add — never a guess — so
/// it can only turn a false remove+add (a shift) into a carry-across, never
/// re-pair a genuinely removed node with an unrelated genuinely-added one.
///
/// ## Ref lifecycle (pinned)
/// - A matched (unchanged or changed) element KEEPS its PRE ref — including a node
///   re-paired across a path shift by the cross-path fallback.
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

        // The owning-window id of any PRE node, read off the recorded refs (only
        // POST ids are passed to `diff`). Lets the positional and cross-path passes
        // judge a PRE node's owning window symmetrically with the POST side.
        let preWindowIDByRoot = preRootWindowIDs(pre)
        func preWindowID(_ path: [Int]) -> CGWindowID? { preWindowIDByRoot[Array(path.prefix(1))] }
        func postWindowID(_ path: [Int]) -> CGWindowID? { postWindowIDsByPath[Array(path.prefix(1))] }

        // A path is positionally matched when the SAME role sits there in PRE and
        // POST AND the owning-window identity is compatible (equal, or unknown on
        // either side). A same-path role match between two KNOWN-DIFFERENT windows
        // is left UNMATCHED for the cross-path pass to resolve by window id.
        func positionallyMatches(_ path: [Int]) -> Bool {
            guard let preItem = preByPath[path], let postItem = postByPath[path],
                  preItem.node.role == postItem.node.role else { return false }
            return windowCarryAllowed(stored: preWindowID(path), post: postWindowID(path))
        }

        // Cross-path fallback: POST-path -> PRE-path for each node re-paired across
        // a shift. Only nodes still unmatched after the positional pass qualify.
        let crossMatch = crossPathMatches(
            preRendered: preRendered, postRendered: postRendered,
            isPositionallyMatched: positionallyMatches,
            preWindowID: preWindowID, postWindowID: postWindowID
        )
        let crossMatchedPrePaths = Set(crossMatch.values)

        let newSnapshot = reconciledSnapshot(
            pre: pre, post: post, postRendered: postRendered,
            postWindowIDsByPath: postWindowIDsByPath,
            isPositionallyMatched: positionallyMatches, crossMatch: crossMatch
        )
        let staleRefs = pre.refs.keys.filter { newSnapshot.refs[$0] == nil }.sorted()

        // ADDED / CHANGED classified in POST pre-order; refs come from the
        // reconciled table so added nodes surface their fresh act-able refs and a
        // node re-paired across a shift surfaces its carried ref.
        var added: [Diff.Entry] = []
        var changed: [Diff.Entry] = []
        for item in postRendered {
            let ref = newSnapshot.ref(atPath: item.path)
            let prePath: [Int]? = positionallyMatches(item.path) ? item.path : crossMatch[item.path]
            if let prePath, let preItem = preByPath[prePath] {
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

        // REMOVED classified in PRE pre-order: any PRE node with neither a
        // positional POST match nor a cross-path re-pairing. Its PRE ref (if any)
        // is recorded so the caller sees which ref went stale.
        var removed: [Diff.Entry] = []
        for item in preRendered {
            if positionallyMatches(item.path) || crossMatchedPrePaths.contains(item.path) { continue }
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
    /// A POST node continues a PRE ref when it either positionally matches the PRE
    /// node at its path OR was re-paired across a shift by the cross-path pass
    /// (`crossMatch`). Both matchers are owning-window-AWARE, so carry-over is
    /// already safe here: a PRE ref keeps its number only when the matched POST
    /// element sits under a COMPATIBLE owning window. After a sibling window closes
    /// and slides another (even identically-titled) window into the vacated
    /// position, that impostor is never positionally matched (nor cross-matched, its
    /// window id differing), so the PRE ref goes STALE and the impostor gets a fresh
    /// ref (VAL-ACT-011). A genuinely-surviving ref has its owning-window id
    /// re-derived from the post walk, so the identity is PRESERVED across the
    /// snapshot round-trip rather than dropped (which would defeat the act-layer
    /// gate on the next action).
    static func reconciledSnapshot(
        pre: Snapshot, post: [AXNode], postRendered: [RenderedNode],
        postWindowIDsByPath: [[Int]: CGWindowID],
        isPositionallyMatched: ([Int]) -> Bool, crossMatch: [[Int]: [Int]]
    ) -> Snapshot {
        var newRefs: [String: RefEntry] = [:]
        var nextFresh = maxRefIndex(pre.refs) + 1

        for item in postRendered where item.node.actionable {
            // The POST element's owning-window id, derived from its root prefix
            // (a window's descendants inherit their root's id).
            let postWindowID = postWindowIDsByPath[Array(item.path.prefix(1))]
            // The PRE path this POST node continues: its own (positional match) or,
            // for a shifted node, the cross-path match. Nil -> genuinely new.
            let matchedPrePath: [Int]? =
                isPositionallyMatched(item.path) ? item.path : crossMatch[item.path]
            if let prePath = matchedPrePath,
               let preRef = pre.ref(atPath: prePath),
               let preEntry = pre.refs[preRef],
               preEntry.role == item.node.role {
                // Carry the PRE ref across, refreshing the re-resolution hints from
                // the POST node (frame/title/path may have moved) and re-deriving the
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

    /// Cross-path fallback matching: re-pairs a node that SHIFTED to a new path
    /// (its old path now holds a different subtree) with its POST counterpart, so a
    /// mere reindex (a root insert/remove, a sheet appearing) reads as a carry-across
    /// rather than a spurious remove+add.
    ///
    /// Returns a POST-path -> PRE-path map of the re-paired nodes. Conservative by
    /// construction:
    ///   - only nodes still UNMATCHED after the positional pass are considered;
    ///   - the match key is `role` + `title`, and — when BOTH nodes' owning-window
    ///     ids are known — those must be EQUAL too (the strongest, safest key);
    ///   - the pairing must be MUTUALLY UNIQUE: exactly one unmatched POST node fits
    ///     a given unmatched PRE node on that key, and vice versa. Any ambiguity (two
    ///     same-role+title candidates on a side) leaves the nodes as remove+add.
    /// The result is order-independent (each POST path is claimed at most once), so
    /// the map is deterministic regardless of dictionary iteration order.
    static func crossPathMatches(
        preRendered: [RenderedNode], postRendered: [RenderedNode],
        isPositionallyMatched: ([Int]) -> Bool,
        preWindowID: ([Int]) -> CGWindowID?, postWindowID: ([Int]) -> CGWindowID?
    ) -> [[Int]: [Int]] {
        struct MatchKey: Hashable { let role: String; let title: String? }

        let unmatchedPre = preRendered.filter { !isPositionallyMatched($0.path) }
        let unmatchedPost = postRendered.filter { !isPositionallyMatched($0.path) }
        guard !unmatchedPre.isEmpty, !unmatchedPost.isEmpty else { return [:] }

        var preByKey: [MatchKey: [RenderedNode]] = [:]
        for item in unmatchedPre {
            preByKey[MatchKey(role: item.node.role, title: item.node.title), default: []].append(item)
        }
        var postByKey: [MatchKey: [RenderedNode]] = [:]
        for item in unmatchedPost {
            postByKey[MatchKey(role: item.node.role, title: item.node.title), default: []].append(item)
        }

        var matches: [[Int]: [Int]] = [:]
        for (key, preItems) in preByKey {
            guard let postItems = postByKey[key] else { continue }
            for preItem in preItems {
                let preWin = preWindowID(preItem.path)
                let postCandidates = postItems.filter {
                    windowCarryAllowed(stored: preWin, post: postWindowID($0.path))
                }
                guard postCandidates.count == 1 else { continue }
                let postItem = postCandidates[0]
                // Mutual uniqueness: the chosen POST node must have exactly one PRE
                // candidate too, else two shifted-looking nodes are ambiguous.
                let postWin = postWindowID(postItem.path)
                let preCandidates = preItems.filter {
                    windowCarryAllowed(stored: preWindowID($0.path), post: postWin)
                }
                guard preCandidates.count == 1 else { continue }
                matches[postItem.path] = preItem.path
            }
        }
        return matches
    }

    /// The owning-window id of each PRE root (length-1 path), read off the recorded
    /// refs — a window's descendants inherit their root's id, so any ref under a
    /// root reports that root's window. `diff` only receives the POST window map, so
    /// this recovers the PRE side for the window-aware matchers.
    static func preRootWindowIDs(_ pre: Snapshot) -> [[Int]: CGWindowID] {
        var byRoot: [[Int]: CGWindowID] = [:]
        for entry in pre.refs.values {
            guard let id = entry.ownerWindowID else { continue }
            byRoot[Array(entry.path.prefix(1))] = id
        }
        return byRoot
    }

    /// Whether a PRE ref may carry forward onto a matched POST element, judged by
    /// owning-window identity. The gate applies ONLY when BOTH ids are known: a ref
    /// with no stored id (an older/handle-free session) or a POST element with no
    /// known id (a non-window subtree, or a walk that captured no ids) degrades to
    /// the plain positional carry, exactly as before. When both are known they must
    /// be EQUAL — a same-hint element that slid in from a DIFFERENT window is an
    /// impostor, so the ref goes STALE rather than being re-homed.
    static func windowCarryAllowed(stored: CGWindowID?, post: CGWindowID?) -> Bool {
        guard let stored, let post else { return true }
        return stored == post
    }

    /// Whether two matched nodes render differently — i.e. any attribute the
    /// snapshot surfaces (and the digest hashes) changed: subrole, title, MASKED
    /// value, enabled, frame, or a scroll container's position. Value is compared
    /// through the `SecureField` mask chokepoint, so a secure field's underlying
    /// secret change is (correctly) invisible.
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
