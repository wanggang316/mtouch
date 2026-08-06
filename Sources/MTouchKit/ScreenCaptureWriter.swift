import Foundation

/// Persists capture bytes to a path, mirroring `SessionStore`'s pinned write
/// rules so `screenshot` and `snapshot` behave identically at the filesystem:
///
/// - Missing parent directories are CREATED (the recording-feature rule).
/// - An existing directory at the path is a precise failure, never a clobber.
/// - The write is ATOMIC (temp file in the same directory + `rename`), so a
///   failure leaves NO debris — no partial or temp file — and an existing file
///   is replaced only on success.
public enum ScreenCaptureWriter {
    /// Writes `data` to `path` atomically. Returns a `ScreenCaptureError` (never
    /// throws) so the pipeline can map it to the pinned diagnostic + exit 1.
    public static func write(_ data: Data, to path: String) -> Result<Void, ScreenCaptureError> {
        let target = URL(fileURLWithPath: path)

        // A directory can never be an image file; report it precisely and leave
        // it untouched.
        if isDirectory(path) {
            return .failure(.pathIsDirectory(path))
        }

        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.notWritable(path: path, reason: message(for: error)))
        }

        // Write to a uniquely named temp in the SAME directory, then rename into
        // place. `rename(2)` is atomic and replaces any existing file; on any
        // failure the temp is removed so nothing is left behind.
        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return .failure(.notWritable(path: path, reason: message(for: error)))
        }

        let renamed = temp.path.withCString { source in
            target.path.withCString { destination in
                rename(source, destination)
            }
        }
        if renamed != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            return .failure(.notWritable(path: path, reason: reason))
        }
        return .success(())
    }

    /// Whether `path` currently exists AND is a directory.
    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    }
}
