import Foundation

/// The live `InitHost`: the real PATH, real subprocesses, the real filesystem.
///
/// Two details are load-bearing.
///
/// PATH lookup is done HERE rather than by asking a shell (`which`, `command -v`).
/// Spawning a shell to find a program means the program's name reaches a shell
/// parser, and it makes the answer depend on which shell and which rc files the
/// machine happens to have.
///
/// The child's output is collected through a TEMPORARY FILE, not a pipe. A pipe
/// has a fixed kernel buffer, so a child that outsings it blocks forever unless
/// something drains the pipe concurrently — and a draining thread is exactly the
/// kind of lingering background work this project keeps out of its command paths.
/// A file has no such limit and needs no thread, which leaves the wait loop free
/// to be a plain poll with a deadline.
public struct LiveInitHost: InitHost {
    /// Ceiling on a client CLI invocation. Generous: `mcp get` health-checks the
    /// server it is asked about, which means launching it. Exceeding this is
    /// reported as a failure, never as "no such server" — mis-reading a hung
    /// probe as "not registered" would produce a duplicate registration attempt.
    public static let commandTimeout: TimeInterval = 120
    static let pollInterval: TimeInterval = 0.02

    public let executablePath: String
    public let homeDirectory: String
    private let searchPath: String

    public init(
        executablePath: String = LiveRecordHost.currentExecutablePath(),
        homeDirectory: String = NSHomeDirectory(),
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.executablePath = executablePath
        self.homeDirectory = homeDirectory
        self.searchPath = searchPath
    }

    // MARK: - PATH

    public func locate(_ tool: String) -> String? {
        // A name that is already a path is taken at face value; only bare names
        // are searched.
        if tool.contains("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = (String(directory) as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Subprocesses

    public func run(_ executable: String, _ arguments: [String]) -> Result<InitCommandResult, InitFailure> {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtouch-init-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: transcript.path, contents: nil) else {
            return .failure(InitFailure("could not create a temporary file to capture the command's output"))
        }
        defer { try? FileManager.default.removeItem(at: transcript) }
        guard let sink = FileHandle(forWritingAtPath: transcript.path) else {
            return .failure(InitFailure("could not open a temporary file to capture the command's output"))
        }
        defer { try? sink.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = sink
        process.standardError = sink
        // The client CLI must never inherit an interactive stdin: it would sit
        // waiting on a prompt inside a non-interactive mtouch run.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(InitFailure((error as NSError).localizedDescription))
        }

        let deadline = Date(timeIntervalSinceNow: LiveInitHost.commandTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: LiveInitHost.pollInterval)
        }
        if process.isRunning {
            process.terminate()
            return .failure(InitFailure(
                "\(executable) did not finish within \(Int(LiveInitHost.commandTimeout))s; it was stopped"
            ))
        }
        process.waitUntilExit()

        let data = (try? Data(contentsOf: transcript)) ?? Data()
        return .success(InitCommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        ))
    }

    // MARK: - Files

    public func readFile(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func writeFile(_ contents: String, to path: String) -> Result<Void, InitFailure> {
        // Same pinned write rules as every other file mtouch produces: parents
        // created, a directory at the path reported rather than clobbered, and an
        // atomic rename so a failure leaves no debris.
        switch ScreenCaptureWriter.write(Data(contents.utf8), to: path) {
        case .success:
            return .success(())
        case let .failure(error):
            return .failure(InitFailure(reason(for: error)))
        }
    }

    /// The writer's failures are phrased for a screenshot ("cannot write
    /// screenshot to …"), so only their REASON is carried across; the caller
    /// supplies the sentence around it.
    private func reason(for error: ScreenCaptureError) -> String {
        switch error {
        case let .pathIsDirectory(path): "\(path) is a directory"
        case let .notWritable(_, reason): reason
        default: error.diagnostic
        }
    }
}
