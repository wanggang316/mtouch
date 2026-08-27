import Foundation

/// A failure to prepare the run evidence bundle. Both cases name the offending
/// path so the caller can surface it (mapping to exit 1). It is thrown BEFORE the
/// documented operation runs — exactly like `TrajectoryError` — so an unusable
/// `MTOUCH_RUN_DIR` aborts the command rather than performing a silent,
/// undocumented run.
public enum RunBundleError: Error, LocalizedError, Equatable {
    /// The configured run directory already exists and is a regular file.
    case pathIsFile(String)
    /// The directory could not be created/opened for writing (parent not
    /// writable, read-only location, …). `reason` carries the system message.
    case notWritable(path: String, reason: String)

    /// Stderr diagnostic, in the project's `mtouch: …` voice.
    public var diagnostic: String {
        switch self {
        case let .pathIsFile(path):
            return "mtouch: cannot open run directory: path is a file: \(path)"
        case let .notWritable(path, reason):
            return "mtouch: cannot write run directory \(path): \(reason)"
        }
    }

    public var errorDescription: String? { diagnostic }
}

/// Which screen state a step's PNG holds.
///
/// A mutating command brackets itself with `.before`/`.after`; a read-only
/// command has nothing to bracket, so its single capture is `.state` rather than
/// a lone `before` that would read as a missing `after`.
public enum RunStepSlot: String, Sendable, CaseIterable {
    case before
    case after
    case state
}

/// One allocated step in a run: its ordinal and the command that owns it. The
/// ordinal is handed out under the bundle's exclusive lock, so two concurrent
/// mtouch processes can never claim the same number.
public struct RunStep: Sendable, Equatable {
    public let index: Int
    /// The owning command name, already reduced to filename-safe characters.
    public let command: String

    public init(index: Int, command: String) {
        self.index = index
        self.command = RunBundle.filenameSafe(command)
    }

    /// Zero-padded ordinal (`0001`), so a plain lexical `ls` of `steps/` is also
    /// chronological.
    public var indexText: String { String(format: "%04d", index) }

    /// The step image's path RELATIVE to the run root
    /// (`steps/0001-act-before.png`). Relative so a bundle can be moved or
    /// archived without rewriting its records.
    public func relativePath(_ slot: RunStepSlot) -> String {
        "\(RunBundle.stepsDirectoryName)/\(indexText)-\(command)-\(slot.rawValue).png"
    }
}

/// The evidence a single record collected: the step images that were written,
/// the moments MARKED inside a live recording instead of being captured, and —
/// when either failed — WHY. A failure is data in the record, never an error that
/// propagates, because an evidence system that can fail the run it is documenting
/// is worse than none.
public struct RunEvidence: Sendable, Equatable {
    public var before: String?
    public var after: String?
    public var state: String?
    public var captureError: String?
    /// Slots whose still was NOT captured because a recording was live, each
    /// carrying where in the movie the moment sits. `mtouch report` materializes
    /// these into `steps/` PNGs under the very same names a direct capture would
    /// have used.
    public var frames: [RunStepSlot: RunStepFrame]

    public init(
        before: String? = nil,
        after: String? = nil,
        state: String? = nil,
        captureError: String? = nil,
        frames: [RunStepSlot: RunStepFrame] = [:]
    ) {
        self.before = before
        self.after = after
        self.state = state
        self.captureError = captureError
        self.frames = frames
    }

    public var isEmpty: Bool {
        before == nil && after == nil && state == nil && captureError == nil && frames.isEmpty
    }

    public subscript(slot: RunStepSlot) -> String? {
        get {
            switch slot {
            case .before: return before
            case .after: return after
            case .state: return state
            }
        }
        set {
            switch slot {
            case .before: before = newValue
            case .after: after = newValue
            case .state: state = newValue
            }
        }
    }

    /// Record a capture failure, keeping any earlier one: a step whose before AND
    /// after both failed says so once, in order.
    public mutating func note(failure: String, slot: RunStepSlot) {
        let entry = "\(slot.rawValue): \(failure)"
        captureError = captureError.map { "\($0); \(entry)" } ?? entry
    }

    /// Compact JSON object with sorted keys, matching the hand-rolled rendering
    /// the rest of the record uses.
    func jsonObject() -> String {
        var fields: [String] = []
        if let after { fields.append("\"after\":\(JSONText.string(after))") }
        if let before { fields.append("\"before\":\(JSONText.string(before))") }
        if let captureError { fields.append("\"captureError\":\(JSONText.string(captureError))") }
        if !frames.isEmpty {
            let body = frames.keys.sorted { $0.rawValue < $1.rawValue }.map { slot in
                "\(JSONText.string(slot.rawValue)):\(frames[slot]!.jsonObject())"
            }.joined(separator: ",")
            fields.append("\"frames\":{\(body)}")
        }
        if let state { fields.append("\"state\":\(JSONText.string(state))") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Parse the `frames` object of a recorded evidence blob, dropping any entry
    /// whose slot or marker is unreadable.
    static func parseFrames(_ object: [String: Any]?) -> [RunStepSlot: RunStepFrame] {
        guard let object else { return [:] }
        var frames: [RunStepSlot: RunStepFrame] = [:]
        for (key, value) in object {
            guard let slot = RunStepSlot(rawValue: key),
                  let marker = (value as? [String: Any]).flatMap(RunStepFrame.parse)
            else { continue }
            frames[slot] = marker
        }
        return frames
    }
}

/// The once-per-run facts in `run.json`. `stepCount` doubles as the step counter:
/// it is read-modify-written under the bundle's exclusive lock, and the file is
/// replaced ATOMICALLY, so a crash mid-allocation leaves either the old count or
/// the new one — never a truncated counter that would restart numbering on top of
/// existing files.
public struct RunMetadata: Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Absolute creation time (epoch seconds).
    public var createdAtWallClock: Double
    /// Machine-wide monotonic creation time (`systemUptime`), so a record's own
    /// monotonic timestamp is directly comparable to the run's start.
    public var createdAtMonotonic: Double
    public var mtouchVersion: String
    public var macOSVersion: String
    public var label: String?
    public var stepCount: Int

    public init(
        schemaVersion: Int = RunMetadata.currentSchemaVersion,
        createdAtWallClock: Double,
        createdAtMonotonic: Double,
        mtouchVersion: String = MTouchVersion.current,
        macOSVersion: String = RunMetadata.systemVersionText(),
        label: String? = nil,
        stepCount: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.createdAtWallClock = createdAtWallClock
        self.createdAtMonotonic = createdAtMonotonic
        self.mtouchVersion = mtouchVersion
        self.macOSVersion = macOSVersion
        self.label = label
        self.stepCount = stepCount
    }

    /// `<major>.<minor>.<patch>` of the running OS.
    public static func systemVersionText() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Compact JSON with sorted keys (project pattern), so the file is stable
    /// byte-for-byte for a given set of facts.
    public func jsonText() -> String {
        var fields: [String] = [
            "\"createdAt\":{\"monotonic\":\(JSONText.number(createdAtMonotonic)),"
                + "\"wallClock\":\(JSONText.number(createdAtWallClock))}",
        ]
        if let label { fields.append("\"label\":\(JSONText.string(label))") }
        fields.append("\"macOSVersion\":\(JSONText.string(macOSVersion))")
        fields.append("\"mtouchVersion\":\(JSONText.string(mtouchVersion))")
        fields.append("\"schemaVersion\":\(schemaVersion)")
        fields.append("\"stepCount\":\(stepCount)")
        return "{" + fields.joined(separator: ",") + "}\n"
    }

    /// Parse `run.json` bytes, or nil when they are missing/unparseable. A
    /// damaged file degrades to absence — never a crash — mirroring `SessionStore`.
    public static func parse(_ data: Data) -> RunMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let createdAt = object["createdAt"] as? [String: Any]
        return RunMetadata(
            schemaVersion: object["schemaVersion"] as? Int ?? currentSchemaVersion,
            createdAtWallClock: createdAt?["wallClock"] as? Double ?? 0,
            createdAtMonotonic: createdAt?["monotonic"] as? Double ?? 0,
            mtouchVersion: object["mtouchVersion"] as? String ?? "",
            macOSVersion: object["macOSVersion"] as? String ?? "",
            label: object["label"] as? String,
            stepCount: object["stepCount"] as? Int ?? 0
        )
    }
}

/// ONE self-describing folder proving what a sequence of mtouch commands did:
///
/// ```
/// <run>/
///   run.json           once-per-run facts + the step counter
///   trajectory.jsonl   the recorder stream, auto-pointed here
///   steps/             per-step PNGs (opt-in)
///   video/             reserved for screen recording; absent until then
///   report.html        rendered by `mtouch report`
/// ```
///
/// Opening is IDEMPOTENT: a second command pointed at an existing run appends to
/// it, leaving `run.json` and the numbering alone. Several processes may share one
/// run, so every mutation of the counter happens under an advisory exclusive lock
/// on `.lock` — a dedicated file, because `run.json` is replaced by `rename(2)`
/// and a lock held on the replaced inode would protect nothing.
public struct RunBundle: Sendable, Equatable {
    public static let metadataFileName = "run.json"
    public static let trajectoryFileName = "trajectory.jsonl"
    public static let reportFileName = "report.html"
    public static let stepsDirectoryName = "steps"
    /// Reserved for the screen-recording pass. Deliberately NOT created here: an
    /// empty directory in every bundle would claim evidence that does not exist.
    /// The report treats its absence as "no recording", not as damage.
    public static let videoDirectoryName = "video"
    static let lockFileName = ".lock"

    /// Absolute path of the run root.
    public let root: String

    public init(root: String) {
        self.root = root
    }

    public var metadataPath: String { child(RunBundle.metadataFileName) }
    public var trajectoryPath: String { child(RunBundle.trajectoryFileName) }
    public var reportPath: String { child(RunBundle.reportFileName) }
    public var stepsDirectory: String { child(RunBundle.stepsDirectoryName) }
    public var videoDirectory: String { child(RunBundle.videoDirectoryName) }
    /// The handshake file a recording into THIS bundle publishes. It is where
    /// `RecordPlan` puts it for a run directory, named here so anything asking
    /// "is a recording live for this run?" reads the one true location.
    public var recordControlPath: String {
        URL(fileURLWithPath: videoDirectory).appendingPathComponent(RecordPlan.controlFileName).path
    }
    var lockPath: String { child(RunBundle.lockFileName) }

    public func child(_ name: String) -> String {
        URL(fileURLWithPath: root).appendingPathComponent(name).path
    }

    /// The absolute path of a run-root-relative path recorded in a step's evidence.
    public func absolutePath(forRelative relative: String) -> String {
        URL(fileURLWithPath: root).appendingPathComponent(relative).path
    }

    /// `absolute` expressed relative to the run root when it sits inside the
    /// bundle, unchanged otherwise.
    ///
    /// The inverse of `absolutePath(forRelative:)`, and the reason a recorded
    /// path survives the bundle being moved or archived. A movie written outside
    /// the bundle (`record start --out …`) cannot be made relative, so it is
    /// recorded as what it is.
    public func relativePath(forAbsolute absolute: String) -> String {
        let base = URL(fileURLWithPath: root).standardized.path
        let target = URL(fileURLWithPath: absolute).standardized.path
        guard target.hasPrefix(base + "/") else { return absolute }
        return String(target.dropFirst(base.count + 1))
    }

    // MARK: - Opening

    /// The bundle `environment` selects, or nil when `MTOUCH_RUN_DIR` is unset or
    /// empty (no run: every command behaves exactly as before).
    ///
    /// Throws BEFORE the caller's operation when the directory is unusable, so an
    /// operator never gets a green exit for a run that recorded nothing.
    public static func resolve(
        environment: [String: String],
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        wallNow: () -> Double = { Date().timeIntervalSince1970 }
    ) throws -> RunBundle? {
        guard let path = environment[MTouchEnvironment.runDirKey], !path.isEmpty else { return nil }
        let label = environment[MTouchEnvironment.runLabelKey].flatMap { $0.isEmpty ? nil : $0 }
        return try open(path: path, label: label, now: now, wallNow: wallNow)
    }

    /// Whether per-step screenshots are on. Opt-in (`1`/`true`/`yes`, case
    /// insensitive) because a capture costs real time on every action.
    public static func captureEnabled(environment: [String: String]) -> Bool {
        guard let raw = environment[MTouchEnvironment.runCaptureKey] else { return false }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    /// Create or re-open the bundle at `path`.
    ///
    /// Re-opening is idempotent: `run.json` is written only when it is ABSENT, and
    /// the check-and-write happens under the lock so two processes racing to
    /// create the same run cannot both stamp it.
    public static func open(
        path: String,
        label: String? = nil,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        wallNow: () -> Double = { Date().timeIntervalSince1970 }
    ) throws -> RunBundle {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw RunBundleError.pathIsFile(path)
        }

        let bundle = RunBundle(root: URL(fileURLWithPath: path).path)
        do {
            // `steps/` is created eagerly: it is where the very next capture lands,
            // and creating it here means a capture failure can only ever be about
            // the capture itself, not about the layout.
            try FileManager.default.createDirectory(atPath: bundle.stepsDirectory, withIntermediateDirectories: true)
        } catch {
            throw RunBundleError.notWritable(path: path, reason: message(for: error))
        }

        let fd = try bundle.openLock()
        defer { close(fd) }
        try bundle.mappingIOFailure {
            try LockedFile.withExclusiveLock(fd) {
                guard !FileManager.default.fileExists(atPath: bundle.metadataPath) else { return }
                let metadata = RunMetadata(
                    createdAtWallClock: wallNow(),
                    createdAtMonotonic: now(),
                    label: label
                )
                try bundle.writeMetadata(metadata)
            }
        }
        return bundle
    }

    // MARK: - Step allocation

    /// Claim the next step ordinal for `command`.
    ///
    /// The read-modify-write of the counter runs entirely under the bundle's
    /// exclusive lock, so two concurrent commands appending to one run get 1 and 2
    /// — never both 1, which would silently interleave their evidence under the
    /// same filenames.
    public func allocateStep(command: String) throws -> RunStep {
        let fd = try openLock()
        defer { close(fd) }
        return try mappingIOFailure {
            try LockedFile.withExclusiveLock(fd) {
                var metadata = loadMetadata() ?? recoveredMetadata()
                metadata.stepCount += 1
                try writeMetadata(metadata)
                return RunStep(index: metadata.stepCount, command: command)
            }
        }
    }

    /// The bundle's `run.json`, or nil when it is missing/damaged.
    public func loadMetadata() -> RunMetadata? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)) else { return nil }
        return RunMetadata.parse(data)
    }

    /// Metadata to fall back on when `run.json` was externally deleted or
    /// corrupted. The counter restarts ABOVE the highest ordinal already present in
    /// `steps/`, so recovery can never overwrite evidence that survived.
    private func recoveredMetadata() -> RunMetadata {
        RunMetadata(
            createdAtWallClock: Date().timeIntervalSince1970,
            createdAtMonotonic: ProcessInfo.processInfo.systemUptime,
            stepCount: highestStepOnDisk()
        )
    }

    private func highestStepOnDisk() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stepsDirectory)) ?? []
        return names.reduce(0) { highest, name in
            let ordinal = Int(name.prefix(while: { $0.isNumber })) ?? 0
            return max(highest, ordinal)
        }
    }

    // MARK: - Step images

    /// Persist one step's PNG bytes, returning its run-root-relative path.
    ///
    /// Returns a diagnostic instead of throwing: writing evidence must never be
    /// able to fail the operation it documents.
    public func writeStepImage(_ data: Data, step: RunStep, slot: RunStepSlot) -> Result<String, RunCaptureFailure> {
        let relative = step.relativePath(slot)
        switch ScreenCaptureWriter.write(data, to: absolutePath(forRelative: relative)) {
        case .success:
            return .success(relative)
        case let .failure(error):
            return .failure(RunCaptureFailure(error.diagnostic))
        }
    }

    // MARK: - Internals

    /// Open (creating if needed) the dedicated lock file. It carries no content:
    /// its only job is to be a STABLE inode every process can `flock`, which
    /// `run.json` cannot be because it is replaced by `rename(2)`.
    private func openLock() throws -> Int32 {
        // `Darwin.open` explicitly: the unqualified name also matches this type's
        // own `open(path:…)` factory.
        let fd = Darwin.open(lockPath, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw RunBundleError.notWritable(path: root, reason: String(cString: strerror(errno)))
        }
        return fd
    }

    /// Replace `run.json` atomically (temp file in the same directory + rename),
    /// so a concurrent reader sees the old file or the new one, never a partial.
    private func writeMetadata(_ metadata: RunMetadata) throws {
        let target = URL(fileURLWithPath: metadataPath)
        let temp = URL(fileURLWithPath: root)
            .appendingPathComponent(".\(RunBundle.metadataFileName).\(UUID().uuidString).tmp")
        do {
            try Data(metadata.jsonText().utf8).write(to: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw FileIOFailure(reason: RunBundle.message(for: error))
        }
        // Capture errno INSIDE the closure at the failure site: it can be clobbered
        // while the `withCString` buffers tear down (mirrors `SessionStore.save`).
        var renameErrno: Int32 = 0
        let renamed = temp.path.withCString { source in
            target.path.withCString { destination -> Int32 in
                let result = rename(source, destination)
                if result != 0 { renameErrno = errno }
                return result
            }
        }
        if renamed != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw FileIOFailure(code: renameErrno)
        }
    }

    private func mappingIOFailure<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as FileIOFailure {
            throw RunBundleError.notWritable(path: root, reason: failure.reason)
        }
    }

    /// Reduce a command name to ASCII characters that are safe in a filename on
    /// any filesystem, so a step image is always addressable by its printed path.
    /// Command names are already ASCII; this is a guard, not a transformation.
    static func filenameSafe(_ name: String) -> String {
        let mapped = String(name.map { character in
            character.isASCII && (character.isLetter || character.isNumber)
                || character == "." || character == "_" || character == "-"
                ? character
                : "-"
        })
        return mapped.isEmpty ? "command" : mapped
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    }
}
