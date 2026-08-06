import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

@Suite struct JSONTextTests {
    @Test func integralDoublesDropTheDecimalPoint() {
        #expect(JSONText.number(585.0) == "585")
        #expect(JSONText.number(0) == "0")
        #expect(JSONText.number(-10) == "-10")
    }

    @Test func fractionalDoublesKeepTheFraction() {
        #expect(JSONText.number(10.5) == "10.5")
        #expect(JSONText.number(-3.25) == "-3.25")
    }

    @Test func nonFiniteDoublesRenderAsZero() {
        // The documented NaN/inf -> "0" branch keeps a stray non-finite value from
        // producing invalid JSON (`nan`/`inf` are not JSON tokens).
        #expect(JSONText.number(.nan) == "0")
        #expect(JSONText.number(.infinity) == "0")
        #expect(JSONText.number(-.infinity) == "0")
    }

    @Test func escapesQuotesBackslashesAndControlCharacters() {
        #expect(JSONText.string("a\"b\\c\nd\te\u{01}") == "\"a\\\"b\\\\c\\nd\\te\\u0001\"")
        #expect(JSONText.string("") == "\"\"")
        #expect(JSONText.string("plain") == "\"plain\"")
    }
}

@Suite struct RunningAppInfoTests {
    private let textEdit = RunningAppInfo(bundleId: "com.apple.TextEdit", pid: 501, name: "TextEdit")

    @Test func textLineLeadsWithBareBundleIdToken() {
        #expect(textEdit.textLine == "com.apple.TextEdit\t501\tTextEdit")
        #expect(textEdit.textLine.split(separator: "\t").first == "com.apple.TextEdit")
    }

    @Test func jsonArrayHasStableKeysAndValues() throws {
        let json = RunningAppInfo.jsonArray([textEdit])
        #expect(json == "[{\"bundleId\":\"com.apple.TextEdit\",\"pid\":501,\"name\":\"TextEdit\"}]")

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        let first = try #require(parsed?.first)
        #expect(first["bundleId"] as? String == "com.apple.TextEdit")
        #expect(first["pid"] as? Int == 501)
        #expect(first["name"] as? String == "TextEdit")
    }

    @Test func jsonEscapesNames() {
        let app = RunningAppInfo(bundleId: "com.example.q", pid: 7, name: "Say \"hi\"")
        #expect(app.jsonObject == "{\"bundleId\":\"com.example.q\",\"pid\":7,\"name\":\"Say \\\"hi\\\"\"}")
    }

    @Test func emptyListRendersEmptyArray() {
        #expect(RunningAppInfo.jsonArray([]) == "[]")
    }

    @Test func displayOrderSortsByBundleIdThenPid() {
        let apps = [
            RunningAppInfo(bundleId: "com.b", pid: 2, name: "B"),
            RunningAppInfo(bundleId: "com.a", pid: 9, name: "A2"),
            RunningAppInfo(bundleId: "com.a", pid: 3, name: "A1"),
        ]
        let ordered = RunningAppInfo.displayOrder(apps)
        #expect(ordered.map(\.pid) == [3, 9, 2])
    }
}

@Suite struct ResolvePIDTests {
    @Test func resolvesCaseInsensitively() throws {
        let pid = try AXWindowEnumerator.resolvePID(
            bundleId: "COM.APPLE.TEXTEDIT",
            in: [(bundleId: "com.apple.Finder", pid: 100), (bundleId: "com.apple.TextEdit", pid: 200)]
        )
        #expect(pid == 200)
    }

    @Test func skipsEntriesWithoutBundleId() throws {
        let pid = try AXWindowEnumerator.resolvePID(
            bundleId: "com.apple.TextEdit",
            in: [(bundleId: nil, pid: 1), (bundleId: "com.apple.TextEdit", pid: 2)]
        )
        #expect(pid == 2)
    }

    @Test func notRunningThrowsTypedError() {
        #expect(throws: AppNotRunningError(bundleId: "com.example.nope")) {
            try AXWindowEnumerator.resolvePID(
                bundleId: "com.example.nope",
                in: [(bundleId: "com.apple.Finder", pid: 100)]
            )
        }
    }

    @Test func errorMessageNamesBundleIdStatesNotRunningAndSuggestsApps() {
        let message = AppNotRunningError(bundleId: "com.example.nope").message
        #expect(message.contains("com.example.nope"))
        #expect(message.contains("not running"))
        #expect(message.contains("mtouch apps"))
    }
}

@Suite struct WindowInfoTests {
    private let window = WindowInfo(
        id: 42,
        title: "Untitled 2",
        frame: CGRect(x: 0, y: 25, width: 585.5, height: 476)
    )

    @Test func jsonObjectHasStableShapeAndFrameEncoding() {
        #expect(window.jsonObject
            == "{\"id\":42,\"title\":\"Untitled 2\",\"frame\":{\"x\":0,\"y\":25,\"w\":585.5,\"h\":476}}")
    }

    @Test func jsonArrayParsesWithFrameKeys() throws {
        let json = WindowInfo.jsonArray([window])
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        let first = try #require(parsed?.first)
        #expect(first["id"] as? Int == 42)
        #expect(first["title"] as? String == "Untitled 2")
        let frame = try #require(first["frame"] as? [String: Double])
        #expect(frame == ["x": 0, "y": 25, "w": 585.5, "h": 476])
    }

    @Test func emptyListRendersEmptyArray() {
        #expect(WindowInfo.jsonArray([]) == "[]")
    }

    @Test func textLineCarriesIdTitlePositionAndSize() {
        #expect(window.textLine == "42\tUntitled 2\t0,25\t585.5x476")
    }

    @Test func titlesAreEscapedInJSON() {
        let tricky = WindowInfo(id: 7, title: "a\"b", frame: .zero)
        #expect(tricky.jsonObject == "{\"id\":7,\"title\":\"a\\\"b\",\"frame\":{\"x\":0,\"y\":0,\"w\":0,\"h\":0}}")
    }
}
