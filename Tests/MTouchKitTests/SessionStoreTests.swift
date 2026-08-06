import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures & temp-file helpers

private func button(_ title: String) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: CGRect(x: 0, y: 0, width: 100, height: 20), actionable: true)
}

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

/// A sample snapshot with three actionable refs (e1..e3).
private func sampleSnapshot() -> Snapshot {
    Snapshot(roots: [window([button("First"), button("Second"), button("Third")])])
}

/// A fresh, unique temp directory that is removed at the end of the closure.
/// Tests write ONLY here — never the real `~/.mtouch/session.json`.
private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-session-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        // Restore write perms in case a test made it read-only, then clean up.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

// MARK: - Round-trip & resolution

@Suite struct SessionStoreRoundTripTests {
    @Test func savedSnapshotReloadsAndResolvesAKnownRef() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            try SessionStore.save(sampleSnapshot(), app: "com.example.App", pid: 4242, to: path)

            // A fresh load simulates a new process reading the file.
            let session = try #require(SessionStore.load(from: path))
            #expect(session.app == "com.example.App")
            #expect(session.pid == 4242)
            #expect(session.refs.count == 3)

            guard case let .resolved(entry) = SessionStore.resolve("e2", from: path) else {
                Issue.record("expected e2 to resolve")
                return
            }
            #expect(entry.title == "Second")
            #expect(entry.ref == "e2")
        }
    }

    @Test func absentTokenIsStaleAndNonTokenIsUnknown() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            try SessionStore.save(sampleSnapshot(), app: "app", pid: 1, to: path)

            // Well-formed but out-of-range token -> stale (act layer: exit 3).
            #expect(SessionStore.resolve("e999", from: path) == .stale)
            // A leading-zero form is still a token (a plausible typo of a real
            // ref): absent -> stale (exit 3), NOT unknown.
            #expect(SessionStore.resolve("e01", from: path) == .stale)
            // Not a ref token at all -> unknown (act layer: exit 64).
            #expect(SessionStore.resolve("banana", from: path) == .unknown)
            #expect(SessionStore.resolve("e0", from: path) == .unknown)
            #expect(SessionStore.resolve("e", from: path) == .unknown)
            #expect(SessionStore.resolve("e1x", from: path) == .unknown)
        }
    }

    @Test func resolvingAgainstNoFileIsNoSession() throws {
        try withTempDir { dir in
            let missing = dir.appendingPathComponent("does-not-exist.json").path
            #expect(SessionStore.load(from: missing) == nil)
            #expect(SessionStore.resolve("e1", from: missing) == .noSession)
        }
    }

    @Test func persistedFileNeverContainsANodeValue() throws {
        // Defence-in-depth: session-store is where refs hit disk. A secure field's
        // value (a possible secret) must not appear in the persisted bytes.
        let secret = "hunter2-topsecret"
        let field = AXNode(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole,
                           title: "Password", value: secret,
                           frame: CGRect(x: 0, y: 0, width: 100, height: 20), actionable: true)
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            try SessionStore.save(Snapshot(roots: [window([field])]), app: "app", pid: 1, to: path)
            let bytes = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            #expect(!bytes.contains(secret))
        }
    }
}

// MARK: - Owning-window CGWindowID (VAL-ACT-011 round 2)

@Suite struct RefEntryOwnerWindowIDTests {
    /// `Snapshot(roots:windowIDsByPath:)` stamps each ref with the CGWindowID of its
    /// OWNING top-level window (looked up by the path's root prefix), so a ref built
    /// from a handle-bearing walk records the authoritative window identity.
    @Test func snapshotStampsEachRefWithItsOwningWindowID() {
        let roots = [
            window([button("A")]),   // root 0 -> window id 7001
            window([button("B")]),   // root 1 -> window id 7002
        ]
        // A LiveElementTree-shaped map: window id present at the root AND propagated
        // to descendants; the init only needs the root prefix.
        let ids: [[Int]: CGWindowID] = [
            [0]: 7001, [0, 0]: 7001,
            [1]: 7002, [1, 0]: 7002,
        ]
        let snapshot = Snapshot(roots: roots, windowIDsByPath: ids)
        #expect(snapshot.refs["e1"]?.ownerWindowID == 7001)  // button A, window 0
        #expect(snapshot.refs["e2"]?.ownerWindowID == 7002)  // button B, window 1
    }

    /// A handle-free build (no window-id map) leaves `ownerWindowID` nil, so text
    /// rendering and any pre-window-id caller keep working unchanged.
    @Test func handleFreeSnapshotLeavesOwnerWindowIDNil() {
        let snapshot = Snapshot(roots: [window([button("A")])])
        #expect(snapshot.refs["e1"]?.ownerWindowID == nil)
    }

    /// The window id survives a persist/reload round-trip; being a window handle
    /// NUMBER (not element content), it is safe to write and keeps `RefEntry`
    /// value-free.
    @Test func ownerWindowIDRoundTripsThroughTheSession() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            let ids: [[Int]: CGWindowID] = [[0]: 9099, [0, 0]: 9099]
            let snapshot = Snapshot(roots: [window([button("A")])], windowIDsByPath: ids)
            try SessionStore.save(snapshot, app: "app", pid: 1, to: path)

            let reloaded = try #require(SessionStore.load(from: path))
            guard case let .resolved(entry) = reloaded.resolve("e1") else {
                Issue.record("expected e1 to resolve"); return
            }
            #expect(entry.ownerWindowID == 9099)
        }
    }

    /// An older session written before the window-id field existed decodes with a
    /// nil `ownerWindowID` (tolerant decode) rather than failing to load.
    @Test func sessionWithoutOwnerWindowIDDecodesAsNil() throws {
        let json = """
        {"ref":"e1","role":"AXButton","path":[0,0]}
        """
        let entry = try JSONDecoder().decode(RefEntry.self, from: Data(json.utf8))
        #expect(entry.ownerWindowID == nil)
        #expect(entry.ancestors.isEmpty)
    }
}

// MARK: - Corruption

@Suite struct SessionStoreCorruptionTests {
    @Test func mismatchedVersionLoadsAsNilThenSaveRewritesCleanly() throws {
        // A future v2 file must read as absent to a v1 binary rather than being
        // mis-decoded. The version gate folds this into the corrupt-as-absent path.
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            let future = Session(version: Session.currentVersion + 1, app: "app", pid: 1, digest: "deadbeef", refs: [:])
            try JSONEncoder().encode(future).write(to: URL(fileURLWithPath: path))

            #expect(SessionStore.load(from: path) == nil)          // treated as absent
            #expect(SessionStore.resolve("e1", from: path) == .noSession)

            // A subsequent save heals the file at the current version.
            try SessionStore.save(sampleSnapshot(), app: "app", pid: 7, to: path)
            let session = try #require(SessionStore.load(from: path))
            #expect(session.version == Session.currentVersion)
            #expect(session.refs.count == 3)
        }
    }

    @Test func corruptFileLoadsAsNilThenSaveRewritesCleanly() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path

            // Garbage bytes where a session file is expected.
            try Data("}{ this is not json ".utf8).write(to: URL(fileURLWithPath: path))
            #expect(SessionStore.load(from: path) == nil)          // treated as absent
            #expect(SessionStore.resolve("e1", from: path) == .noSession)

            // A subsequent save heals the file.
            try SessionStore.save(sampleSnapshot(), app: "app", pid: 7, to: path)
            let session = try #require(SessionStore.load(from: path))
            #expect(session.refs.count == 3)
            #expect(SessionStore.resolve("e1", from: path) != .noSession)
        }
    }
}

// MARK: - Failure surfacing

@Suite struct SessionStoreFailureTests {
    @Test func savingToADirectoryThrowsNamingThePath() throws {
        try withTempDir { dir in
            let asDir = dir.appendingPathComponent("iam-a-directory")
            try FileManager.default.createDirectory(at: asDir, withIntermediateDirectories: true)

            #expect(throws: SessionStoreError.self) {
                try SessionStore.save(sampleSnapshot(), app: "app", pid: 1, to: asDir.path)
            }
            do {
                try SessionStore.save(sampleSnapshot(), app: "app", pid: 1, to: asDir.path)
            } catch let error as SessionStoreError {
                #expect("\(error)".contains(asDir.path))   // the message names the path
            }
        }
    }

    @Test func savingUnderAReadOnlyDirectoryThrowsNamingThePath() throws {
        // Root bypasses POSIX permission bits, so this assertion only holds for a
        // non-root user; skip cleanly otherwise.
        try #require(getuid() != 0)
        try withTempDir { dir in
            let readOnly = dir.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)

            let path = readOnly.appendingPathComponent("session.json").path
            do {
                try SessionStore.save(sampleSnapshot(), app: "app", pid: 1, to: path)
                Issue.record("expected save to throw under a read-only directory")
            } catch let error as SessionStoreError {
                #expect("\(error)".contains(path))
            }
        }
    }
}

// MARK: - Atomicity / concurrent distinct paths

@Suite struct SessionStoreAtomicityTests {
    @Test func twoSavesToDistinctPathsDoNotCrossContaminate() throws {
        try withTempDir { dir in
            let pathA = dir.appendingPathComponent("a.json").path
            let pathB = dir.appendingPathComponent("b.json").path

            let a = Snapshot(roots: [window([button("Alpha")])])
            let b = Snapshot(roots: [window([button("Bravo"), button("Bravo2")])])

            try SessionStore.save(a, app: "com.a", pid: 11, to: pathA)
            try SessionStore.save(b, app: "com.b", pid: 22, to: pathB)

            let loadedA = try #require(SessionStore.load(from: pathA))
            let loadedB = try #require(SessionStore.load(from: pathB))

            #expect(loadedA.app == "com.a")
            #expect(loadedA.pid == 11)
            #expect(loadedA.refs.count == 1)
            #expect(loadedA.refs["e1"]?.title == "Alpha")

            #expect(loadedB.app == "com.b")
            #expect(loadedB.pid == 22)
            #expect(loadedB.refs.count == 2)
            #expect(loadedB.refs["e1"]?.title == "Bravo")
        }
    }

    @Test func saveLeavesNoTempFilesBehindAndResultParsesFully() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            try SessionStore.save(sampleSnapshot(), app: "app", pid: 1, to: path)

            // No leftover temp artifacts from the write-then-rename dance.
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(entries == ["session.json"])

            // The persisted bytes are complete, parseable JSON.
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
        }
    }

    @Test func overwritingAnExistingSessionReplacesItCleanly() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("session.json").path
            try SessionStore.save(Snapshot(roots: [window([button("Old")])]), app: "old", pid: 1, to: path)
            try SessionStore.save(sampleSnapshot(), app: "new", pid: 2, to: path)

            let session = try #require(SessionStore.load(from: path))
            #expect(session.app == "new")
            #expect(session.refs.count == 3)
            #expect(session.refs["e1"]?.title == "First")
        }
    }
}

// MARK: - Path resolution

@Suite struct SessionFilePathTests {
    @Test func envOverrideIsUsedVerbatim() {
        let path = SessionStore.sessionFilePath(environment: [MTouchEnvironment.sessionKey: "/tmp/custom/s.json"])
        #expect(path == "/tmp/custom/s.json")
    }

    @Test func defaultIsHomeDotMtouchSessionJson() {
        let path = SessionStore.sessionFilePath(environment: ["HOME": "/Users/tester"])
        #expect(path == "/Users/tester/.mtouch/session.json")
    }

    @Test func emptyOverrideFallsBackToDefault() {
        let path = SessionStore.sessionFilePath(environment: [
            MTouchEnvironment.sessionKey: "",
            "HOME": "/Users/tester",
        ])
        #expect(path == "/Users/tester/.mtouch/session.json")
    }

    @Test func overrideTakesPrecedenceOverHome() {
        let path = SessionStore.sessionFilePath(environment: [
            MTouchEnvironment.sessionKey: "/var/isolated.json",
            "HOME": "/Users/tester",
        ])
        #expect(path == "/var/isolated.json")
    }
}
