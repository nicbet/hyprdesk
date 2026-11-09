import AppKit

/// The menu-bar item: HyprDesk's mark (a squircle holding ✦, as on the app icon) and, beside it,
/// the current workspace's number, centered on the mark. One template image, so macOS tints it
/// like every other menu-bar icon (and dims it while suspended).
@MainActor
enum MenuBarIcon {
    /// About the size of the system's own menu-bar icons.
    static let height: CGFloat = 18
    static let mark: CGFloat = 15
    static let gap: CGFloat = 4
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    static func image(number: Int?) -> NSImage {
        let text = number.map { NSAttributedString(string: "\($0)", attributes: [.font: font, .foregroundColor: NSColor.black]) }
        let textWidth = text.map { ceil($0.size().width) } ?? 0
        let width = mark + (text == nil ? 0 : gap + textWidth)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            drawMark(in: NSRect(x: 0, y: (height - mark) / 2, width: mark, height: mark))
            if let text {
                // Digits are cap height tall: put their middle on the mark's middle.
                let baseline = (height - font.capHeight) / 2
                text.draw(at: NSPoint(x: mark + gap, y: baseline + font.descender))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = number.map { "\(HyprDesk.name), workspace \($0)" } ?? HyprDesk.name
        return image
    }

    /// The squircle outline with a four-pointed star cut from its middle.
    private static func drawMark(in rect: NSRect) {
        NSColor.black.set()
        let line: CGFloat = 1.5
        let body = rect.insetBy(dx: line / 2, dy: line / 2)
        let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.3, yRadius: body.height * 0.3)
        squircle.lineWidth = line
        squircle.stroke()

        // ✦: four points, the sides curving in toward the middle.
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let r = rect.width * 0.3
        let pinch = r * 0.18
        let star = NSBezierPath()
        let points = [NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x + r, y: c.y), NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x - r, y: c.y)]
        let inner = [NSPoint(x: c.x + pinch, y: c.y + pinch), NSPoint(x: c.x + pinch, y: c.y - pinch),
                     NSPoint(x: c.x - pinch, y: c.y - pinch), NSPoint(x: c.x - pinch, y: c.y + pinch)]
        star.move(to: points[0])
        for i in 0..<4 {
            star.curve(to: points[(i + 1) % 4], controlPoint1: inner[i], controlPoint2: inner[i])
        }
        star.close()
        star.fill()
    }
}
