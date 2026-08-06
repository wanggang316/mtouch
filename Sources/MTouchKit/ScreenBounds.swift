import CoreGraphics

/// Off-screen coordinate detection for the coordinate `act` verbs.
///
/// A coordinate that falls outside every display is a runtime failure (exit 1)
/// that MUST be rejected BEFORE any event is posted — the check is pure over a
/// list of display rects, so the validation is unit-testable without a live
/// display, and the live seam only supplies the rects.
///
/// Rects are in the GLOBAL display coordinate space (`CGDisplayBounds`): top-left
/// origin, y growing downward from the top-left of the main display — the SAME
/// convention as AX frames and snapshot `frame`, so a point derived from a
/// snapshot compares directly.
public enum ScreenBounds {
    /// Whether `point` lies within any of `displays`. A point exactly on a
    /// display's right/bottom edge is treated as inside (edges are inclusive), so
    /// a coordinate landing on the last row/column of a screen is not spuriously
    /// rejected as off-screen.
    public static func contains(_ point: ScreenPoint, in displays: [CGRect]) -> Bool {
        displays.contains { rect in
            point.x >= rect.minX && point.x <= rect.maxX
                && point.y >= rect.minY && point.y <= rect.maxY
        }
    }

    /// Live check against the active displays. When the display list cannot be
    /// read (no active displays / API failure) the check DEGRADES to the main
    /// display bounds so a normal on-screen coordinate is never wrongly rejected.
    public static func isOnScreen(_ point: ScreenPoint) -> Bool {
        contains(point, in: activeDisplayBounds())
    }

    /// Bounds of every active display, or the main display alone as a fallback.
    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return mainDisplayFallback()
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return mainDisplayFallback()
        }
        let bounds = ids.prefix(Int(count)).map(CGDisplayBounds)
        return bounds.isEmpty ? mainDisplayFallback() : bounds
    }

    private static func mainDisplayFallback() -> [CGRect] {
        [CGDisplayBounds(CGMainDisplayID())]
    }
}
