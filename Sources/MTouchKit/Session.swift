import Foundation

/// The outcome of resolving a ref token (`e5`) against the current session.
///
/// The four cases are DELIBERATELY distinct because the act layer maps them to
/// different exit codes and user guidance. The mapping is pinned here so the act
/// implementer does not have to guess:
///
///   - `.resolved(entry)` — the ref is in the current session. Act proceeds
///     (exit 0), re-locating the element from `entry`'s handle-free hints.
///   - `.stale` — a well-formed ref token (`e` + a positive integer) that the
///     current session does NOT contain. Typically the UI changed and refs were
///     renumbered, or the token is beyond the range this snapshot issued.
///     → act layer: exit 3 (`refError`) WITH recovery advice ("the UI changed;
///       re-run `snapshot` to get fresh refs").
///   - `.unknown` — a string that is NOT a ref token this tool ever issues
///     (e.g. "banana", "e", "e0", "e1x"). It is a malformed argument, not a
///     missing element.
///     → act layer: exit 64 (`usageError`).
///   - `.noSession` — no session file exists, or it was unreadable/corrupt.
///     → act layer: exit 3 (`refError`) WITH advice ("no active session; run
///       `snapshot` first").
///
/// The load-bearing discriminator between exit 3 and exit 64 is TOKEN SHAPE, not
/// in-range-ness: any `e<positiveInteger>` is token-shaped and, when absent,
/// yields `.stale` (→ 3); only non-token strings yield `.unknown` (→ 64). A
/// single snapshot always issues a contiguous `e1…eN`, so there is no
/// "in-range but absent" case — every absent token is simply `.stale`.
public enum RefResolution: Equatable, Sendable {
    case resolved(RefEntry)
    case stale
    case unknown
    case noSession
}

/// The persisted session: the minimal state needed to re-resolve refs in a later
/// process without any AX/TCC access at load time.
///
/// It stores the app bundle id + pid the snapshot was taken from, a `digest`
/// fingerprint of the walked tree, and the value-free ref table (`RefEntry`).
/// The full node tree is INTENTIONALLY omitted: the ref table's handle-free hints
/// plus the digest are all the act layer needs to re-locate elements on a fresh
/// walk, and omitting the tree keeps the file small and guarantees no node
/// `value` (a possible secret) is ever written — `RefEntry` carries no value.
public struct Session: Equatable, Sendable, Codable {
    /// Schema version, so a future format change can be detected instead of
    /// silently mis-decoding. Bumped when the persisted shape changes.
    public static let currentVersion = 1

    public let version: Int
    /// Bundle id of the app the snapshot was taken from.
    public let app: String
    /// Process id of that app at snapshot time.
    public let pid: Int32
    /// Deterministic fingerprint of the walked tree (see `Session.digest(of:)`).
    /// Lets a later feature detect that the UI changed since this snapshot.
    public let digest: String
    /// Ref string (`e5`) -> handle-free re-resolution hints. The source of truth
    /// for resolution; carries NO node value, so secrets never persist.
    public let refs: [String: RefEntry]

    public init(version: Int = Session.currentVersion, app: String, pid: Int32, digest: String, refs: [String: RefEntry]) {
        self.version = version
        self.app = app
        self.pid = pid
        self.digest = digest
        self.refs = refs
    }

    /// Build a session from a rendered `Snapshot`, computing the tree digest.
    public init(snapshot: Snapshot, app: String, pid: Int32) {
        self.init(app: app, pid: pid, digest: Session.digest(of: snapshot), refs: snapshot.refs)
    }

    /// Resolve `ref` against THIS session. Never returns `.noSession` (the
    /// session exists by construction); callers use `SessionStore.resolve` for
    /// the no-session case.
    public func resolve(_ ref: String) -> RefResolution {
        if let entry = refs[ref] { return .resolved(entry) }
        return Session.isRefToken(ref) ? .stale : .unknown
    }

    /// Whether `token` is syntactically a ref this tool issues: the ref prefix
    /// (`e`) followed by a positive decimal integer. Leading-zero forms like
    /// `e01` are accepted as tokens (a plausible typo of a real ref); genuinely
    /// non-numeric or empty suffixes are not. This is the exit-3-vs-64
    /// discriminator the act layer reuses.
    public static func isRefToken(_ token: String) -> Bool {
        guard token.hasPrefix(Snapshot.refPrefix) else { return false }
        let digits = token.dropFirst(Snapshot.refPrefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        guard let value = Int(digits), value >= 1 else { return false }
        return true
    }

    /// A deterministic, byte-stable fingerprint of the snapshot's tree, derived
    /// from its canonical JSON rendering (which already masks secure values).
    /// Being a one-way FNV-1a hash, it leaks no content; it exists only to detect
    /// that the UI changed between snapshots.
    static func digest(of snapshot: Snapshot) -> String {
        fnv1a64(SnapshotJSON.render(snapshot))
    }

    private static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
