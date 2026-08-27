import Foundation

/// The observable outcome of a `report` invocation, kept SEPARATE from the side
/// effects (printing, exiting) so the whole flow is unit-testable.
public enum ReportOutcome: Equatable, Sendable {
    case rendered(path: String, message: String)
    case failed(stderr: String, code: MTouchExitCode)
}

/// Composes `mtouch report`: locate the run bundle → load it (totally, degrading
/// every absence into a statement) → materialize the stills its steps deferred to
/// the recording → render deterministic HTML → write it.
///
/// The command is deliberately NOT itself recorded: it reads a bundle and writes
/// a derived artifact, so recording it would append to the very trajectory it
/// just rendered and make the report disagree with its own bundle.
public enum ReportPipeline {
    public static func run(
        runDirectory: String,
        out: String?,
        redact: Bool = false,
        extractor: RunFrameExtracting = LiveFrameExtractor()
    ) -> ReportOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: runDirectory, isDirectory: &isDirectory) else {
            return .failed(
                stderr: "mtouch: run directory not found: \(runDirectory)",
                code: .runtimeFailure
            )
        }
        guard isDirectory.boolValue else {
            return .failed(
                stderr: "mtouch: not a run directory: \(runDirectory) is a file. "
                    + "Pass the directory a run was recorded into (MTOUCH_RUN_DIR / --run-dir).",
                code: .runtimeFailure
            )
        }

        var bundle = RunReportLoader.load(runDirectory: runDirectory)
        // Cut the deferred stills out of the movie BEFORE rendering, so the
        // renderer stays a pure function of its input. Skipped under --redact:
        // that flag exists to keep imagery out of the render, and materializing
        // would create new imagery on disk to then omit.
        if !redact {
            bundle = RunFrameMaterializer.materialize(bundle, extractor: extractor)
        }
        let html = RunReportHTML.render(bundle, redact: redact)
        let path = out ?? RunBundle(root: bundle.root).reportPath
        let data = Data(html.utf8)

        if ScreenCaptureWriter.isDirectory(path) {
            return .failed(stderr: "mtouch: cannot write report: path is a directory: \(path)", code: .runtimeFailure)
        }
        let target = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: target, options: .atomic)
        } catch {
            return .failed(
                stderr: "mtouch: cannot write report to \(path): \(message(for: error))",
                code: .runtimeFailure
            )
        }
        return .rendered(path: path, message: message(path: path, bundle: bundle, bytes: data.count))
    }

    /// The pinned human line: `wrote <path> (<n> records, <k> failed, <bytes> bytes)`.
    /// The byte count is there because inlining screenshots makes the file large
    /// enough that an operator should not be surprised by it.
    static func message(path: String, bundle: RunReportBundle, bytes: Int) -> String {
        var parts = ["\(bundle.records.count) records", "\(bundle.failedCount) failed"]
        if bundle.unreadableCount > 0 {
            parts.append("\(bundle.unreadableCount) unreadable")
        }
        parts.append("\(bytes) bytes")
        return "wrote \(path) (\(parts.joined(separator: ", ")))"
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    }
}
