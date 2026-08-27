import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fake provider (zero AX/TCC dependency)

/// Drives `AXTreeWalker` from literal `AXNode` trees. Backed by two fixtures:
/// `before` is returned until the fallback is enabled, then `after`. Counts the
/// walk passes and fallback attempts so tests can assert the retry is bounded.
///
/// `attributes(of:)` re-derives an `AXAttributes` from a fixture node, mapping
/// the node's declared `actionable` back to an `AXPress` action so the walker's
/// own `actionable`/`isScrollArea` derivation is exercised (not bypassed). Build
/// fixtures whose `actionable`/`isScrollArea` are consistent with that
/// derivation, so a walk round-trips to the fixture.
final class FakeTreeProvider: AXTreeProvider {
    typealias Element = AXNode

    private let before: [AXNode]
    private let after: [AXNode]
    private var manualAccessibilityEnabled = false

    private(set) var rootsCallCount = 0
    private(set) var fallbackCallCount = 0

    init(before: [AXNode], after: [AXNode]? = nil) {
        self.before = before
        self.after = after ?? before
    }

    func roots() -> [AXNode] {
        rootsCallCount += 1
        return manualAccessibilityEnabled ? after : before
    }

    func children(of element: AXNode) -> [AXNode] { element.children }

    func attributes(of element: AXNode) -> AXAttributes {
        AXAttributes(
            role: element.role,
            subrole: element.subrole,
            title: element.title,
            value: element.value,
            description: element.description,
            identifier: element.identifier,
            frame: element.frame,
            enabled: element.enabled,
            actionNames: element.actionable ? [kAXPressAction] : [],
            scrollPosition: element.scrollPosition
        )
    }

    func enableManualAccessibilityFallback() {
        fallbackCallCount += 1
        manualAccessibilityEnabled = true
    }
}

// MARK: - Fixtures

private func button(_ title: String) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, enabled: true, actionable: true)
}

private func staticText(_ text: String) -> AXNode {
    AXNode(role: kAXStaticTextRole, title: text)
}

/// A window whose subtree carries a button and a line of static text.
private func populatedWindow() -> AXNode {
    AXNode(
        role: kAXWindowRole,
        title: "Untitled",
        children: [
            AXNode(role: kAXGroupRole, children: [button("OK"), staticText("Hello")]),
        ]
    )
}

/// A window whose subtree has no actionable elements and no text — only inert
/// chrome. The window still reports a title (which must not count as content).
private func blankWindow() -> AXNode {
    AXNode(
        role: kAXWindowRole,
        title: "Untitled",
        children: [AXNode(role: kAXGroupRole, children: [AXNode(role: kAXGroupRole)])]
    )
}

private func menuItem(_ title: String) -> AXNode {
    AXNode(role: kAXMenuItemRole, title: title, actionable: true)
}

/// A menu-bar item that owns a submenu. `menuFrame` decides the submenu's
/// displayed state: a zero-size frame is the closed (off-screen) form macOS
/// reports for an unopened menu; a real on-screen frame is the opened form.
private func menuBarItem(_ title: String, menuFrame: CGRect) -> AXNode {
    AXNode(
        role: kAXMenuBarItemRole,
        title: title,
        actionable: true,
        children: [
            AXNode(
                role: kAXMenuRole,
                frame: menuFrame,
                children: [menuItem("New"), menuItem("Open")]
            ),
        ]
    )
}

private let closedSubmenuFrame = CGRect(x: 0, y: 1080, width: 0, height: 0)
private let openSubmenuFrame = CGRect(x: 116, y: 30, width: 200, height: 400)

// MARK: - Walker behavior

@Suite struct TreeWalkerTests {
    @Test func populatedTreeRoundTripsWithoutFallback() {
        let fixture = [populatedWindow()]
        let provider = FakeTreeProvider(before: fixture)

        let result = AXTreeWalker.walk(provider: provider)

        #expect(result.nodes == fixture)
        #expect(result.fallbackFired == false)
        #expect(result.fallbackHelped == false)
        #expect(result.truncated == false)
        // No emptiness -> exactly one pass, fallback never attempted.
        #expect(provider.rootsCallCount == 1)
        #expect(provider.fallbackCallCount == 0)
    }

    @Test func emptyThenPopulatedFiresFallbackAndItHelps() {
        let populated = [populatedWindow()]
        let provider = FakeTreeProvider(before: [blankWindow()], after: populated)

        let result = AXTreeWalker.walk(provider: provider)

        #expect(result.nodes == populated)
        #expect(result.fallbackFired == true)
        #expect(result.fallbackHelped == true)
        // First pass empty, second pass populated -> exactly two passes.
        #expect(provider.rootsCallCount == 2)
        #expect(provider.fallbackCallCount == 1)
    }

    @Test func emptyThenEmptyFiresFallbackExactlyOnceAndItDoesNotHelp() {
        let provider = FakeTreeProvider(before: [blankWindow()], after: [blankWindow()])

        let result = AXTreeWalker.walk(provider: provider)

        #expect(isEffectivelyEmpty(result.nodes))
        #expect(result.fallbackFired == true)
        #expect(result.fallbackHelped == false)
        // The retry is bounded: exactly two walk passes and one fallback attempt.
        #expect(provider.rootsCallCount == 2)
        #expect(provider.fallbackCallCount == 1)
    }

    @Test func pathologicalDepthIsCappedNotInfinite() {
        // A chain deeper than the cap: the walk must terminate, flag truncation,
        // and not descend past the cap.
        var leaf = AXNode(role: kAXGroupRole)
        for _ in 0..<(AXTreeWalker.maxDepth + 50) {
            leaf = AXNode(role: kAXGroupRole, children: [leaf])
        }
        let provider = FakeTreeProvider(before: [AXNode(role: kAXWindowRole, children: [leaf])])

        let result = AXTreeWalker.walk(provider: provider)

        #expect(result.truncated == true)
        let depth = maxDepthOf(result.nodes[0])
        #expect(depth <= AXTreeWalker.maxDepth)
    }

    @Test func closedSubmenuIsNotExpandedButOwnerSurvives() {
        // A menu-bar item owning a CLOSED (zero-size, off-screen) submenu: the
        // owner stays and stays actionable, but its hidden items are not walked.
        let menuBar = AXNode(
            role: kAXMenuBarRole,
            children: [menuBarItem("File", menuFrame: closedSubmenuFrame)]
        )
        let provider = FakeTreeProvider(before: [menuBar])

        let result = AXTreeWalker.walk(provider: provider)

        let file = result.nodes[0].children[0]
        #expect(file.role == kAXMenuBarItemRole)
        #expect(file.title == "File")
        #expect(file.actionable == true)
        // The closed AXMenu (and its items) are dropped: the owner is a leaf.
        #expect(file.children.isEmpty)
        #expect(!result.nodes.flatMap(\.flattened).contains { $0.role == kAXMenuItemRole })
    }

    @Test func openMenuStillExposesItsItems() {
        // Once a menu is opened it has a real on-screen frame; its items MUST
        // still be walked (the M2 `act show-menu` path must not be broken).
        let menuBar = AXNode(
            role: kAXMenuBarRole,
            children: [menuBarItem("File", menuFrame: openSubmenuFrame)]
        )
        let provider = FakeTreeProvider(before: [menuBar])

        let result = AXTreeWalker.walk(provider: provider)

        let file = result.nodes[0].children[0]
        #expect(file.children.count == 1)
        let menu = file.children[0]
        #expect(menu.role == kAXMenuRole)
        #expect(menu.children.map(\.title) == ["New", "Open"])
    }

    private func maxDepthOf(_ node: AXNode) -> Int {
        1 + (node.children.map(maxDepthOf).max() ?? -1)
    }
}

// MARK: - Owning-window id capture (VAL-ACT-011 e2e — snapshot populate)

@Suite struct TreeWalkerWindowIDTests {
    /// A provider whose WINDOW roots each report a distinct CGWindowID (keyed by
    /// title) and whose non-window roots report none — so the walker's per-root
    /// window-id capture is exercised with zero AX access.
    private final class WindowIDProvider: AXTreeProvider {
        typealias Element = AXNode
        let rootNodes: [AXNode]
        let ids: [String: CGWindowID]
        init(roots: [AXNode], ids: [String: CGWindowID]) { rootNodes = roots; self.ids = ids }
        func roots() -> [AXNode] { rootNodes }
        func children(of element: AXNode) -> [AXNode] { element.children }
        func attributes(of element: AXNode) -> AXAttributes {
            AXAttributes(
                role: element.role, subrole: element.subrole, title: element.title,
                value: element.value, frame: element.frame, enabled: element.enabled,
                actionNames: element.actionable ? [kAXPressAction] : [], scrollPosition: element.scrollPosition
            )
        }
        func windowID(of element: AXNode) -> CGWindowID? {
            element.role == kAXWindowRole ? element.title.flatMap { ids[$0] } : nil
        }
        func enableManualAccessibilityFallback() {}
    }

    @Test func capturesEachRootWindowIDAndSkipsTheMenuBar() {
        let win0 = AXNode(role: kAXWindowRole, title: "W0", children: [button("Go")])
        let win1 = AXNode(role: kAXWindowRole, title: "W1", children: [button("Stop")])
        let menuBar = AXNode(
            role: kAXMenuBarRole,
            children: [AXNode(role: kAXMenuBarItemRole, title: "File", actionable: true)]
        )
        let provider = WindowIDProvider(roots: [win0, win1, menuBar], ids: ["W0": 7001, "W1": 7002])

        let result = AXTreeWalker.walk(provider: provider)

        // Only the two window roots carry ids; the menu-bar root contributes none.
        #expect(result.windowIDsByPath == [[0]: 7001, [1]: 7002])

        // Threaded into the snapshot, each ref records its owning window; the
        // menu-bar item's ref stays nil (no window).
        let snapshot = Snapshot(roots: result.nodes, windowIDsByPath: result.windowIDsByPath)
        #expect(snapshot.refs["e1"]?.ownerWindowID == 7001)   // W0's button
        #expect(snapshot.refs["e2"]?.ownerWindowID == 7002)   // W1's button
        #expect(snapshot.refs["e3"]?.ownerWindowID == nil)    // menu-bar item
    }
}

// MARK: - Menu-descent predicate

@Suite struct MenuDescentTests {
    @Test func menuBarItemsAndMenuItemsOwnSubmenus() {
        #expect(MenuDescent.ownsSubmenu(ownerRole: kAXMenuBarItemRole))
        #expect(MenuDescent.ownsSubmenu(ownerRole: kAXMenuItemRole))
        #expect(!MenuDescent.ownsSubmenu(ownerRole: kAXWindowRole))
        #expect(!MenuDescent.ownsSubmenu(ownerRole: kAXMenuRole))
    }

    @Test func zeroSizeOrMissingFrameMenuIsClosed() {
        #expect(MenuDescent.isClosedSubmenu(AXAttributes(role: kAXMenuRole, frame: closedSubmenuFrame)))
        #expect(MenuDescent.isClosedSubmenu(AXAttributes(role: kAXMenuRole, frame: nil)))
        #expect(MenuDescent.isClosedSubmenu(
            AXAttributes(role: kAXMenuRole, frame: CGRect(x: 0, y: 0, width: 200, height: 0))
        ))
    }

    @Test func onScreenMenuIsOpen() {
        #expect(!MenuDescent.isClosedSubmenu(AXAttributes(role: kAXMenuRole, frame: openSubmenuFrame)))
    }

    @Test func nonMenuChildIsNeverAClosedSubmenu() {
        // Only AXMenu children are subject to the collapse; a real off-screen
        // control (unlikely, but must not be dropped by this predicate) is kept.
        #expect(!MenuDescent.isClosedSubmenu(AXAttributes(role: kAXButtonRole, frame: closedSubmenuFrame)))
        #expect(!MenuDescent.isClosedSubmenu(AXAttributes(role: kAXGroupRole, frame: nil)))
    }
}

// MARK: - Actionable predicate

@Suite struct AXActionableTests {
    @Test func rolesInTheSetAreActionable() {
        #expect(AXActionable.isActionable(role: kAXButtonRole, actionNames: []))
        #expect(AXActionable.isActionable(role: kAXMenuItemRole, actionNames: []))
        #expect(AXActionable.isActionable(role: kAXCheckBoxRole, actionNames: []))
        #expect(AXActionable.isActionable(role: "AXLink", actionNames: []))
        #expect(AXActionable.isActionable(role: "AXTextArea", actionNames: []))
    }

    @Test func pressActionMakesAnyRoleActionable() {
        #expect(AXActionable.isActionable(role: kAXGroupRole, actionNames: [kAXPressAction]))
    }

    @Test func inertRoleWithoutPressIsNotActionable() {
        #expect(!AXActionable.isActionable(role: kAXGroupRole, actionNames: []))
        #expect(!AXActionable.isActionable(role: kAXStaticTextRole, actionNames: [kAXShowMenuAction]))
    }

    @Test func actionableIsDerivedWhenBuildingFromAttributes() {
        // Disabled but actionable: enabled is recorded, not a reason to drop it.
        let node = AXNode(
            attributes: AXAttributes(role: kAXButtonRole, enabled: false, actionNames: []),
            children: []
        )
        #expect(node.actionable == true)
        #expect(node.enabled == false)
    }
}

// MARK: - Effectively-empty predicate

@Suite struct IsEffectivelyEmptyTests {
    @Test func windowWithNoActionableOrTextIsEmpty() {
        #expect(isEffectivelyEmpty([blankWindow()]))
    }

    @Test func windowWithAnActionableDescendantIsNotEmpty() {
        let window = AXNode(role: kAXWindowRole, children: [button("Go")])
        #expect(!isEffectivelyEmpty([window]))
    }

    @Test func windowWithTextContentIsNotEmpty() {
        let window = AXNode(role: kAXWindowRole, children: [staticText("Ready")])
        #expect(!isEffectivelyEmpty([window]))
    }

    @Test func menuBarActionableItemsDoNotMaskEmptyWindows() {
        // The menu bar always has actionable items; it must not count.
        let menuBar = AXNode(
            role: kAXMenuBarRole,
            children: [AXNode(role: kAXMenuBarItemRole, title: "File", actionable: true)]
        )
        #expect(isEffectivelyEmpty([blankWindow(), menuBar]))
    }

    @Test func windowTitleAloneIsNotContent() {
        let window = AXNode(role: kAXWindowRole, title: "Important Document", children: [])
        #expect(isEffectivelyEmpty([window]))
    }

    @Test func noWindowsIsEmpty() {
        #expect(isEffectivelyEmpty([]))
    }
}

// MARK: - Value rendering

@Suite struct AXValueRenderingTests {
    @Test func rendersStringsBooleansAndNumbers() {
        #expect(AXValueRendering.string(from: "hello" as CFString) == "hello")
        #expect(AXValueRendering.string(from: kCFBooleanTrue) == "true")
        #expect(AXValueRendering.string(from: kCFBooleanFalse) == "false")
        #expect(AXValueRendering.string(from: 42 as CFNumber) == "42")
        #expect(AXValueRendering.string(from: 3.5 as CFNumber) == "3.5")
    }

    @Test func rendersNilForAbsentOrUnsupportedValues() {
        #expect(AXValueRendering.string(from: nil) == nil)
    }

    @Test func decodesBooleans() {
        #expect(AXValueRendering.bool(from: kCFBooleanTrue) == true)
        #expect(AXValueRendering.bool(from: kCFBooleanFalse) == false)
        #expect(AXValueRendering.bool(from: nil) == nil)
        #expect(AXValueRendering.bool(from: "nope" as CFString) == nil)
    }
}
