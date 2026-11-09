import CoreGraphics
import WindowKit

/// The switcher's order: most recently focused first, then the stacking order (frontmost first),
/// minimized windows last.
public enum SwitcherOrder {
    public static func ordered(_ windows: [WindowInfo], recent: [CGWindowID], fallback: [CGWindowID: Int]) -> [WindowInfo] {
        let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return windows.enumerated().sorted { a, b in
            let keyA = (a.element.isMinimized ? 1 : 0, rank[a.element.id] ?? Int.max, fallback[a.element.id] ?? Int.max, a.offset)
            let keyB = (b.element.isMinimized ? 1 : 0, rank[b.element.id] ?? Int.max, fallback[b.element.id] ?? Int.max, b.offset)
            return keyA < keyB
        }.map(\.element)
    }
}
