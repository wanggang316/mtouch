import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

/// A REAL 1010-byte MP4: four 16x16 H.264 frames at 10 fps, 0.4 s long, one
/// video track. Embedded as base64 rather than generated at test time so the
/// suite needs no encoder, no display, and no capture — it is the "valid movie"
/// end of the verifier's classification, checked with the LIVE container probe.
private let tinyMovieBase64 = """
AAAAHGZ0eXBtcDQyAAAAAWlzb21tcDQxbXA0MgAAAAFtZGF0AAAAAAAAANgAAAA6BgUyR1ZK3FxMQz+U78URPNFDqAEAAAMA
AQMAAAMAAQIAAeYACwAAAwAAAwAAB2IMA4kkAQ3/////gAAAADIluCAf3gjlTP+CzB6bUkQAUXvbWI96Chke5rmDp9W2soHz
YayoY2+o56cAADaAFcM9GAAAABch4Qxf/vc/H/9hi8dQASDAN42V8dGwwAAAABohqIKEv/aXwlUn//F/6aBdAAfrqTEmvm4R
wAAAABcBqMGP//2o7WfYjOAPWACjc2OQfgnfyAAAAv5tb292AAAAbG12aGQAAAAA5rXO+ua1zvoAAAJYAAAA8AABAAABAAAA
AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC
AAACinRyYWsAAABcdGtoZAAAAAHmtc765rXO+gAAAAEAAAAAAAAA8AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAA
AAEAAAAAAAAAAAAAAAAAAEAAAAAAEAAAABAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAPAAAAB4AAEAAAAAAgJtZGlh
AAAAIG1kaGQAAAAA5rXO+ua1zvoAAAJYAAAA8FXEAAAAAAAxaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAENvcmUgTWVk
aWEgVmlkZW8AAAABqW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAA
AQAAAWlzdGJsAAAAoXN0c2QAAAAAAAAAAQAAAJFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAA
AAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAJ2F2Y0MBZAAL/+EADCdkAAusVlDDeBZgpQEABCju
PLD9+PgAAAAACmZpZWwBAAAAAApjaHJtAAAAAAAYc3R0cwAAAAAAAAABAAAABAAAADwAAAAwY3R0cwAAAAAAAAAEAAAAAQAA
AHgAAAABAAAA8AAAAAEAAAB4AAAAAQAAAAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABBzZHRwAAAAACAQEBgAAAAcc3RzYwAA
AAAAAAABAAAAAQAAAAQAAAABAAAAJHN0c3oAAAAAAAAAAAAAAAQAAAB0AAAAGwAAAB4AAAAbAAAAFHN0Y28AAAAAAAAAAQAA
ACw=
"""

/// Whether to run the tests that exercise the REAL media-container integration.
///
/// A headless CI runner has no decoder, so loading a valid H.264 movie there
/// hangs until the verifier's own deadline and returns `.unreadable`. That does
/// not merely break the positive case — it quietly HOLLOWS OUT the negative
/// ones: "not a movie" and "truncated movie" both assert a refusal, and a
/// blanket timeout refuses everything, so they keep passing while asserting
/// nothing at all.
///
/// Detecting this by probing the host was tried and is NOT reliable: on the
/// runner the first container read returns quickly and a later identical read
/// hangs, so the probe reports "can decode" and the test then times out anyway.
/// A flaky gate is worse than an honest one, so key on the environment instead.
/// These three run on any developer machine and in the live recording check;
/// they are skipped on CI, which is recorded as an environment-blocked gap
/// rather than papered over. The verifier's classification logic stays covered
/// everywhere through its `probe:` seam.
private let mediaContainerIntegrationEnabled =
    ProcessInfo.processInfo.environment["CI"] == nil

private func tinyMovieData() -> Data {
    Data(base64Encoded: tinyMovieBase64, options: .ignoreUnknownCharacters) ?? Data()
}

private func writeTinyMovie(_ url: URL) throws {
    try tinyMovieData().write(to: url)
}

/// A container probe that answers without touching a file, for the two verdicts
/// no small real file can produce on demand.
private func stubProbe(
    duration: Double,
    tracks: Int
) -> (String) -> Result<RecordMovieProbe, RecordFailure> {
    { _ in .success(RecordMovieProbe(durationSeconds: duration, videoTrackCount: tracks)) }
}

// MARK: - Classification against real files

@Suite struct RecordArtifactVerificationTests {
    @Test func aFileThatWasNeverWrittenIsNotARecording() throws {
        try withRecordTempDir { dir in
            let path = dir.appendingPathComponent("absent.mp4").path
            #expect(RecordArtifact.verify(path: path) == .missing(path: path))
        }
    }

    /// The recorder creates its output before it has anything to put in it. A
    /// zero-byte file is the shape a capture that never produced a frame leaves
    /// behind, and it must never be reported as a recording.
    @Test func aZeroByteFileIsRefused() throws {
        try withRecordTempDir { dir in
            let url = dir.appendingPathComponent("empty.mp4")
            try Data().write(to: url)
            #expect(RecordArtifact.verify(path: url.path) == .empty(path: url.path))
        }
    }

    /// Bytes that are not a movie — which is also what a SIGKILLed recorder
    /// leaves, an mdat with no finalized moov — are refused with the parser's
    /// own reason.
    @Test(.enabled(if: mediaContainerIntegrationEnabled)) func bytesThatAreNotAMovieAreRefusedWithAReason() throws {
        try withRecordTempDir { dir in
            let url = dir.appendingPathComponent("notamovie.mp4")
            try Data("this is plainly not a movie container".utf8).write(to: url)
            let verdict = RecordArtifact.verify(path: url.path)
            guard case let .unreadable(path, reason) = verdict else {
                Issue.record("expected an unreadable verdict, got \(verdict)")
                return
            }
            #expect(path == url.path)
            #expect(!reason.isEmpty)
            #expect(verdict.diagnostic.contains(url.path))
            #expect(verdict.diagnostic.contains("unfinalized"))
        }
    }

    /// A TRUNCATED movie — the first half of a valid file — must fail too. This
    /// is the case that makes a killed recorder detectable at all.
    @Test(.enabled(if: mediaContainerIntegrationEnabled)) func aTruncatedMovieIsRefused() throws {
        try withRecordTempDir { dir in
            let whole = tinyMovieData()
            let url = dir.appendingPathComponent("truncated.mp4")
            try whole.prefix(whole.count / 2).write(to: url)
            #expect(!RecordArtifact.verify(path: url.path).isVerified)
        }
    }

    @Test(.enabled(if: mediaContainerIntegrationEnabled)) func aRealMovieIsVerifiedWithItsBytesDurationAndTrackCount() throws {
        try withRecordTempDir { dir in
            let url = dir.appendingPathComponent("good.mp4")
            try writeTinyMovie(url)
            let verdict = RecordArtifact.verify(path: url.path)
            let facts = try #require(verdict.facts)
            #expect(verdict.isVerified)
            #expect(facts.byteCount == 1010)
            #expect(facts.videoTrackCount == 1)
            #expect(facts.durationSeconds > 0)
            #expect(facts.durationSeconds < 5)
        }
    }

    /// A directory is "no recording here", not a zero-byte one.
    @Test func aDirectoryAtTheOutputPathIsMissingNotEmpty() throws {
        try withRecordTempDir { dir in
            let path = dir.appendingPathComponent("adirectory.mp4").path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            #expect(RecordArtifact.verify(path: path) == .missing(path: path))
        }
    }
}

// MARK: - Classification of readable containers

@Suite struct RecordArtifactContainerTests {
    @Test func aContainerWithoutAVideoTrackIsRefused() throws {
        try withRecordTempDir { dir in
            let url = dir.appendingPathComponent("audioonly.mp4")
            try Data("some bytes".utf8).write(to: url)
            let verdict = RecordArtifact.verify(path: url.path, probe: stubProbe(duration: 12, tracks: 0))
            #expect(verdict == .noVideoTrack(path: url.path))
            #expect(verdict.diagnostic.contains("no video track"))
        }
    }

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func aContainerWithoutAUsableDurationIsRefused(_ duration: Double) throws {
        try withRecordTempDir { dir in
            let url = dir.appendingPathComponent("noduration.mp4")
            try Data("some bytes".utf8).write(to: url)
            let verdict = RecordArtifact.verify(path: url.path, probe: stubProbe(duration: duration, tracks: 1))
            #expect(verdict == .zeroDuration(path: url.path))
        }
    }

    @Test func theBytesComeFromTheFilesystemNotTheContainer() throws {
        try withRecordTempDir { dir in
            let url = dir.appendingPathComponent("sized.mp4")
            try Data(repeating: 0x41, count: 4096).write(to: url)
            let verdict = RecordArtifact.verify(path: url.path, probe: stubProbe(duration: 9.5, tracks: 2))
            let facts = try #require(verdict.facts)
            #expect(facts.byteCount == 4096)
            #expect(facts.durationSeconds == 9.5)
            #expect(facts.videoTrackCount == 2)
        }
    }

    @Test func theHumanSummaryNamesBytesDurationAndTracks() {
        let one = RecordArtifactVerdict.factsText(
            RecordMovieFacts(byteCount: 2048, durationSeconds: 12.3456, videoTrackCount: 1)
        )
        #expect(one == "2048 bytes, 12.346 s, 1 video track")
        let many = RecordArtifactVerdict.factsText(
            RecordMovieFacts(byteCount: 10, durationSeconds: 4, videoTrackCount: 2)
        )
        #expect(many == "10 bytes, 4 s, 2 video tracks")
    }

    @Test func everyRefusalNamesTheOffendingFile() {
        let path = "/runs/demo/video/capture.mp4"
        let verdicts: [RecordArtifactVerdict] = [
            .missing(path: path),
            .empty(path: path),
            .unreadable(path: path, reason: "no moov atom"),
            .noVideoTrack(path: path),
            .zeroDuration(path: path),
        ]
        for verdict in verdicts {
            #expect(!verdict.isVerified)
            #expect(verdict.facts == nil)
            #expect(verdict.diagnostic.hasPrefix("mtouch: "))
            #expect(verdict.diagnostic.contains(path))
        }
    }
}

// MARK: - The byte-count seam

@Suite struct RecordArtifactByteCountTests {
    @Test func aRegularFileReportsItsSize() throws {
        try withRecordTempDir { dir in
            let url = dir.appendingPathComponent("bytes.bin")
            try Data(repeating: 7, count: 333).write(to: url)
            #expect(RecordArtifact.fileByteCount(url.path) == 333)
        }
    }

    @Test func anAbsentPathAndADirectoryBothReportNothing() throws {
        try withRecordTempDir { dir in
            #expect(RecordArtifact.fileByteCount(dir.appendingPathComponent("nope").path) == nil)
            #expect(RecordArtifact.fileByteCount(dir.path) == nil)
        }
    }
}

// MARK: - The destination preflight

/// ScreenCaptureKit announces that recording STARTED before its writer has
/// touched the file, so a doomed destination would otherwise be discovered only
/// on the first sample — long after `record start` had already reported success.
/// These pin the refusals that happen BEFORE any capture.
@Suite struct RecordDestinationPreflightTests {
    @Test func awritableDestinationIsAcceptedAndLeavesNoProbeBehind() throws {
        try withRecordTempDir { dir in
            let path = dir.appendingPathComponent("fine.mp4").path
            guard case .success = LiveScreenRecorder.prepareDestination(path) else {
                Issue.record("expected a writable path to be accepted")
                return
            }
            // The probe must not leave a zero-byte file where the recorder is
            // about to create its own.
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func missingParentDirectoriesAreCreated() throws {
        try withRecordTempDir { dir in
            let path = dir.appendingPathComponent("a/b/c/deep.mp4").path
            guard case .success = LiveScreenRecorder.prepareDestination(path) else {
                Issue.record("expected missing parents to be created")
                return
            }
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a/b/c").path))
        }
    }

    /// `--out` overwrites, matching `screenshot`. The existing file is cleared so
    /// the writer starts from nothing rather than appending to a stranger.
    @Test func anExistingFileIsClearedSoTheWriterStartsFromNothing() throws {
        try withRecordTempDir { dir in
            let path = dir.appendingPathComponent("old.mp4").path
            try Data(repeating: 1, count: 999).write(to: URL(fileURLWithPath: path))
            guard case .success = LiveScreenRecorder.prepareDestination(path) else {
                Issue.record("expected an existing file to be replaceable")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func aDirectoryAtTheDestinationIsRefusedByName() throws {
        try withRecordTempDir { dir in
            let path = dir.appendingPathComponent("adirectory.mp4").path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            guard case let .failure(failure) = LiveScreenRecorder.prepareDestination(path) else {
                Issue.record("expected a directory to be refused")
                return
            }
            #expect(failure.reason.contains("path is a directory"))
            #expect(failure.reason.contains(path))
        }
    }

    @Test func anUnwritableParentIsRefusedByName() throws {
        // Root ignores the permission bits, so the refusal is unobservable there.
        try #require(getuid() != 0)
        try withRecordTempDir { dir in
            let locked = dir.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            let path = locked.appendingPathComponent("nope.mp4").path
            guard case let .failure(failure) = LiveScreenRecorder.prepareDestination(path) else {
                Issue.record("expected an unwritable parent to be refused")
                return
            }
            #expect(failure.reason.contains(path))
            #expect(failure.reason.hasPrefix("mtouch: "))
        }
    }
}
