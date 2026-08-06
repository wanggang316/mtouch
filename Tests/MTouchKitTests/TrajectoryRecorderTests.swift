import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures & helpers

private func button(_ title: String) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: CGRect(x: 0, y: 0, width: 100, height: 20), actionable: true)
}

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

/// A fresh, unique temp directory removed at the end of the closure. Tests write
/// ONLY here — never the real home or a shared /tmp trajectory.
private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-trajectory-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

/// Persist a session with the given labels and return its tree digest, so a test
/// can assert a record's digest field against the exact value the store wrote.
@discardableResult
private func writeSession(_ titles: [String], app: String, pid: Int32, to path: String) throws -> String {
    let snapshot = Snapshot(roots: [window(titles.map(button))])
    try SessionStore.save(snapshot, app: app, pid: pid, to: path)
    return try #require(SessionStore.load(from: path)).digest
}

/// Parse a trajectory file into records; each line must be a complete JSON object
/// (this is the `jq -c .` guarantee, asserted structurally).
private func readRecords(_ path: String) throws -> [[String: Any]] {
    let content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
    return try lines.map { line in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any])
    }
}

private func info(ok: Bool, exit: Int32?, errorClass: String?, diff: String? = nil, screenshotPath: String? = nil) -> TrajectoryOutcomeInfo {
    TrajectoryOutcomeInfo(ok: ok, exit: exit, errorClass: errorClass, diff: diff, screenshotPath: screenshotPath)
}

// MARK: - Toggle & transparency

@Suite struct TrajectoryToggleTests {
    @Test func recordingOffIsPurePassThroughAndWritesNothing() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            // Env WITHOUT MTOUCH_TRAJECTORY: recording is off.
            let result = try TrajectoryRecorder.record(
                command: "apps", args: TrajectoryArgs(), kind: .read,
                environment: ["HOME": dir.path],
                operation: { 42 },
                describe: { _ in info(ok: true, exit: 0, errorClass: nil) }
            )
            #expect(result == 42)                                  // result unchanged
            #expect(!FileManager.default.fileExists(atPath: trajectory))  // no phantom file
        }
    }

    @Test func setThenUnsetThenSetLeavesOnlyOnPhaseRecords() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let on = ["MTOUCH_TRAJECTORY": trajectory, "MTOUCH_SESSION": dir.appendingPathComponent("s.json").path]
            let off = ["MTOUCH_SESSION": dir.appendingPathComponent("s.json").path]

            _ = try TrajectoryRecorder.record(command: "apps", args: TrajectoryArgs(), kind: .read,
                environment: on, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            _ = try TrajectoryRecorder.record(command: "apps", args: TrajectoryArgs(), kind: .read,
                environment: off, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            _ = try TrajectoryRecorder.record(command: "apps", args: TrajectoryArgs(), kind: .read,
                environment: on, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })

            // The off phase left no line: only the two on-phase records exist.
            let records = try readRecords(trajectory)
            #expect(records.count == 2)
        }
    }
}

// MARK: - Record shaping per class

@Suite struct TrajectoryShapeTests {
    @Test func snapshotRecordCarriesDigestAndNoPrePostPair() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let session = dir.appendingPathComponent("s.json").path
            let digest = try writeSession(["A", "B"], app: "app", pid: 1, to: session)
            let env = ["MTOUCH_TRAJECTORY": trajectory, "MTOUCH_SESSION": session]

            _ = try TrajectoryRecorder.record(command: "snapshot",
                args: TrajectoryArgs.build(["app": .string("app")]), kind: .snapshot,
                environment: env, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })

            let record = try #require(try readRecords(trajectory).first)
            #expect(record["command"] as? String == "snapshot")
            #expect(record["digest"] as? String == digest)
            #expect(record["preDigest"] == nil)
            #expect(record["postDigest"] == nil)
            #expect(record["diff"] == nil)
            let outcome = try #require(record["outcome"] as? [String: Any])
            #expect(outcome["ok"] as? Bool == true)
        }
    }

    @Test func mutatingRecordCarriesPrePostDigestsAndDiff() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let session = dir.appendingPathComponent("s.json").path
            let preDigest = try writeSession(["A"], app: "app", pid: 1, to: session)
            let env = ["MTOUCH_TRAJECTORY": trajectory, "MTOUCH_SESSION": session]

            var postDigest = ""
            _ = try TrajectoryRecorder.record(command: "act",
                args: TrajectoryArgs.build(["verb": .string("press"), "ref": .string("e1")]), kind: .action,
                environment: env,
                operation: {
                    // The act persists a new session (a different tree ⇒ new digest).
                    postDigest = (try? writeSession(["A", "B"], app: "app", pid: 1, to: session)) ?? ""
                },
                describe: { _ in info(ok: true, exit: 0, errorClass: nil, diff: "+ e2 AXButton \"B\"") })

            let record = try #require(try readRecords(trajectory).first)
            #expect(record["command"] as? String == "act")
            #expect(record["preDigest"] as? String == preDigest)
            #expect(record["postDigest"] as? String == postDigest)
            #expect(preDigest != postDigest)
            #expect(record["diff"] as? String == "+ e2 AXButton \"B\"")
            #expect(record["digest"] == nil)
        }
    }

    @Test func readRecordCarriesNoDigests() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let session = dir.appendingPathComponent("s.json").path
            try writeSession(["A"], app: "app", pid: 1, to: session)
            let env = ["MTOUCH_TRAJECTORY": trajectory, "MTOUCH_SESSION": session]

            _ = try TrajectoryRecorder.record(command: "doctor",
                args: TrajectoryArgs.build(["json": .bool(true)]), kind: .read,
                environment: env, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })

            let record = try #require(try readRecords(trajectory).first)
            #expect(record["digest"] == nil)
            #expect(record["preDigest"] == nil)
            #expect(record["postDigest"] == nil)
            #expect(record["diff"] == nil)
            #expect(record["screenshotPath"] == nil)
        }
    }

    @Test func screenshotRecordReferencesPathNeverBytes() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let env = ["MTOUCH_TRAJECTORY": trajectory]
            let pngPath = "/tmp/mtouch-shot.png"

            _ = try TrajectoryRecorder.record(command: "screenshot",
                args: TrajectoryArgs.build(["out": .string(pngPath)]), kind: .screenshot,
                environment: env, operation: {},
                describe: { _ in info(ok: true, exit: 0, errorClass: nil, screenshotPath: pngPath) })

            let raw = try String(contentsOf: URL(fileURLWithPath: trajectory), encoding: .utf8)
            let record = try #require(try readRecords(trajectory).first)
            #expect(record["screenshotPath"] as? String == pngPath)
            #expect(record["digest"] == nil)
            // No base64 image payload anywhere in the line.
            #expect(!raw.contains("base64"))
            #expect(!raw.contains("iVBOR"))   // the standard PNG base64 header
        }
    }

    @Test func failureRecordsExitCodeAndErrorClass() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let session = dir.appendingPathComponent("s.json").path
            try writeSession(["A"], app: "app", pid: 1, to: session)
            let env = ["MTOUCH_TRAJECTORY": trajectory, "MTOUCH_SESSION": session]

            _ = try TrajectoryRecorder.record(command: "act",
                args: TrajectoryArgs.build(["verb": .string("press"), "ref": .string("e9")]), kind: .action,
                environment: env, operation: {},
                describe: { _ in info(ok: false, exit: MTouchExitCode.refError.rawValue, errorClass: "ref") })

            let record = try #require(try readRecords(trajectory).first)
            let outcome = try #require(record["outcome"] as? [String: Any])
            #expect(outcome["ok"] as? Bool == false)
            #expect(outcome["exit"] as? Int == 3)
            #expect(outcome["errorClass"] as? String == "ref")
        }
    }
}

// MARK: - Digest chain (VAL-REC-014)

@Suite struct TrajectoryDigestChainTests {
    @Test func consecutiveMutatingRecordsLinkPrevPostToNextPre() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let session = dir.appendingPathComponent("s.json").path
            try writeSession(["A"], app: "app", pid: 1, to: session)
            let env = ["MTOUCH_TRAJECTORY": trajectory, "MTOUCH_SESSION": session]

            // Two acts, each persisting a distinct new tree — no intervening snapshot.
            _ = try TrajectoryRecorder.record(command: "act",
                args: TrajectoryArgs.build(["verb": .string("type"), "text": .string("x")]), kind: .action,
                environment: env,
                operation: { try? SessionStore.save(Snapshot(roots: [window([button("A"), button("B")])]), app: "app", pid: 1, to: session) },
                describe: { _ in info(ok: true, exit: 0, errorClass: nil, diff: "d1") })
            _ = try TrajectoryRecorder.record(command: "act",
                args: TrajectoryArgs.build(["verb": .string("type"), "text": .string("y")]), kind: .action,
                environment: env,
                operation: { try? SessionStore.save(Snapshot(roots: [window([button("A"), button("B"), button("C")])]), app: "app", pid: 1, to: session) },
                describe: { _ in info(ok: true, exit: 0, errorClass: nil, diff: "d2") })

            let records = try readRecords(trajectory)
            #expect(records.count == 2)
            let firstPost = records[0]["postDigest"] as? String
            let secondPre = records[1]["preDigest"] as? String
            #expect(firstPost != nil)
            #expect(secondPre == firstPost)                        // the chain links
            #expect(records[0]["preDigest"] as? String != firstPost)  // a real change happened
        }
    }
}

// MARK: - Secret safety (VAL-REC-007)

@Suite struct TrajectorySecretSafetyTests {
    @Test func secureRefusedTypeRecordsEventButNeverThePayload() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let session = dir.appendingPathComponent("s.json").path
            try writeSession(["A"], app: "app", pid: 1, to: session)
            let env = ["MTOUCH_TRAJECTORY": trajectory, "MTOUCH_SESSION": session]
            let secret = "hunter2-topsecret"

            _ = try TrajectoryRecorder.record(command: "act",
                args: TrajectoryArgs.build(["verb": .string("type"), "text": .string(secret)]), kind: .action,
                environment: env, operation: {},
                describe: { _ in info(ok: false, exit: MTouchExitCode.secureInput.rawValue, errorClass: "secure-input") })

            let raw = try String(contentsOf: URL(fileURLWithPath: trajectory), encoding: .utf8)
            #expect(!raw.contains(secret))                         // payload absent from the file

            let record = try #require(try readRecords(trajectory).first)
            let args = try #require(record["args"] as? [String: Any])
            #expect(args["text"] == nil)                           // no text key at all
            #expect(args["verb"] as? String == "type")             // but the event IS recorded
            let outcome = try #require(record["outcome"] as? [String: Any])
            #expect(outcome["errorClass"] as? String == "secure-input")
        }
    }

    @Test func successfulTypeKeepsTextForReplay() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let session = dir.appendingPathComponent("s.json").path
            try writeSession(["A"], app: "app", pid: 1, to: session)
            let env = ["MTOUCH_TRAJECTORY": trajectory, "MTOUCH_SESSION": session]

            _ = try TrajectoryRecorder.record(command: "act",
                args: TrajectoryArgs.build(["verb": .string("type"), "text": .string("hello world")]), kind: .action,
                environment: env, operation: {},
                describe: { _ in info(ok: true, exit: 0, errorClass: nil, diff: "d") })

            let record = try #require(try readRecords(trajectory).first)
            let args = try #require(record["args"] as? [String: Any])
            #expect(args["text"] as? String == "hello world")
        }
    }
}

// MARK: - Unicode round-trip

@Suite struct TrajectoryUnicodeTests {
    @Test func unicodeArgsRoundTripThroughJSON() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let session = dir.appendingPathComponent("s.json").path
            try writeSession(["A"], app: "app", pid: 1, to: session)
            let env = ["MTOUCH_TRAJECTORY": trajectory, "MTOUCH_SESSION": session]
            let text = "café 日本語 🎉 \"quoted\"\nnewline\ttab"

            _ = try TrajectoryRecorder.record(command: "act",
                args: TrajectoryArgs.build(["verb": .string("type"), "text": .string(text)]), kind: .action,
                environment: env, operation: {},
                describe: { _ in info(ok: true, exit: 0, errorClass: nil, diff: "d") })

            let record = try #require(try readRecords(trajectory).first)
            let args = try #require(record["args"] as? [String: Any])
            #expect(args["text"] as? String == text)               // exact round-trip
        }
    }
}

// MARK: - Append-only & line-atomic (VAL-REC-008 / VAL-REC-013)

@Suite struct TrajectoryAppendTests {
    @Test func existingFileIsAppendedNeverTruncated() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let env = ["MTOUCH_TRAJECTORY": trajectory]

            _ = try TrajectoryRecorder.record(command: "apps", args: TrajectoryArgs.build(["json": .bool(true)]),
                kind: .read, environment: env, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            let afterFirst = try String(contentsOf: URL(fileURLWithPath: trajectory), encoding: .utf8)

            _ = try TrajectoryRecorder.record(command: "doctor", args: TrajectoryArgs(),
                kind: .read, environment: env, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            let afterSecond = try String(contentsOf: URL(fileURLWithPath: trajectory), encoding: .utf8)

            // The first record's bytes are a prefix of the file after the second
            // append: nothing was rewritten.
            #expect(afterSecond.hasPrefix(afterFirst))
            let records = try readRecords(trajectory)
            #expect(records.count == 2)
            #expect(records[0]["command"] as? String == "apps")
            #expect(records[1]["command"] as? String == "doctor")
        }
    }

    @Test func everyCompletedLineIsIndependentlyParseable() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let env = ["MTOUCH_TRAJECTORY": trajectory]
            for index in 0..<25 {
                _ = try TrajectoryRecorder.record(command: "cmd\(index)", args: TrajectoryArgs.build(["i": .int(index)]),
                    kind: .read, environment: env, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            }
            let records = try readRecords(trajectory)      // throws if any line is partial
            #expect(records.count == 25)
        }
    }

    @Test func concurrentWritersToOneFileNeverInterleavePartialLines() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let env = ["MTOUCH_TRAJECTORY": trajectory]
            let count = 40

            // Many parallel invocations append to the SAME file. Each record is one
            // atomic O_APPEND write, so the file stays fully parseable with exactly
            // `count` lines and no partial/interleaved line.
            DispatchQueue.concurrentPerform(iterations: count) { index in
                _ = try? TrajectoryRecorder.record(
                    command: "parallel",
                    args: TrajectoryArgs.build(["worker": .int(index), "pad": .string(String(repeating: "x", count: 64))]),
                    kind: .read, environment: env, operation: {},
                    describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            }

            let records = try readRecords(trajectory)
            #expect(records.count == count)
            let workers = Set(records.compactMap { $0["args"] as? [String: Any] }.compactMap { $0["worker"] as? Int })
            #expect(workers == Set(0..<count))    // every writer's line survived, distinct
        }
    }

    @Test func timestampsAreNonDecreasingWithinASession() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("t.jsonl").path
            let env = ["MTOUCH_TRAJECTORY": trajectory]
            for _ in 0..<5 {
                _ = try TrajectoryRecorder.record(command: "apps", args: TrajectoryArgs(),
                    kind: .read, environment: env, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            }
            let stamps = try readRecords(trajectory).compactMap { $0["timestamp"] as? Double }
            #expect(stamps.count == 5)
            #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }
}

// MARK: - MCP parity (VAL-REC-011)

@Suite struct TrajectoryMCPParityTests {
    @Test func toolResultMapsToActionDiffOnlyForTheActionKind() {
        let ok = ToolResult.text("+ e2 AXButton \"B\"")
        #expect(ok.trajectoryInfo(kind: .action).diff == "+ e2 AXButton \"B\"")
        // The same text under a non-action kind is NOT a diff (snapshot/read shapes).
        #expect(ok.trajectoryInfo(kind: .snapshot).diff == nil)
        #expect(ok.trajectoryInfo(kind: .read).diff == nil)
    }

    @Test func toolResultScreenshotReferencesPathParsedFromTheLineNeverBytes() {
        let result = ToolResult(
            payloads: [
                .text("wrote /tmp/shot.png (1920x1080 px, display \"Main\", scale 2)"),
                .image(base64: "iVBORw0KAAAA", mimeType: "image/png"),
            ],
            isError: false
        )
        let mapped = result.trajectoryInfo(kind: .screenshot)
        #expect(mapped.screenshotPath == "/tmp/shot.png")   // path, not the image bytes
        #expect(mapped.diff == nil)
    }

    @Test func toolResultDomainFailureMapsToErrorClassWithNoExit() {
        let mapped = ToolResult.text("mtouch: bad", isError: true).trajectoryInfo(kind: .action)
        #expect(mapped.ok == false)
        #expect(mapped.exit == nil)          // MCP has no exit code
        #expect(mapped.errorClass == "error")
    }

    @Test func mcpAndCliRecordsShareTheSameFieldNames() throws {
        try withTempDir { dir in
            // MCP surface: dispatchRecorded for a read tool (apps needs no AX/TCC).
            let mcpFile = dir.appendingPathComponent("mcp.jsonl").path
            _ = MCPToolDispatch.dispatchRecorded(
                tool: "apps",
                arguments: ToolArguments(["json": .bool(true)]),
                environment: ["MTOUCH_TRAJECTORY": mcpFile]
            )
            // CLI surface: the same logical read through the recorder directly.
            let cliFile = dir.appendingPathComponent("cli.jsonl").path
            _ = try TrajectoryRecorder.record(
                command: "apps", args: TrajectoryArgs.build(["json": .bool(true)]), kind: .read,
                environment: ["MTOUCH_TRAJECTORY": cliFile], operation: {},
                describe: { _ in info(ok: true, exit: 0, errorClass: nil) }
            )

            let mcp = try #require(try readRecords(mcpFile).first)
            let cli = try #require(try readRecords(cliFile).first)
            #expect(Set(mcp.keys) == Set(cli.keys))               // identical field names
            #expect(mcp["command"] as? String == "apps")
            #expect(cli["command"] as? String == "apps")
            let mcpArgs = try #require(mcp["args"] as? [String: Any])
            let cliArgs = try #require(cli["args"] as? [String: Any])
            #expect(mcpArgs["json"] as? Bool == true)
            #expect(cliArgs["json"] as? Bool == true)
        }
    }

    @Test func dispatchRecordedIsPassThroughWhenRecordingOff() {
        // Same result whether or not recording is configured (transparency).
        let off = MCPToolDispatch.dispatchRecorded(tool: "apps", arguments: ToolArguments(), environment: [:])
        let plain = MCPToolDispatch.dispatch(tool: "apps", arguments: ToolArguments(), environment: [:])
        #expect(off == plain)
    }
}

// MARK: - Path classification (VAL-REC-005)

@Suite struct TrajectoryPathTests {
    @Test func missingParentDirectoriesAreCreated() throws {
        try withTempDir { dir in
            let trajectory = dir.appendingPathComponent("a/b/c/t.jsonl").path
            let env = ["MTOUCH_TRAJECTORY": trajectory]
            _ = try TrajectoryRecorder.record(command: "apps", args: TrajectoryArgs(),
                kind: .read, environment: env, operation: {}, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            #expect(FileManager.default.fileExists(atPath: trajectory))
            #expect(try readRecords(trajectory).count == 1)
        }
    }

    @Test func aDirectoryPathAbortsBeforeRunningTheOperation() throws {
        try withTempDir { dir in
            let asDir = dir.appendingPathComponent("iam-a-dir")
            try FileManager.default.createDirectory(at: asDir, withIntermediateDirectories: true)
            let env = ["MTOUCH_TRAJECTORY": asDir.path]

            var ran = false
            #expect(throws: TrajectoryError.self) {
                _ = try TrajectoryRecorder.record(command: "apps", args: TrajectoryArgs(),
                    kind: .read, environment: env, operation: { ran = true }, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            }
            #expect(!ran)   // the operation never ran: no silent unrecorded exit 0
        }
    }

    @Test func anUnwritablePathAbortsBeforeRunningTheOperation() throws {
        // Root bypasses POSIX permission bits; the assertion only holds for a
        // non-root user.
        try #require(getuid() != 0)
        try withTempDir { dir in
            let readOnly = dir.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
            let env = ["MTOUCH_TRAJECTORY": readOnly.appendingPathComponent("t.jsonl").path]

            var ran = false
            #expect(throws: TrajectoryError.self) {
                _ = try TrajectoryRecorder.record(command: "apps", args: TrajectoryArgs(),
                    kind: .read, environment: env, operation: { ran = true }, describe: { _ in info(ok: true, exit: 0, errorClass: nil) })
            }
            #expect(!ran)
        }
    }
}
