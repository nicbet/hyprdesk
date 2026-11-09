import CoreGraphics

/// The window server's stacking order, frontmost first. Window IDs and order need no Screen
/// Recording permission (only titles and images would).
public enum WindowOrder {
    /// Window ID → position, 0 frontmost. Windows on other Spaces and minimized ones follow the
    /// on-screen ones.
    /// The on-screen list is the one in stacking order; the full list isn't (a window in front
    /// can come a hundred places after one behind it), so it only adds the windows that aren't on
    /// screen, after them.
    public static func current() -> [CGWindowID: Int] {
        var order: [CGWindowID: Int] = [:]
        for options: CGWindowListOption in [[.optionOnScreenOnly, .excludeDesktopElements], [.excludeDesktopElements]] {
            guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { continue }
            for info in list {
                if let id = info[kCGWindowNumber as String] as? CGWindowID, order[id] == nil { order[id] = order.count }
            }
        }
        return order
    }

    /// `windows` frontmost first; unknown windows last, in their given order.
    public static func sorted(_ windows: [WindowInfo], by order: [CGWindowID: Int]) -> [WindowInfo] {
        windows.enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }
}
