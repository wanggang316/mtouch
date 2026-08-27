import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures

/// One node of a literal menu tree. `opensMenu` distinguishes a SUBMENU (pressing
/// it reveals its children) from a COMMAND (pressing it does the thing), which is
/// the difference the resolver must respect.
private final class FakeMenuItem {
    let title: String?
    var enabled: Bool
    var children: [FakeMenuItem]
    var opensMenu: Bool
    var pressSucceeds: Bool

    init(
        title: String?,
        enabled: Bool = true,
        children: [FakeMenuItem] = [],
        opensMenu: Bool = false,
        pressSucceeds: Bool = true
    ) {
        self.title = title
        self.enabled = enabled
        self.children = children
        self.opensMenu = opensMenu
        self.pressSucceeds = pressSucceeds
    }
}

/// A menu tree with no accessibility access at all: nothing is really opened, so a
/// test can drive every failure path without a live application and without any
/// risk of leaving a real menu hanging open.
private final class FakeMenuNavigator: MenuNavigator {
    typealias Item = FakeMenuItem

    private let bar: [FakeMenuItem]?
    private(set) var pressed: [String] = []
    private(set) var closeCalls = 0
    /// Every step, in order, so "waited for the menu to close BEFORE returning" is
    /// asserted as an ordering fact.
    private(set) var journal: [String] = []

    init(bar: [FakeMenuItem]?) {
        self.bar = bar
    }

    func menuBarItems() -> [FakeMenuItem]? { bar }
    func title(of item: FakeMenuItem) -> String? { item.title }
    func isEnabled(_ item: FakeMenuItem) -> Bool { item.enabled }

    func press(_ item: FakeMenuItem) -> Bool {
        pressed.append(item.title ?? "<untitled>")
        journal.append("press \(item.title ?? "<untitled>")")
        return item.pressSucceeds
    }

    func openedItems(of item: FakeMenuItem) -> [FakeMenuItem]? {
        journal.append("open \(item.title ?? "<untitled>")")
        return item.opensMenu ? item.children : nil
    }

    func awaitDismissal() { journal.append("await-dismissal") }

    func closeMenus() {
        closeCalls += 1
        journal.append("close")
    }
}

private func submenu(_ title: String, _ children: [FakeMenuItem], enabled: Bool = true) -> FakeMenuItem {
    FakeMenuItem(title: title, enabled: enabled, children: children, opensMenu: true)
}

private func command(_ title: String?, enabled: Bool = true, pressSucceeds: Bool = true) -> FakeMenuItem {
    FakeMenuItem(title: title, enabled: enabled, pressSucceeds: pressSucceeds)
}

/// A representative English menu bar, including a disabled item, an untitled
/// separator, and a nested submenu.
private func englishBar() -> [FakeMenuItem] {
    [
        submenu("File", [
            command("New File"),
            command("Open…"),
            command(nil),                        // separator
            command("Save"),
            command("Save As…", enabled: false), // exists but unavailable
            submenu("Share", [command("Email"), command("Message")]),
        ]),
        submenu("Edit", [command("Copy"), command("Paste")]),
    ]
}

private func path(_ raw: String) throws -> MenuPath {
    try MenuPath(parsing: raw)
}

private func invoke(_ raw: String, _ navigator: FakeMenuNavigator) throws -> Result<Void, MenuPathError> {
    MenuPathResolver.invoke(path: try path(raw), in: navigator)
}

private func error(_ result: Result<Void, MenuPathError>) -> MenuPathError? {
    guard case let .failure(error) = result else { return nil }
    return error
}

// MARK: - Grammar

@Suite struct MenuPathGrammarTests {
    @Test func parsesASeparatedPath() throws {
        #expect(try path("File>Save").segments == ["File", "Save"])
        #expect(try path("File>Share>Email").segments == ["File", "Share", "Email"])
    }

    @Test func trimsWhitespaceAroundEachSegment() throws {
        #expect(try path("  File  >  Save As…  ").segments == ["File", "Save As…"])
    }

    @Test func aSingleSegmentIsAValidPath() throws {
        #expect(try path("File").segments == ["File"])
    }

    @Test func rejectsAnEmptyOrIncompletePathAsAUsageError() {
        for raw in ["", "   ", "File>", ">Save", "File>>Save"] {
            do {
                _ = try path(raw)
                Issue.record("'\(raw)' should not parse")
            } catch let parseError as MenuPathError {
                #expect(parseError.exitCode == .usageError, "'\(raw)' is a malformed argument")
            } catch {
                Issue.record("unexpected error for '\(raw)': \(error)")
            }
        }
    }

    @Test func theItemFormKeepsASegmentContainingTheSeparator() throws {
        // The escape hatch for a title that itself contains '>': no parsing at all.
        let menuPath = try MenuPath(segments: ["Format", "Indent > Increase"])
        #expect(menuPath.segments == ["Format", "Indent > Increase"])
    }

    @Test func theItemFormStillRejectsEmptySegments() {
        #expect(throws: MenuPathError.self) { try MenuPath(segments: []) }
        #expect(throws: MenuPathError.self) { try MenuPath(segments: ["File", "  "]) }
    }

    @Test func renderedIsTheCanonicalForm() throws {
        #expect(try path(" File > Save ").rendered == "File>Save")
    }
}

// MARK: - Title matching (pure, table-driven)

@Suite struct MenuMatchingTests {
    @Test func prefersAnExactTitleThenACaseInsensitiveOne() {
        let cases: [(name: String, segment: String, titles: [String?], expected: MenuMatching.Match)] = [
            ("exact", "Save", ["New File", "Save", "Save As…"], .matched(1)),
            ("case-insensitive fallback", "save", ["New File", "Save"], .matched(1)),
            ("uppercase fallback", "SAVE AS…", ["Save", "Save As…"], .matched(1)),
            ("exact beats case-insensitive", "save", ["save", "Save"], .matched(0)),
            ("localized CJK", "存储", ["新建文件", "存储", "存储为…"], .matched(1)),
            ("localized CJK missing", "打印", ["新建文件", "存储"], .notFound),
            ("separators never match", "", [nil, "Save"], .notFound),
            ("untitled items are skipped", "Save", [nil, nil, "Save"], .matched(2)),
            ("missing", "Nope", ["New File", "Save"], .notFound),
            ("ambiguous exact", "Save", ["Save", "Save"], .ambiguous(2)),
            ("ambiguous case-insensitive", "save", ["Save", "SAVE"], .ambiguous(2)),
            ("empty menu", "Save", [], .notFound),
        ]

        for testCase in cases {
            let match = MenuMatching.match(testCase.segment, in: testCase.titles)
            #expect(match == testCase.expected, "\(testCase.name): got \(match)")
        }
    }
}

// MARK: - Walking the path

@Suite struct MenuPathResolverTests {
    @Test func opensEachLevelThenInvokesTheLeaf() throws {
        let navigator = FakeMenuNavigator(bar: englishBar())
        let result = try invoke("File>Save", navigator)

        #expect(error(result) == nil)
        #expect(navigator.pressed == ["File", "Save"])
        #expect(navigator.closeCalls == 0)   // the leaf press dismisses the menu itself
    }

    @Test func descendsANestedSubmenu() throws {
        let navigator = FakeMenuNavigator(bar: englishBar())
        let result = try invoke("File>Share>Email", navigator)

        #expect(error(result) == nil)
        #expect(navigator.pressed == ["File", "Share", "Email"])
    }

    @Test func aSingleSegmentJustOpensTheMenu() throws {
        let navigator = FakeMenuNavigator(bar: englishBar())
        let result = try invoke("File", navigator)

        #expect(error(result) == nil)
        #expect(navigator.pressed == ["File"])
    }

    @Test func matchesCaseInsensitivelyWhenNoExactTitleExists() throws {
        let navigator = FakeMenuNavigator(bar: englishBar())
        #expect(error(try invoke("file>save", navigator)) == nil)
        #expect(navigator.pressed == ["File", "Save"])
    }

    @Test func drivesALocalizedMenuBar() throws {
        // Menu titles are user-visible and localized; nothing may assume English.
        let navigator = FakeMenuNavigator(bar: [
            submenu("文件", [command("新建文件"), command("存储")]),
            submenu("编辑", [command("拷贝")]),
        ])
        #expect(error(try invoke("文件>存储", navigator)) == nil)
        #expect(navigator.pressed == ["文件", "存储"])
    }

    @Test func aMissingSegmentListsWhatWasAvailableThere() throws {
        let navigator = FakeMenuNavigator(bar: englishBar())
        let failure = try #require(error(try invoke("File>Nope", navigator)))

        #expect(failure.exitCode == .runtimeFailure)
        // The listing is what lets an agent correct itself without another round trip.
        #expect(failure.message.contains("'New File'"))
        #expect(failure.message.contains("'Save'"))
        #expect(failure.message.contains("'Save As…'"))
        #expect(failure.message.contains("Nope"))
        #expect(navigator.pressed == ["File"])   // the leaf was never pressed
    }

    @Test func aMissingTopLevelSegmentListsTheMenuBarTitles() throws {
        let navigator = FakeMenuNavigator(bar: englishBar())
        let failure = try #require(error(try invoke("Fyle>Save", navigator)))

        #expect(failure.message.contains("'File'"))
        #expect(failure.message.contains("'Edit'"))
        #expect(navigator.pressed.isEmpty)       // nothing was touched at all
        #expect(navigator.closeCalls == 0)       // so nothing is dismissed either
    }

    @Test func aDisabledLeafIsRefusedWithoutPressingIt() throws {
        let navigator = FakeMenuNavigator(bar: englishBar())
        let failure = try #require(error(try invoke("File>Save As…", navigator)))

        #expect(failure.exitCode == .runtimeFailure)
        #expect(failure.message.contains("disabled"))
        #expect(navigator.pressed == ["File"])   // never pressed the disabled item
    }

    @Test func sameTitledSiblingsAreRefusedRatherThanGuessed() throws {
        let navigator = FakeMenuNavigator(bar: [
            submenu("File", [command("Export"), command("Export")]),
        ])
        let failure = try #require(error(try invoke("File>Export", navigator)))

        #expect(failure.exitCode == .runtimeFailure)
        #expect(failure.message.contains("2 items"))
        #expect(navigator.pressed == ["File"])
    }

    @Test func aRefusedPressIsReportedNotSilentlyIgnored() throws {
        let navigator = FakeMenuNavigator(bar: [
            submenu("File", [command("Save", pressSucceeds: false)]),
        ])
        let failure = try #require(error(try invoke("File>Save", navigator)))

        #expect(failure.exitCode == .runtimeFailure)
        #expect(failure.message.contains("refused"))
    }

    @Test func anItemThatOpensNoMenuStopsThePath() throws {
        // 'Save' is a command, not a submenu, so 'File>Save>More' cannot continue —
        // and must say why rather than silently invoking Save.
        let navigator = FakeMenuNavigator(bar: englishBar())
        let failure = try #require(error(try invoke("File>Save>More", navigator)))

        #expect(failure.exitCode == .runtimeFailure)
        #expect(failure.message.contains("opened no menu"))
    }

    @Test func anUnreadableMenuBarIsReported() {
        let navigator = FakeMenuNavigator(bar: nil)
        let result = MenuPathResolver.invoke(
            path: try! MenuPath(segments: ["File", "Save"]), in: navigator
        )
        #expect(error(result)?.reason == .menuBarUnreadable)
        #expect(navigator.closeCalls == 0)
    }

    /// THE hard requirement: a failed path never leaves a menu hanging open. An
    /// open menu swallows every later click and keystroke, so one failed attempt
    /// would wedge every following step of a session.
    @Test func everyFailureAfterOpeningAMenuClosesItAgain() throws {
        let cases: [(name: String, path: String, bar: () -> [FakeMenuItem])] = [
            ("missing item", "File>Nope", englishBar),
            ("disabled item", "File>Save As…", englishBar),
            ("missing item one level deeper", "File>Share>Nope", englishBar),
            ("path continues past a command", "File>Save>More", englishBar),
            ("ambiguous siblings", "File>Export", {
                [submenu("File", [command("Export"), command("Export")])]
            }),
            ("refused press", "File>Save", {
                [submenu("File", [command("Save", pressSucceeds: false)])]
            }),
        ]

        for testCase in cases {
            let navigator = FakeMenuNavigator(bar: testCase.bar())
            let result = try invoke(testCase.path, navigator)

            #expect(error(result) != nil, "\(testCase.name) should fail")
            #expect(navigator.closeCalls == 1, "\(testCase.name) must close the menus it opened")
        }
    }

    @Test func aSuccessfulInvocationSendsNoDismissal() throws {
        // A stray dismissal after a successful command could cancel whatever the
        // command just opened, so success must send none.
        let navigator = FakeMenuNavigator(bar: englishBar())
        _ = try invoke("File>Share>Email", navigator)
        #expect(navigator.closeCalls == 0)
    }

    @Test func waitsForTheInvokedMenuToDisappearBeforeReturning() throws {
        // Otherwise the caller's post-action walk races the closing menu and reports
        // THE MENU as the result of the command instead of what the command did.
        let navigator = FakeMenuNavigator(bar: englishBar())
        _ = try invoke("File>Save", navigator)

        #expect(navigator.journal == ["press File", "open File", "press Save", "await-dismissal"])
    }

    @Test func aFailedPathNeverWaitsOnADismissalThatWillNotHappen() throws {
        let navigator = FakeMenuNavigator(bar: englishBar())
        _ = try invoke("File>Nope", navigator)
        #expect(!navigator.journal.contains("await-dismissal"))
        #expect(navigator.journal.last == "close")
    }
}
