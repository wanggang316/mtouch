import Foundation
import Testing
@testable import MTouchKit

private struct StubPermissionProvider: PermissionProvider {
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool
}

@Suite struct PreflightTests {
    @Test func requireAccessibilityPassesWhenGranted() throws {
        let provider = StubPermissionProvider(accessibilityGranted: true, screenRecordingGranted: false)
        try Preflight.requireAccessibility(provider: provider)
    }

    @Test func requireAccessibilityThrowsWhenMissing() {
        let provider = StubPermissionProvider(accessibilityGranted: false, screenRecordingGranted: true)
        #expect(throws: PermissionError(permission: .accessibility)) {
            try Preflight.requireAccessibility(provider: provider)
        }
    }

    @Test func requireScreenRecordingPassesWhenGranted() throws {
        let provider = StubPermissionProvider(accessibilityGranted: false, screenRecordingGranted: true)
        try Preflight.requireScreenRecording(provider: provider)
    }

    @Test func requireScreenRecordingThrowsWhenMissing() {
        let provider = StubPermissionProvider(accessibilityGranted: true, screenRecordingGranted: false)
        #expect(throws: PermissionError(permission: .screenRecording)) {
            try Preflight.requireScreenRecording(provider: provider)
        }
    }
}

@Suite struct PermissionDiagnosticTests {
    @Test(arguments: Permission.allCases)
    func diagnosticNamesPermissionPaneTerminalAndDoctor(_ permission: Permission) {
        let diagnostic = PermissionError(permission: permission).diagnostic
        #expect(diagnostic.contains("\(permission.displayName) permission is not granted"))
        #expect(diagnostic.contains(permission.settingsPane))
        #expect(diagnostic.contains("invoking terminal application"))
        #expect(diagnostic.contains("mtouch doctor"))
    }

    @Test func settingsPanesMatchSystemSettings() {
        #expect(Permission.accessibility.settingsPane == "Privacy & Security → Accessibility")
        #expect(Permission.screenRecording.settingsPane == "Privacy & Security → Screen & System Audio Recording")
    }
}

@Suite struct DoctorReportTests {
    private static let grantCombinations: [(ax: Bool, sr: Bool)] = [
        (true, true), (true, false), (false, true), (false, false),
    ]

    private func report(ax: Bool, sr: Bool) -> DoctorReport {
        DoctorReport(provider: StubPermissionProvider(accessibilityGranted: ax, screenRecordingGranted: sr))
    }

    // Accessibility alone drives the exit code; Screen Recording never masks it.
    @Test(arguments: grantCombinations)
    func exitCodeDependsOnlyOnAccessibility(_ combo: (ax: Bool, sr: Bool)) {
        let expected: MTouchExitCode = combo.ax ? .success : .permissionMissing
        #expect(report(ax: combo.ax, sr: combo.sr).exitCode == expected)
    }

    @Test(arguments: grantCombinations)
    func textReportsEachPermissionIndependently(_ combo: (ax: Bool, sr: Bool)) {
        let lines = report(ax: combo.ax, sr: combo.sr).textLines()
        #expect(lines.contains("Accessibility: \(combo.ax ? "granted" : "missing") (required)"))
        #expect(lines.contains("Screen Recording: \(combo.sr ? "granted" : "missing") (optional)"))
    }

    @Test func textIncludesGuidanceOnlyForMissingPermissions() {
        let lines = report(ax: false, sr: true).textLines()
        let text = lines.joined(separator: "\n")
        #expect(text.contains(Permission.accessibility.settingsPane))
        #expect(!text.contains(Permission.screenRecording.settingsPane))
        #expect(text.contains("invoking terminal application"))
        #expect(text.contains("mtouch doctor"))

        let allGranted = report(ax: true, sr: true).textLines()
        #expect(allGranted.count == 2)
    }

    @Test(arguments: grantCombinations)
    func jsonShapeIsStableAndMatchesVerdicts(_ combo: (ax: Bool, sr: Bool)) {
        let json = report(ax: combo.ax, sr: combo.sr).jsonString()
        let expected = "{\"permissions\":{"
            + "\"accessibility\":{\"granted\":\(combo.ax),\"required\":true},"
            + "\"screenRecording\":{\"granted\":\(combo.sr),\"required\":false}}}"
        #expect(json == expected)
    }

    @Test(arguments: grantCombinations)
    func jsonIsParseableWithMatchingVerdicts(_ combo: (ax: Bool, sr: Bool)) throws {
        let data = Data(report(ax: combo.ax, sr: combo.sr).jsonString().utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let permissions = try #require(object?["permissions"] as? [String: [String: Bool]])
        #expect(permissions["accessibility"]?["granted"] == combo.ax)
        #expect(permissions["accessibility"]?["required"] == true)
        #expect(permissions["screenRecording"]?["granted"] == combo.sr)
        #expect(permissions["screenRecording"]?["required"] == false)
    }
}
