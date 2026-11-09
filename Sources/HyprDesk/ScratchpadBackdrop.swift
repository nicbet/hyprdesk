import AppKit
import WindowKit

/// The dimmed layer between the workspace and the scratchpad while the scratchpad is up, as in
/// Hyprland: one per screen, at the level of ordinary windows.
///
/// It shows a picture of each screen taken just before the scratchpad came up, dimmed. Bringing
/// an app forward brings all of its windows (the workspace's Ghostty along with the scratchpad's),
/// so what's really behind can shuffle; the picture keeps showing the workspace as you left it.
/// Without Screen Recording it's a plain dim. `layer(below:)` slips it right under the
/// scratchpad's windows in the window server's stack, after every activation settles. A click
/// on it puts the scratchpad away.
@MainActor
final class ScratchpadBackdrop {
    private var panels: [NSPanel] = []
    private let onClick: () -> Void

    static let dim: CGFloat = 0.45
    static let fade: TimeInterval = 0.15
    /// Going away quicker than coming: it's over the moment the scratchpad's windows are gone.
    static let fadeOutDuration: TimeInterval = 0.1

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
    }

    /// `pictures`: each screen as it looked, by display ID; screens without one get a plain dim.
    func show(pictures: [CGDirectDisplayID: CGImage] = [:]) {
        for panel in panels { panel.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return makePanel(for: screen, picture: id.flatMap { pictures[$0] })
        }
        for panel in panels {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            for panel in panels { panel.animator().alphaValue = 1 }
        }
    }

    var isShown: Bool { !panels.isEmpty }

    /// Just under the backmost of `windows` (the scratchpad's): everything behind that is dimmed,
    /// whatever came forward with it.
    func layer(below windows: [CGWindowID]) {
        let order = WindowOrder.current()
        guard isShown, let backmost = windows.filter({ order[$0] != nil }).max(by: { order[$0]! < order[$1]! }) else { return }
        for panel in panels { panel.order(.below, relativeTo: Int(backmost)) }
    }

    func hide() {
        let leaving = panels
        panels = []
        Self.fadeOut(leaving)
    }

    private static func fadeOut(_ leaving: [NSPanel]) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeOutDuration
            for panel in leaving { panel.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated { for panel in leaving { panel.orderOut(nil) } }
        }
    }

    private func makePanel(for screen: NSScreen, picture: CGImage?) -> NSPanel {
        let panel = BackdropPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.onClick = onClick
        panel.level = .normal
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        panel.hasShadow = false
        if let picture {
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contents = picture
            view.layer?.contentsGravity = .resize
            let shade = CALayer()
            shade.frame = view.bounds
            shade.backgroundColor = NSColor.black.withAlphaComponent(Self.dim).cgColor
            shade.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(shade)
            panel.contentView = view
            panel.isOpaque = true
            panel.backgroundColor = .black
        } else {
            panel.isOpaque = false
            panel.backgroundColor = NSColor.black.withAlphaComponent(Self.dim)
        }
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setFrame(screen.frame, display: false)
        return panel
    }
}

/// Takes clicks without taking focus.
private final class BackdropPanel: NSPanel {
    var onClick: () -> Void = {}

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }
}
