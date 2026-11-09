import AppKit
import Overview
import SwiftUI

/// Flashes the space's name after a switch, centered near the bottom of the screen under the
/// pointer (above the Dock).
/// Takes no clicks and no focus; switching again while it's up just updates it.
@MainActor
final class NameTagPanel {
    let model = SpaceNameTagModel()
    private var panel: NSPanel?
    private var hiding: Task<Void, Never>?

    static let visibleFor: Duration = .milliseconds(800)
    /// Above the bottom of the screen (or the Dock).
    static let bottomGap: CGFloat = 56
    static let fadeOut: TimeInterval = 0.25

    func show(name: String, index: Int, count: Int) {
        model.name = name
        model.index = index
        model.count = count
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? makePanel()
        let size = SpaceNameTag.size
        // Centered, a little up from the bottom (the visible frame stops above the Dock).
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + Self.bottomGap,
                              width: size.width, height: size.height), display: false)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        hiding?.cancel()
        hiding = Task { @MainActor [weak panel] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled, let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeOut
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
            }
        }
    }

    /// Builds the panel ahead of its first use.
    func prepare() {
        _ = panel ?? makePanel()
        panel?.contentView?.layoutSubtreeIfNeeded()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // The window server's HUD blur, rounded.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: SpaceNameTag(model: model))
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        let container = TagContainer(blur: blur, hosting: hosting)
        panel.contentView = container
        self.panel = panel
        return panel
    }
}

/// Holds the blur with the tag on it, both filling the panel.
private final class TagContainer: NSView {
    private let blur: NSVisualEffectView
    private let hosting: NSView

    init(blur: NSVisualEffectView, hosting: NSView) {
        self.blur = blur
        self.hosting = hosting
        super.init(frame: .zero)
        addSubview(blur)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        blur.frame = bounds
        hosting.frame = blur.bounds
    }
}
