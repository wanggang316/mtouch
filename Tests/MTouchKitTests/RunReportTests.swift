import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures & helpers

private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtouch-run-report-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

/// Build a bundle on disk by hand, so a test pins exactly the shape it is about
/// (rather than depending on the recorder to produce it).
private struct BundleBuilder {
    let root: String

    init(root: String, label: String? = "demo run", metadata: Bool = true) throws {
        self.root = root
        try FileManager.default.createDirectory(
            atPath: RunBundle(root: root).stepsDirectory, withIntermediateDirectories: true
        )
        if metadata {
            let facts = RunMetadata(
                createdAtWallClock: 1_700_000_000, createdAtMonotonic: 100,
                mtouchVersion: "9.9.9", macOSVersion: "15.5.0", label: label, stepCount: 2
            )
            try Data(facts.jsonText().utf8)
                .write(to: URL(fileURLWithPath: RunBundle(root: root).metadataPath))
        }
    }

    func writeTrajectory(_ lines: [String]) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8)
            .write(to: URL(fileURLWithPath: RunBundle(root: root).trajectoryPath))
    }

    func writeStepImage(_ relative: String, bytes: String = "fake-png") throws {
        try Data(bytes.utf8).write(to: URL(fileURLWithPath: RunBundle(root: root).absolutePath(forRelative: relative)))
    }

    func writeVideo(_ name: String) throws {
        let directory = RunBundle(root: root).videoDirectory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data("fake-video".utf8)
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}

/// A record line in exactly the shape `TrajectoryRecord.jsonLine` writes.
private func line(
    command: String,
    step: Int? = nil,
    args: String = "{}",
    ok: Bool = true,
    exit: Int = 0,
    errorClass: String? = nil,
    wallClock: Double = 1_700_000_001,
    timestamp: Double = 101,
    diff: String? = nil,
    evidence: String? = nil
) -> String {
    var fields = [
        "\"command\":\(JSONText.string(command))",
        "\"timestamp\":\(JSONText.number(timestamp))",
        "\"wallClock\":\(JSONText.number(wallClock))",
        "\"args\":\(args)",
        "\"outcome\":{\"ok\":\(ok),\"exit\":\(exit),"
            + "\"errorClass\":\(errorClass.map(JSONText.string) ?? "null")}",
    ]
    if let diff { fields.append("\"diff\":\(JSONText.string(diff))") }
    if let step { fields.append("\"step\":\(step)") }
    if let evidence { fields.append("\"evidence\":\(evidence)") }
    return "{" + fields.joined(separator: ",") + "}"
}

private func render(_ root: String, redact: Bool = false) -> String {
    RunReportHTML.render(RunReportLoader.load(runDirectory: root), redact: redact)
}

// MARK: - A full bundle

@Suite struct RunReportFullBundleTests {
    @Test func theTimelineCarriesEveryFactAStepRecorded() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([
                line(
                    command: "act", step: 1,
                    args: "{\"ref\":\"e4\",\"verb\":\"press\"}",
                    wallClock: 1_700_000_002, timestamp: 102,
                    diff: "+ e5 AXButton \"Save\"",
                    evidence: "{\"after\":\"steps/0001-act-after.png\",\"before\":\"steps/0001-act-before.png\"}"
                ),
                line(
                    command: "read", step: 2, args: "{\"ref\":\"e5\"}",
                    ok: false, exit: 3, errorClass: "ref", wallClock: 1_700_000_006, timestamp: 106
                ),
            ])
            try builder.writeStepImage("steps/0001-act-before.png", bytes: "BEFORE-BYTES")
            try builder.writeStepImage("steps/0001-act-after.png", bytes: "AFTER-BYTES")

            let html = render(root)
            #expect(html.hasPrefix("<!DOCTYPE html>"))
            // Commands, ordinals, arguments, outcome, exit code, error class, diff.
            #expect(html.contains(">0001<"))
            #expect(html.contains(">0002<"))
            #expect(html.contains(">act<"))
            #expect(html.contains(">read<"))
            #expect(html.contains("<th>verb</th><td>press</td>"))
            #expect(html.contains("<th>ref</th><td>e4</td>"))
            #expect(html.contains("exit 3"))
            #expect(html.contains(">ref<"))
            #expect(html.contains("+ e5 AXButton &quot;Save&quot;"))
            // Both clocks, on every step.
            #expect(html.contains("2023-11-14 22:13:22.000 UTC"))
            #expect(html.contains(">102 s<"))
            // Header summary: label, duration, counts, pass/fail tally.
            #expect(html.contains("demo run"))
            #expect(html.contains("9.9.9"))
            #expect(html.contains("15.5.0"))
            #expect(html.contains("6.000 s"))               // created 1700000000 → last record 1700000006
            #expect(html.contains("1 passed"))
            #expect(html.contains("1 failed"))
            // Screenshots inline as data URIs, in before/after order.
            let before = Data("BEFORE-BYTES".utf8).base64EncodedString()
            let after = Data("AFTER-BYTES".utf8).base64EncodedString()
            #expect(html.contains("data:image/png;base64,\(before)"))
            #expect(html.contains("data:image/png;base64,\(after)"))
            let beforeIndex = try #require(html.range(of: before))
            let afterIndex = try #require(html.range(of: after))
            #expect(beforeIndex.lowerBound < afterIndex.lowerBound)
        }
    }

    @Test func thePageIsSelfContainedAndReachesNoNetwork() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([
                line(command: "act", step: 1, evidence: "{\"before\":\"steps/0001-act-before.png\"}"),
            ])
            try builder.writeStepImage("steps/0001-act-before.png")

            let html = render(root)
            #expect(html.contains("<style>"))               // CSS inlined, never linked
            #expect(!html.contains("<link"))
            #expect(!html.contains("http://"))
            #expect(!html.contains("https://"))
            #expect(!html.contains("//fonts."))
            #expect(!html.contains("@import"))
            // The only `src` on an image is a data URI.
            #expect(html.contains("<img alt=\"before screenshot\" src=\"data:image/png;base64,"))
            #expect(!html.contains("<img src=\"steps/"))
        }
    }

    @Test func theSensitiveContentBannerNamesBothHazards() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([line(command: "act", step: 1)])

            let html = render(root)
            #expect(html.contains("Sensitive content"))
            #expect(html.contains("whatever was on screen"))
            // The subtler hazard: redaction only covers FAILED records, so a
            // successful type is in the log verbatim.
            #expect(html.contains("<code>text</code>"))
            #expect(html.contains("<code>combo</code>"))
            #expect(html.contains("<code>value</code>"))
            #expect(html.contains("failed</strong> records"))
            #expect(html.contains("act type &lt;secret&gt;"))
            #expect(html.contains("--redact"))
        }
    }
}

// MARK: - Graceful degradation

@Suite struct RunReportDegradationTests {
    @Test func anAbsentVideoDirectoryIsStatedNotFaked() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([line(command: "act", step: 1)])

            let html = render(root)
            #expect(html.contains("Screen recording"))
            #expect(html.contains("No screen recording in this run"))
            #expect(!html.contains("<video"))
        }
    }

    @Test func aPresentRecordingGetsAnEmbedSlot() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([line(command: "act", step: 1)])
            try builder.writeVideo("run.mp4")

            let html = render(root)
            #expect(html.contains("<video controls preload=\"none\" src=\"video/run.mp4\">"))
            #expect(!html.contains("No screen recording in this run"))
        }
    }

    @Test func aStepWhoseImageIsGoneSaysSoRatherThanRenderingABrokenImage() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([
                line(command: "act", step: 1, evidence: "{\"before\":\"steps/0001-act-before.png\"}"),
            ])
            // The record names an image that was never written (or was deleted).
            let html = render(root)
            #expect(html.contains("before screenshot missing"))
            #expect(html.contains("steps/0001-act-before.png"))
            #expect(!html.contains("data:image/png;base64,"))
        }
    }

    @Test func anEvidencePathPointingOutsideTheBundleIsNeverInlined() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            let outside = dir.appendingPathComponent("secret.txt")
            try Data("TOP-SECRET".utf8).write(to: outside)
            try builder.writeTrajectory([
                line(command: "act", step: 1, evidence: "{\"before\":\"../secret.txt\"}"),
            ])

            let html = render(root)
            #expect(!html.contains(Data("TOP-SECRET".utf8).base64EncodedString()))
            #expect(html.contains("before screenshot missing"))
        }
    }

    @Test func aRunWithoutCapturesSaysCapturesWereOff() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([line(command: "act", step: 1)])
            #expect(render(root).contains("No screenshots for this step"))
        }
    }

    @Test func aCaptureFailureIsShownOnTheStepItAffected() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([
                line(
                    command: "act", step: 1,
                    evidence: "{\"captureError\":\"before: Screen Recording is not granted\"}"
                ),
            ])
            let html = render(root)
            #expect(html.contains("capture failed"))
            #expect(html.contains("Screen Recording is not granted"))
            #expect(html.contains("kept its own exit code"))
        }
    }

    @Test func anEmptyTrajectoryStillRenders() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([])

            let html = render(root)
            #expect(html.hasPrefix("<!DOCTYPE html>"))
            #expect(html.hasSuffix("</html>\n"))
            #expect(html.contains("is empty — this run recorded no commands"))
            #expect(html.contains("0 passed"))
        }
    }

    @Test func anAbsentTrajectoryPointsAtTheExplicitOverrideThatWouldExplainIt() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            _ = try BundleBuilder(root: root)

            let html = render(root)
            #expect(html.hasPrefix("<!DOCTYPE html>"))
            #expect(html.contains("is absent"))
            #expect(html.contains("MTOUCH_TRAJECTORY"))
        }
    }

    @Test func aMalformedLineIsSurfacedInPlaceAndTheRestStillRenders() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([
                line(command: "apps", step: 1),
                "{\"command\":\"act\",\"truncated",             // a torn line from a crash
                line(command: "read", step: 3),
            ])

            let html = render(root)
            #expect(html.contains("unreadable line 2"))
            #expect(html.contains("&quot;truncated"))            // the raw text, escaped
            #expect(html.contains(">apps<"))                     // the good records survive
            #expect(html.contains(">read<"))
            #expect(html.contains("unreadable lines"))           // and the header counts it
        }
    }

    @Test func anAbsentRunJsonStillRenders() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root, metadata: false)
            try builder.writeTrajectory([line(command: "act", step: 1)])

            let html = render(root)
            #expect(html.contains("absent or unreadable"))
            #expect(html.contains(">act<"))
        }
    }

    @Test func aRunawayUnreadableLineIsCappedAndTheCutIsMarked() {
        let long = String(repeating: "x", count: 900)
        let capped = RunReportHTML.truncate(long)
        #expect(capped.hasPrefix(String(repeating: "x", count: 500)))
        #expect(capped.hasSuffix("… (400 more characters)"))
        #expect(RunReportHTML.truncate("short") == "short")
    }
}

// MARK: - Redaction

@Suite struct RunReportRedactionTests {
    @Test func redactDropsScreenshotsAndVideoButKeepsTheStructuredLog() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([
                line(
                    command: "act", step: 1, args: "{\"text\":\"hunter2\",\"verb\":\"type\"}",
                    diff: "+ e5 AXButton \"Save\"",
                    evidence: "{\"after\":\"steps/0001-act-after.png\",\"before\":\"steps/0001-act-before.png\"}"
                ),
            ])
            try builder.writeStepImage("steps/0001-act-before.png", bytes: "BEFORE-BYTES")
            try builder.writeStepImage("steps/0001-act-after.png", bytes: "AFTER-BYTES")
            try builder.writeVideo("run.mp4")

            let html = render(root, redact: true)
            #expect(!html.contains("data:image/png;base64,"))
            #expect(!html.contains(Data("BEFORE-BYTES".utf8).base64EncodedString()))
            #expect(!html.contains("<video"))
            #expect(!html.contains("<img"))
            #expect(html.contains("Redacted"))
            #expect(!html.contains("Sensitive content"))
            // The log itself is untouched — that is the point of the flag.
            #expect(html.contains("<th>verb</th><td>type</td>"))
            #expect(html.contains("<th>text</th><td>hunter2</td>"))
            #expect(html.contains("+ e5 AXButton &quot;Save&quot;"))
        }
    }
}

// MARK: - HTML escaping

@Suite struct RunReportEscapingTests {
    @Test func hostileAccessibilityStringsAreEscapedNotInjected() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            let hostile = "<script>alert('x')</script> & \"quoted\" 日本語 🎉 </li></ol>"
            try builder.writeTrajectory([
                line(
                    command: "act", step: 1,
                    args: "{\"value\":\(JSONText.string(hostile))}",
                    diff: hostile
                ),
            ])

            let html = render(root)
            // No live markup from target-supplied text.
            #expect(!html.contains("<script>"))
            #expect(!html.contains("</script>"))
            #expect(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))
            #expect(html.contains("&amp;"))
            #expect(html.contains("&quot;quoted&quot;"))
            // Unicode is NOT mangled: it survives verbatim under the UTF-8 charset.
            #expect(html.contains("日本語 🎉"))
            // The document still closes properly despite the injected end tags.
            #expect(html.hasSuffix("</html>\n"))
        }
    }

    @Test func escapeCoversTheFiveMarkupCharactersAndRefusesRawControlBytes() {
        #expect(RunReportHTML.escape("a<b>c&d\"e'f") == "a&lt;b&gt;c&amp;d&quot;e&#39;f")
        // Newline and tab are meaningful inside a <pre> and survive; other control
        // characters cannot be represented in HTML at all and become U+FFFD.
        #expect(RunReportHTML.escape("a\nb\tc") == "a\nb\tc")
        #expect(RunReportHTML.escape("a\u{0}b\u{7}c\u{1B}d") == "a\u{FFFD}b\u{FFFD}c\u{FFFD}d")
        #expect(RunReportHTML.escape("日本語 🎉 café") == "日本語 🎉 café")
    }

    @Test func aHostileLabelOrPathCannotEscapeTheHeader() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root, label: "</dd><script>bad()</script>")
            try builder.writeTrajectory([line(command: "act", step: 1)])

            let html = render(root)
            #expect(!html.contains("<script>bad()"))
            #expect(html.contains("&lt;/dd&gt;&lt;script&gt;bad()&lt;/script&gt;"))
        }
    }
}

// MARK: - Determinism

@Suite struct RunReportDeterminismTests {
    @Test func twoRendersOfOneBundleAreByteIdentical() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([
                line(
                    command: "act", step: 1,
                    args: "{\"ref\":\"e1\",\"verb\":\"press\"}",
                    evidence: "{\"after\":\"steps/0001-act-after.png\",\"before\":\"steps/0001-act-before.png\"}"
                ),
                line(command: "read", step: 2, ok: false, exit: 3, errorClass: "ref"),
            ])
            try builder.writeStepImage("steps/0001-act-before.png")
            try builder.writeStepImage("steps/0001-act-after.png")
            try builder.writeVideo("run.mp4")

            let first = render(root)
            let second = render(root)
            #expect(first == second)
            #expect(Data(first.utf8) == Data(second.utf8))
            // Nothing render-time leaked into the body.
            #expect(!first.lowercased().contains("generated at"))
            #expect(!first.contains(RunReportHTML.utcText(Date().timeIntervalSince1970)))
        }
    }

    @Test func writingTheReportTwiceProducesTheSameBytesOnDisk() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([line(command: "act", step: 1)])

            let first = ReportPipeline.run(runDirectory: root, out: nil)
            let firstBytes = try Data(contentsOf: URL(fileURLWithPath: RunBundle(root: root).reportPath))
            // Re-rendering into the bundle must not feed on its own previous output.
            let second = ReportPipeline.run(runDirectory: root, out: nil)
            let secondBytes = try Data(contentsOf: URL(fileURLWithPath: RunBundle(root: root).reportPath))
            #expect(first == second)
            #expect(firstBytes == secondBytes)
        }
    }

    @Test func timestampsRenderInUTCWithoutALocaleOrTimeZone() {
        #expect(RunReportHTML.utcText(0) == "1970-01-01 00:00:00.000 UTC")
        #expect(RunReportHTML.utcText(1_700_000_000.25) == "2023-11-14 22:13:20.250 UTC")
        #expect(RunReportHTML.utcText(.nan) == "(out of range)")
        #expect(RunReportHTML.utcText(.infinity) == "(out of range)")
        #expect(RunReportHTML.secondsText(6) == "6.000 s")
    }
}

// MARK: - The report command

@Suite struct ReportPipelineTests {
    @Test func renderingWritesReportHtmlIntoTheBundleByDefault() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([
                line(command: "act", step: 1),
                line(command: "read", step: 2, ok: false, exit: 3, errorClass: "ref"),
            ])

            switch ReportPipeline.run(runDirectory: root, out: nil) {
            case let .rendered(path, message):
                #expect(path == RunBundle(root: root).reportPath)
                #expect(message.hasPrefix("wrote \(path) ("))
                #expect(message.contains("2 records"))
                #expect(message.contains("1 failed"))
                #expect(message.contains(" bytes)"))
                #expect(FileManager.default.fileExists(atPath: path))
            case let .failed(stderr, code):
                Issue.record("expected a rendered report, got \(code): \(stderr)")
            }
        }
    }

    @Test func outRedirectsTheHtmlAndCreatesMissingParents() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([line(command: "act", step: 1)])
            let target = dir.appendingPathComponent("out/nested/report.html").path

            switch ReportPipeline.run(runDirectory: root, out: target) {
            case let .rendered(path, _):
                #expect(path == target)
                #expect(FileManager.default.fileExists(atPath: target))
                // The bundle itself was left alone.
                #expect(!FileManager.default.fileExists(atPath: RunBundle(root: root).reportPath))
            case let .failed(stderr, code):
                Issue.record("expected a rendered report, got \(code): \(stderr)")
            }
        }
    }

    @Test func aMissingRunDirectoryFailsWithAnActionableDiagnostic() {
        withTempDir { dir in
            let missing = dir.appendingPathComponent("nope").path
            let outcome = ReportPipeline.run(runDirectory: missing, out: nil)
            #expect(outcome == .failed(
                stderr: "mtouch: run directory not found: \(missing)", code: .runtimeFailure
            ))
        }
    }

    @Test func aFilePassedAsTheRunDirectoryIsRefusedNotParsed() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("trajectory.jsonl")
            try Data("{}\n".utf8).write(to: file)
            switch ReportPipeline.run(runDirectory: file.path, out: nil) {
            case let .failed(stderr, code):
                #expect(code == .runtimeFailure)
                #expect(stderr.contains("not a run directory"))
                #expect(stderr.contains("MTOUCH_RUN_DIR"))
            case .rendered:
                Issue.record("a file must never be accepted as a run directory")
            }
        }
    }

    @Test func anUnwritableDestinationFailsRatherThanReportingSuccess() throws {
        try #require(getuid() != 0)
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let builder = try BundleBuilder(root: root)
            try builder.writeTrajectory([line(command: "act", step: 1)])
            let locked = dir.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)

            switch ReportPipeline.run(runDirectory: root, out: locked.appendingPathComponent("r.html").path) {
            case let .failed(stderr, code):
                #expect(code == .runtimeFailure)
                #expect(stderr.contains("cannot write report to"))
            case .rendered:
                Issue.record("an unwritable destination must not report success")
            }
        }
    }
}

// MARK: - End-to-end through the recorder

@Suite struct RunReportEndToEndTests {
    @Test func aBundleTheRecorderProducedRendersWithItsScreenshotsInline() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("run").path
            let environment = [
                MTouchEnvironment.runDirKey: root,
                MTouchEnvironment.runCaptureKey: "1",
                MTouchEnvironment.runLabelKey: "smoke",
            ]
            let capture = StubReportCapture()
            for (command, kind) in [("act", TrajectoryKind.action), ("read", TrajectoryKind.read)] {
                _ = try TrajectoryRecorder.record(
                    command: command, args: TrajectoryArgs.build(["ref": .string("e1")]), kind: kind,
                    environment: environment, operation: {},
                    describe: { _ in TrajectoryOutcomeInfo(ok: true, exit: 0, errorClass: nil) },
                    capture: capture
                )
            }

            let html = render(root)
            #expect(html.contains("smoke"))
            #expect(html.contains(">0001<"))
            #expect(html.contains(">0002<"))
            #expect(html.contains("2 passed"))
            let payload = Data("stub-png".utf8).base64EncodedString()
            // before + after for the action, one state for the read.
            #expect(html.components(separatedBy: "data:image/png;base64,\(payload)").count - 1 == 3)
            #expect(!html.contains("screenshot missing"))
        }
    }
}

/// A capture that never touches the screen.
private struct StubReportCapture: RunCapturing {
    func capturePNG() -> Result<Data, RunCaptureFailure> { .success(Data("stub-png".utf8)) }
}
