import ApplicationServices
import CoreGraphics

/// Menu-descent policy for the AX walker: whether to walk INTO a submenu.
///
/// A macOS menu bar keeps every submenu's items in the accessibility tree even
/// while the menu is CLOSED — as children of an off-screen, zero-size `AXMenu`
/// owned by the menu-bar item. Walking those pre-expands hundreds of items that
///   1. bloat the snapshot far past its line budget (VAL-SNAP-004), and
///   2. are semantically wrong: a closed menu's items are NOT reachable by an
///      agent until the menu is opened, so the perception model must not
///      advertise actions the action model cannot yet perform.
/// This policy drops the closed `AXMenu` so the owner (`File`, `Edit`, …) stays
/// in the snapshot as a single actionable, ref-bearing node with no descendants.
///
/// SEAM for the act layer (M2 `act show-menu`, VAL-ACT-007): once a menu is
/// actually opened it is drawn on screen and its `AXMenu` reports a real,
/// non-zero frame — at which point `isClosedSubmenu` returns false and the
/// walker descends it, so a post-open snapshot/diff reveals the now-live items.
/// Menus are therefore collapsed by default but never permanently unwalkable:
/// opening one is exactly what makes its items appear.
enum MenuDescent {
    /// Whether an element with this role owns a submenu as an `AXMenu` child:
    /// menu-bar items (`File`, `Edit`, …) and the menu items nested inside an
    /// opened menu (which may in turn own their own submenus). Used to gate the
    /// closed-submenu check to menu owners only, so the extra child read never
    /// touches the rest of the tree.
    static func ownsSubmenu(ownerRole: String) -> Bool {
        ownerRole == kAXMenuBarItemRole || ownerRole == kAXMenuItemRole
    }

    /// Whether `child` is a CLOSED submenu the walker must not descend into: an
    /// `AXMenu` that is not currently displayed. A displayed menu necessarily
    /// occupies a real on-screen rectangle, so a zero-size (or unreadable) frame
    /// marks it closed. Non-`AXMenu` children are never closed submenus.
    static func isClosedSubmenu(_ child: AXAttributes) -> Bool {
        guard child.role == kAXMenuRole else { return false }
        guard let frame = child.frame else { return true }
        return frame.width == 0 || frame.height == 0
    }
}
