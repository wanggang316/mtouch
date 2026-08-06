import Foundation

/// A failure to PERSIST a session. Both cases name the offending path so the CLI
/// can surface it (mapping to exit 1, `runtimeFailure`). A `save` never silently
/// "succeeds" without writing: any inability to persist throws.
public enum SessionStoreError: Error, LocalizedError, CustomStringConvertible, Equatable {
    /// The target path already exists and is a directory.
    case pathIsDirectory(String)
    /// The target could not be written (parent not writable, read-only location,
    /// rename failed, …). `reason` carries the underlying system message.
    case notWritable(path: String, reason: String)

    public var description: String {
        switch self {
        case let .pathIsDirectory(path):
            return "cannot write session: path is a directory: \(path)"
        case let .notWritable(path, reason):
            return "cannot write session to \(path): \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

/// Persists a `Snapshot` as a `Session` and resolves refs against it.
///
/// Writes are ATOMIC (temp file in the same directory + `rename`), so a
/// concurrent reader never observes a half-written file and two stores on
/// DISTINCT paths never interfere. Reads treat a missing OR corrupt file as
/// simply absent (`nil`) — corruption never crashes and never propagates
/// garbage; a subsequent `save` overwrites it cleanly.
public enum SessionStore {
    /// The effective session-file path. `MTOUCH_SESSION`, when set to a
    /// non-empty value, is used VERBATIM (this is how concurrent sessions
    /// isolate). Otherwise the default is `$HOME/.mtouch/session.json`, taking
    /// `HOME` from the injected environment so tests never touch the real home.
    /// The env dict is injected rather than read globally so this is unit-testable.
    public static func sessionFilePath(environment: [String: String]) -> String {
        if let override = environment[MTouchEnvironment.sessionKey], !override.isEmpty {
            return override
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".mtouch", isDirectory: true)
            .appendingPathComponent("session.json")
            .path
    }

    /// Persist `snapshot` (taken from `app`/`pid`) to `path`, atomically.
    ///
    /// Missing parent directories are created (consistent with the recording
    /// feature's pinned rule). Throws `SessionStoreError` — never silently fails —
    /// when the target is a directory or the location is not writable.
    public static func save(_ snapshot: Snapshot, app: String, pid: Int32, to path: String) throws {
        let session = Session(snapshot: snapshot, app: app, pid: pid)
        let data = try encoder.encode(session)

        let target = URL(fileURLWithPath: path)
        let directory = target.deletingLastPathComponent()

        // A directory can never be a session file; report it precisely.
        if isDirectory(target.path) {
            throw SessionStoreError.pathIsDirectory(path)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SessionStoreError.notWritable(path: path, reason: message(for: error))
        }

        // Write to a uniquely named temp file in the SAME directory, then rename
        // into place. `rename(2)` is atomic and replaces any existing file, so a
        // reader sees either the old file or the new one — never a partial write.
        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
        } catch {
            throw SessionStoreError.notWritable(path: path, reason: message(for: error))
        }

        // Capture errno INSIDE the closure at the failure site: it can be
        // clobbered while the `withCString` buffers tear down, so reading it after
        // the call could report a stale/unrelated reason.
        var renameErrno: Int32 = 0
        let renamed = temp.path.withCString { source in
            target.path.withCString { destination -> Int32 in
                let result = rename(source, destination)
                if result != 0 { renameErrno = errno }
                return result
            }
        }
        if renamed != 0 {
            let reason = String(cString: strerror(renameErrno))
            try? FileManager.default.removeItem(at: temp)
            throw SessionStoreError.notWritable(path: path, reason: reason)
        }
    }

    /// Load the session at `path`, or `nil` when the file is MISSING, CORRUPT
    /// (unparseable JSON), or of a MISMATCHED schema version. All three degrade to
    /// absence — never a crash — so a stray/garbage/future-version file reads as
    /// "no session" and the next `save` heals it. The version gate keeps a future
    /// v2 file from being mis-decoded by a v1 binary.
    public static func load(from path: String) -> Session? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let session = try? decoder.decode(Session.self, from: data),
              session.version == Session.currentVersion
        else { return nil }
        return session
    }

    /// Resolve `ref` against an already-loaded session (`nil` ⇒ `.noSession`).
    public static func resolve(_ ref: String, in session: Session?) -> RefResolution {
        guard let session else { return .noSession }
        return session.resolve(ref)
    }

    /// Resolve `ref` against the session persisted at `path`, loading it first.
    /// A missing/corrupt file yields `.noSession`.
    public static func resolve(_ ref: String, from path: String) -> RefResolution {
        resolve(ref, in: load(from: path))
    }

    // MARK: - Internals

    /// `.sortedKeys` makes the persisted bytes deterministic across runs; the
    /// round-trip correctness itself only relies on Codable symmetry.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    }
}
