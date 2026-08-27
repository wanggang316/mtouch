import Foundation

/// A menu-bar command addressed by its TITLE PATH, e.g. `File>Save`.
///
/// This exists because the accessibility tree of many applications is opaque in
/// their content area — no text field, no addressable control — while their MENU
/// BAR is fully exposed. Driving the menu bar is then the only reliable way to
/// command such an app, and it is strictly better than a blind keyboard shortcut:
/// every step is an accessibility press against a named, verifiable element, and
/// the result is a real diff rather than a hope that the right app had focus.
///
/// Grammar: segments separated by `>`, surrounding whitespace trimmed, so
/// `" File > Save "` and `"File>Save"` are the same path. A title that itself
/// contains `>` is addressed with the exact-segment form (`init(segments:)`, the
/// CLI's repeatable `--item`), which does no parsing at all.
public struct MenuPath: Equatable, Sendable {
    public static let separator: Character = ">"

    /// The trimmed, non-empty titles, outermost first. Never empty.
    public let segments: [String]

    /// Exact segments, one per menu level. No splitting: a segment may contain `>`.
    public init(segments: [String]) throws {
        let trimmed = segments.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !trimmed.isEmpty else {
            throw MenuPathError(reason: .empty)
        }
        guard !trimmed.contains(where: \.isEmpty) else {
            throw MenuPathError(reason: .emptySegment(path: segments.joined(separator: String(Self.separator))))
        }
        self.segments = trimmed
    }

    /// Parse the `A>B>C` form. An empty path, or any empty segment (`File>>Save`,
    /// a trailing `File>`), is a malformed request rather than a missing menu, so it
    /// is rejected here as a usage error before any application is touched.
    public init(parsing raw: String) throws {
        try self.init(
            segments: raw
                .split(separator: Self.separator, omittingEmptySubsequences: false)
                .map(String.init)
        )
    }

    /// The canonical `A>B>C` rendering, used in diagnostics and trajectory args.
    public var rendered: String { segments.joined(separator: String(Self.separator)) }
}

/// Why a menu path could not be invoked. Every case is DISTINCT and actionable —
/// a menu command that silently does nothing is the worst outcome for an agent,
/// so there is no "unknown failure" case and no silent no-op:
///   - a missing segment lists the titles that WERE available at that level, which
///     is what lets an agent correct itself without another round trip;
///   - a disabled leaf says so (the command exists but is not available now);
///   - same-titled siblings are refused rather than guessed between.
public struct MenuPathError: MTouchDiagnosticError, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// No segments at all.
        case empty
        /// A segment was empty after trimming (`File>>Save`).
        case emptySegment(path: String)
        /// The application's menu bar could not be read.
        case menuBarUnreadable
        /// No menu item at this level carries the requested title.
        case notFound(segment: String, context: String, available: [String])
        /// The item exists but cannot be invoked right now.
        case disabled(segment: String, context: String)
        /// Several items at this level carry the same title.
        case ambiguous(segment: String, context: String, count: Int)
        /// The accessibility press was refused.
        case pressFailed(segment: String, context: String)
        /// The item was pressed but no menu appeared, so the path cannot descend.
        case menuDidNotOpen(segment: String, context: String)
    }

    public let reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }

    /// Malformed paths are decided from the ARGUMENT alone (usage, exit 64);
    /// everything else is a fact about the live application (exit 1). Matches the
    /// precedence every other verb uses.
    public var exitCode: MTouchExitCode {
        switch reason {
        case .empty, .emptySegment: return .usageError
        default: return .runtimeFailure
        }
    }

    public var message: String {
        switch reason {
        case .empty:
            return "mtouch: a menu path must have at least one segment, e.g. 'File>Save'."
        case let .emptySegment(path):
            return "mtouch: '\(path)' has an empty menu segment. Use 'File>Save'; for a title that "
                + "itself contains '>', pass each title with a separate --item."
        case .menuBarUnreadable:
            return "mtouch: the application's menu bar could not be read."
        case let .notFound(segment, context, available):
            return "mtouch: no menu item titled '\(segment)' in \(context). Available: "
                + "\(MenuPathError.list(available)). Titles are matched exactly first, then "
                + "case-insensitively, and are localized — use the titles exactly as shown."
        case let .disabled(segment, context):
            return "mtouch: the menu item '\(segment)' in \(context) is disabled and cannot be "
                + "invoked right now. Nothing was invoked."
        case let .ambiguous(segment, context, count):
            return "mtouch: '\(segment)' matches \(count) items in \(context); mtouch will not guess "
                + "between them. Open the menu with 'mtouch act show-menu <ref>' and press the "
                + "intended item by reference."
        case let .pressFailed(segment, context):
            return "mtouch: the menu item '\(segment)' in \(context) refused the accessibility press. "
                + "It may have been dismissed; re-run 'mtouch snapshot' and retry."
        case let .menuDidNotOpen(segment, context):
            return "mtouch: '\(segment)' in \(context) opened no menu, so the path cannot continue. "
                + "It is a command rather than a submenu — drop the remaining segments."
        }
    }

    /// Renders available titles for a diagnostic: quoted, comma-separated, capped so
    /// a long menu cannot bury the message, with the overflow counted.
    static func list(_ titles: [String], limit: Int = 30) -> String {
        guard !titles.isEmpty else { return "(none)" }
        let shown = titles.prefix(limit).map { "'\($0)'" }.joined(separator: ", ")
        let overflow = titles.count - min(titles.count, limit)
        return overflow > 0 ? "\(shown) (+\(overflow) more)" : shown
    }
}

/// Which item at one menu level a path segment names. Pure over TITLES alone, so
/// the whole matching policy — exact before case-insensitive, ambiguity refused —
/// is table-testable with no accessibility access and no element type.
public enum MenuMatching {
    public enum Match: Equatable, Sendable {
        /// Index into the titles array.
        case matched(Int)
        case notFound
        /// How many equally-good candidates were found (always ≥ 2).
        case ambiguous(Int)
    }

    /// EXACT match first, then case-insensitive. Two tiers rather than one because
    /// menu titles are user-visible and often localized: an exact hit must never be
    /// beaten by a loose one, but an agent that reproduces `file` for `File` should
    /// still succeed. Items with no title (separators) never match. More than one
    /// candidate in a tier is ambiguous — refused, never guessed.
    public static func match(_ segment: String, in titles: [String?]) -> Match {
        let exact = titles.indices.filter { titles[$0] == segment }
        if exact.count == 1 { return .matched(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact.count) }

        let insensitive = titles.indices.filter { index in
            guard let title = titles[index], !title.isEmpty else { return false }
            return title.caseInsensitiveCompare(segment) == .orderedSame
        }
        if insensitive.count == 1 { return .matched(insensitive[0]) }
        if insensitive.count > 1 { return .ambiguous(insensitive.count) }
        return .notFound
    }
}

/// The navigable menu surface of ONE application, behind a seam so the descent
/// policy is testable against a literal menu tree — no live app, no accessibility
/// grant, and no risk of a test opening a real menu.
public protocol MenuNavigator {
    associatedtype Item

    /// Top-level menu-bar items, or nil when the menu bar cannot be read at all.
    func menuBarItems() -> [Item]?
    /// The item's title; nil for an untitled item (a separator).
    func title(of item: Item) -> String?
    /// Whether the item can be invoked now.
    func isEnabled(_ item: Item) -> Bool
    /// Press the item: opens its menu, or invokes it when it is the leaf.
    func press(_ item: Item) -> Bool
    /// The items of the menu the just-pressed item revealed, nil when none opened.
    func openedItems(of item: Item) -> [Item]?
    /// Wait (bounded) for the menus this navigator opened to disappear after the
    /// leaf was invoked.
    func awaitDismissal()
    /// Close every menu this navigator opened.
    func closeMenus()
}

/// Walks a `MenuPath` down a `MenuNavigator`, pressing each level open and
/// invoking the leaf.
///
/// The invariant that makes this safe to retry: ON EVERY FAILURE PATH, any menu
/// this walk opened is closed again before returning. A half-walked path that
/// leaves a menu hanging open wedges the application — the menu swallows every
/// subsequent click and keystroke, so one failed attempt would break every later
/// step in a session. Closing is therefore not cleanup, it is part of the contract.
public enum MenuPathResolver {
    public static func invoke<Navigator: MenuNavigator>(
        path: MenuPath,
        in navigator: Navigator
    ) -> Result<Void, MenuPathError> {
        guard var items = navigator.menuBarItems() else {
            return .failure(MenuPathError(reason: .menuBarUnreadable))
        }

        // Whether a menu is currently open BECAUSE OF THIS WALK. Only then may a
        // failure send a close: an app whose menus we never touched must not be sent
        // a stray dismissal that could cancel something else.
        var opened = false
        var context = "the menu bar"

        for (index, segment) in path.segments.enumerated() {
            let isLeaf = index == path.segments.count - 1
            let titles = items.map { navigator.title(of: $0) }

            let item: Navigator.Item
            switch MenuMatching.match(segment, in: titles) {
            case let .matched(matchIndex):
                item = items[matchIndex]
            case .notFound:
                return fail(
                    .notFound(
                        segment: segment, context: context,
                        available: titles.compactMap { $0 }.filter { !$0.isEmpty }
                    ),
                    opened: opened, navigator: navigator
                )
            case let .ambiguous(count):
                return fail(
                    .ambiguous(segment: segment, context: context, count: count),
                    opened: opened, navigator: navigator
                )
            }

            guard navigator.isEnabled(item) else {
                return fail(.disabled(segment: segment, context: context), opened: opened, navigator: navigator)
            }
            guard navigator.press(item) else {
                return fail(.pressFailed(segment: segment, context: context), opened: opened, navigator: navigator)
            }
            if isLeaf {
                // The leaf press IS the command, and macOS dismisses the menu itself
                // — but not instantly. Wait for that to happen before returning, so
                // the caller's post-action walk sees the command's EFFECT rather than
                // the menu that was on its way out. (Nothing was opened for a
                // single-segment path, so that case returns at once with its menu
                // deliberately left open.)
                navigator.awaitDismissal()
                return .success(())
            }

            opened = true
            guard let revealed = navigator.openedItems(of: item) else {
                return fail(
                    .menuDidNotOpen(segment: segment, context: context),
                    opened: opened, navigator: navigator
                )
            }
            items = revealed
            context = "menu '\(segment)'"
        }

        // Unreachable: a path has at least one segment and the last one returns.
        return .success(())
    }

    /// Invoke `path` against the LIVE menu bar of `pid`. A named factory rather than
    /// an inline default argument so the live accessibility navigator stays an
    /// internal implementation detail of the module.
    public static func invokeLive(pid: pid_t, path: MenuPath) -> Result<Void, MenuPathError> {
        invoke(path: path, in: LiveMenuNavigator(pid: pid))
    }

    private static func fail<Navigator: MenuNavigator>(
        _ reason: MenuPathError.Reason,
        opened: Bool,
        navigator: Navigator
    ) -> Result<Void, MenuPathError> {
        if opened { navigator.closeMenus() }
        return .failure(MenuPathError(reason: reason))
    }
}
