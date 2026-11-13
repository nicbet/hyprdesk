import CoreGraphics

/// Which macOS desktop HyprDesk is on. Accessibility only lists the current desktop's windows,
/// so after a desktop change HyprDesk checks whether its own windows are still on screen: if
/// most of them aren't, the user is on another desktop, and its listing must be ignored.
public enum Desktop {
    /// The windows on screen on the current desktop (parked ones count: a sliver stays on screen).
    public static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// Whether the lock screen is up. While it is, Accessibility lists no windows at all, yet the
    /// window server still counts them on screen behind it: neither listing can be believed.
    public static func isScreenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Whether the desktop on screen is the one holding `home` (the windows HyprDesk knew
    /// there, minimized ones left out: they're never on screen). At least half of them must be
    /// on screen: windows assigned to every desktop show everywhere, so one isn't enough. With
    /// no windows known, any desktop is home.
    public static func isHome(_ home: Set<CGWindowID>, onScreen: Set<CGWindowID>) -> Bool {
        guard !home.isEmpty else { return true }
        return home.intersection(onScreen).count * 2 >= home.count
    }
}
