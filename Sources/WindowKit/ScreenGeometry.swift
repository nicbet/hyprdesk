import AppKit

/// Screens in Accessibility coordinates (origin top left of the main screen, y down), and where
/// to park a window so it's out of sight.
public enum ScreenGeometry {
    /// Every screen's frame, Accessibility coordinates.
    @MainActor
    public static func screens() -> [CGRect] {
        guard let main = NSScreen.screens.first else { return [] }
        let height = main.frame.height
        return NSScreen.screens.map { CGRect(x: $0.frame.minX, y: height - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    }

    /// Every screen's usable area (without the menu bar and the Dock), Accessibility coordinates,
    /// in the same order as `screens()`.
    @MainActor
    public static func visibleScreens() -> [CGRect] {
        guard let main = NSScreen.screens.first else { return [] }
        let height = main.frame.height
        return NSScreen.screens.map {
            CGRect(x: $0.visibleFrame.minX, y: height - $0.visibleFrame.maxY, width: $0.visibleFrame.width, height: $0.visibleFrame.height)
        }
    }

    /// How much of the usable screen a scratchpad window may take.
    public static let scratchpadScale: CGFloat = 0.8

    /// Where a scratchpad window shows (Hyprland's special workspace sits inset over the others):
    /// fitted into `scratchpadScale` of `visible`, keeping its proportions, and centered.
    public static func scratchpadFrame(for size: CGSize, in visible: CGRect) -> CGRect {
        let box = CGSize(width: visible.width * scratchpadScale, height: visible.height * scratchpadScale)
        let fit = min(1, box.width / max(1, size.width), box.height / max(1, size.height))
        let fitted = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        return CGRect(x: (visible.midX - fitted.width / 2).rounded(), y: (visible.midY - fitted.height / 2).rounded(),
                      width: fitted.width, height: fitted.height)
    }

    /// The screen holding `frame`'s center, else the one it overlaps most, else the first.
    public static func screen(for frame: CGRect, in screens: [CGRect]) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let screen = screens.first(where: { $0.contains(center) }) { return screen }
        return screens.max { overlap($0, frame) < overlap($1, frame) } ?? screens.first
    }

    /// How much of the window stays on screen when parked: macOS won't let a window leave the
    /// screens entirely.
    public static let parkedSliver: CGFloat = 1

    /// Where to move a window of `frame`'s size so it's out of sight: just past the bottom-right
    /// corner of its screen, or the bottom-left one when another screen sits to the right (the
    /// window would show up there). Bottom corners, because a screen above would show it too.
    public static func parkingOrigin(for frame: CGRect, in screens: [CGRect]) -> CGPoint {
        guard let screen = screen(for: frame, in: screens) else { return CGPoint(x: frame.minX, y: frame.minY) }
        let others = screens.filter { $0 != screen }
        let corners = [
            CGPoint(x: screen.maxX - parkedSliver, y: screen.maxY - parkedSliver),               // bottom right
            CGPoint(x: screen.minX - frame.width + parkedSliver, y: screen.maxY - parkedSliver), // bottom left
        ]
        return corners.first { origin in
            let parked = CGRect(origin: origin, size: frame.size)
            return !others.contains { $0.intersects(parked) }
        } ?? corners[0]
    }

    /// Whether so little of `frame` is on any screen that the user couldn't see or grab it: under
    /// a quarter of its area, or a sliver under 100 × 60 pt. A parked window is; a window a
    /// user can work with never is. (macOS clamps where a window may go, so a parked window may
    /// not sit exactly where it was sent: never compare to `parkingOrigin`.)
    public static func isMostlyOffscreen(_ frame: CGRect, in screens: [CGRect]) -> Bool {
        guard frame.width > 0, frame.height > 0, !screens.isEmpty else { return false }
        var area: CGFloat = 0
        var widest: CGFloat = 0
        var tallest: CGFloat = 0
        for screen in screens {
            let visible = screen.intersection(frame)
            guard !visible.isNull else { continue }
            area += visible.width * visible.height
            widest = max(widest, visible.width)
            tallest = max(tallest, visible.height)
        }
        return area < frame.width * frame.height / 4 || widest < 100 || tallest < 60
    }

    /// `frame` if the user can see it; otherwise the same size (shrunk to fit), centered on the
    /// screen it's nearest to. For frames that must never be restored to a hidden spot.
    public static func onScreen(_ frame: CGRect, in screens: [CGRect]) -> CGRect {
        guard isMostlyOffscreen(frame, in: screens) else { return frame }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let distance = { (screen: CGRect) in hypot(screen.midX - center.x, screen.midY - center.y) }
        guard let screen = screens.min(by: { distance($0) < distance($1) }) else { return frame }
        let size = CGSize(width: min(frame.width, screen.width * 0.9), height: min(frame.height, screen.height * 0.9))
        return CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
