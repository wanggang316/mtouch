import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The live accessibility implementation of `MenuNavigator` for one application.
///
/// It reuses the walker's existing menu semantics rather than inventing new ones:
/// `MenuDescent.isClosedSubmenu` already encodes that a CLOSED menu reports a
/// zero-size frame and an OPEN one reports a real rectangle, which is exactly the
/// signal needed to know whether a press actually opened the menu — and the same
/// signal that makes the opened items appear in a snapshot.
///
/// A class (not a struct) because it must REMEMBER which menus it opened: closing
/// them again on a failure is part of the resolver's contract.
final class LiveMenuNavigator: MenuNavigator {
    typealias Item = AXUIElement

    /// Attempts to observe the menu a press should have opened. A menu is drawn
    /// asynchronously, so the first read routinely still shows it closed.
    static let openAttempts = 10
    /// Interval between those attempts (≤ 1s total, well inside the act budget).
    static let openInterval: TimeInterval = 0.1
    /// Attempts to observe the invoked menu closing again (≤ 1s at the same
    /// interval), after which the walk reports what it sees rather than waiting on.
    static let dismissAttempts = 10

    private let appElement: AXUIElement
    private let sleep: (TimeInterval) -> Void
    private let postEscape: () -> Void
    /// The menus opened by THIS walk, outermost first.
    private var openedMenus: [AXUIElement] = []

    init(
        pid: pid_t,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        postEscape: (() -> Void)? = nil
    ) {
        appElement = AXUIElementCreateApplication(pid)
        AXSupport.setMessagingTimeout(appElement)
        self.sleep = sleep
        self.postEscape = postEscape ?? LiveMenuNavigator.escapeKeystroke
    }

    func menuBarItems() -> [AXUIElement]? {
        let read = AXSupport.copyAttributeResult(appElement, kAXMenuBarAttribute)
        guard read.error == nil,
              let raw = read.value,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let menuBar = raw as! AXUIElement
        guard let children = AXSupport.copyAttribute(menuBar, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        return children
    }

    func title(of item: AXUIElement) -> String? {
        AXSupport.copyAttribute(item, kAXTitleAttribute) as? String
    }

    func isEnabled(_ item: AXUIElement) -> Bool {
        // An element that does not report the attribute is treated as enabled, the
        // same default the walker applies, so a missing attribute never blocks a
        // command that would in fact work.
        AXValueRendering.bool(from: AXSupport.copyAttribute(item, kAXEnabledAttribute)) ?? true
    }

    func press(_ item: AXUIElement) -> Bool {
        AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// The items of the menu the press revealed. Polls (never sleeps blindly past
    /// the answer) until an OPEN `AXMenu` child appears, and remembers it so a later
    /// failure can close it.
    func openedItems(of item: AXUIElement) -> [AXUIElement]? {
        for attempt in 0..<Self.openAttempts {
            if let menu = openMenu(of: item) {
                openedMenus.append(menu)
                return (AXSupport.copyAttribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            if attempt < Self.openAttempts - 1 { sleep(Self.openInterval) }
        }
        return nil
    }

    /// Wait for the menus this walk opened to actually disappear after the leaf was
    /// invoked. Without this the caller's post-action walk races the closing
    /// animation and reports the OPEN MENU as the action's result — which is both
    /// useless (it is not what the command did) and misleading (it looks like the
    /// menu was left hanging open). Bounded: if a menu somehow stays up, this
    /// returns anyway and the diff shows it, which is the honest report.
    func awaitDismissal() {
        defer { openedMenus.removeAll() }
        for attempt in 0..<Self.dismissAttempts {
            if openedMenus.allSatisfy({ !isOpen($0) }) { return }
            if attempt < Self.dismissAttempts - 1 { sleep(Self.openInterval) }
        }
    }

    /// Close every menu this walk opened, deepest first.
    ///
    /// `AXCancel` is preferred: it is an accessibility action addressed AT the menu,
    /// so it cannot leak into another application the way a synthesized keystroke
    /// can. A menu that refuses it falls back to an Escape keystroke — one per menu
    /// still open, since Escape closes a single level.
    func closeMenus() {
        for menu in openedMenus.reversed() {
            if AXUIElementPerformAction(menu, kAXCancelAction as CFString) != .success {
                postEscape()
            }
        }
        openedMenus.removeAll()
    }

    // MARK: - Internals

    /// The item's OPEN submenu, or nil while it is still closed. Reuses
    /// `MenuDescent`'s closed-menu predicate so "open" means exactly what the
    /// snapshot walker means by it.
    private func openMenu(of item: AXUIElement) -> AXUIElement? {
        guard let children = AXSupport.copyAttribute(item, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        return children.first { isOpen($0) }
    }

    /// Whether the element is a menu that is currently drawn on screen — the same
    /// judgement (`AXMenu` with a real frame) the snapshot walker makes.
    private func isOpen(_ element: AXUIElement) -> Bool {
        let attributes = AXAttributes(
            role: (AXSupport.copyAttribute(element, kAXRoleAttribute) as? String) ?? kAXUnknownRole,
            frame: AXSupport.frame(of: element)
        )
        return attributes.role == kAXMenuRole && !MenuDescent.isClosedSubmenu(attributes)
    }

    /// One Escape keystroke to the session, the last-resort dismissal when a menu
    /// refuses `AXCancel`. An open menu owns the keyboard, so it is the recipient.
    private static func escapeKeystroke() {
        let combo = KeyCombo(keyCode: CGKeyCode(kVK_Escape), flags: [])
        let poster = CGEventPoster()
        for event in KeyboardEvents.combo(combo, source: CGEventSource(stateID: .combinedSessionState)) {
            poster.post(event)
        }
    }
}
