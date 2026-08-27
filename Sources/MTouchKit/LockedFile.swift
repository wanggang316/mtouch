import Foundation

/// A low-level POSIX file failure. It carries ONLY the system reason, so each
/// caller wraps it in its own domain error (`TrajectoryError`, `RunBundleError`)
/// and keeps that domain's pinned diagnostic wording.
struct FileIOFailure: Error, Equatable {
    let reason: String

    init(code: Int32) { reason = String(cString: strerror(code)) }
    init(reason: String) { self.reason = reason }
}

/// The hardened multi-process file discipline shared by every mtouch writer that
/// SEVERAL processes may touch at once: the trajectory stream (concurrent
/// appends) and a run bundle's step counter (concurrent allocations).
///
/// Both guarantees live here once so the two callers cannot drift:
///
///   - `withExclusiveLock` holds an advisory `flock(LOCK_EX)` for the whole of a
///     critical section and releases it even when the body throws, so a
///     multi-write payload cannot interleave with another writer and a counter
///     read-modify-write cannot be lost.
///   - `writeAll` loops `write(2)` until the entire buffer is out, retrying on
///     `EINTR` and advancing past a partial write, so a short/interrupted write
///     completes rather than leaving a torn record.
enum LockedFile {
    /// Run `body` while holding an advisory EXCLUSIVE lock on `fd`. The lock
    /// acquisition itself retries on `EINTR`; the release is unconditional.
    static func withExclusiveLock<T>(_ fd: Int32, _ body: () throws -> T) throws -> T {
        while flock(fd, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw FileIOFailure(code: code)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// Write `data` to `fd` COMPLETELY. A no-error/no-progress write is refused
    /// rather than spun on forever.
    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            let total = buffer.count
            var offset = 0
            while offset < total {
                let written = write(fd, base + offset, total - offset)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }   // interrupted before any byte: retry
                    throw FileIOFailure(code: code)
                }
                if written == 0 {
                    throw FileIOFailure(reason: "write made no progress (\(offset)/\(total) bytes)")
                }
                offset += written                   // advance past a partial write
            }
        }
    }
}
