import AppKit
import Overview
import SwiftUI

/// The full-screen overlay hosting `OverviewView` on the screen under the pointer. Takes the
/// keyboard while it's up: arrows, 1–9, Return, Escape.
@MainActor
final class OverviewPanel {
    let model: OverviewModel
    private var panel: KeyPanel?
    /// The app that was in front before the overview, to go back to when it's dismissed.
    private var previous: NSRunningApplication?

    var isVisible: Bool { panel.map { $0.isVisible && !$0.isFadingOut } == true }

    init(model: OverviewModel) {
        self.model = model
    }

    /// Builds and renders the panel ahead of its first use.
    func prepare() {
        let panel = self.panel ?? makePanel()
        model.reset()
        panel.warmUp(on: NSScreen.main)
    }

    func toggle() {
        isVisible ? dismiss(restoringFocus: true) : show()
    }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? makePanel()
        let front = NSWorkspace.shared.frontmostApplication
        previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previous : front
        model.reset()
        model.pointer.reset(at: NSEvent.mouseLocation)
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        // Active, so raising a window can hand activation over to its app (macOS 14+).
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Hides the overlay. `restoringFocus`: nothing was opened, so go back to the previous app.
    func dismiss(restoringFocus: Bool) {
        guard let panel, panel.isVisible, !panel.isFadingOut else { return }
        panel.fadeOut(duration: 0.1, shieldingClicks: !restoringFocus)
        if restoringFocus, let previous, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setBlurredContent(OverviewView(model: model))
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        // Another app came forward (a switch, a click elsewhere): get out of the way.
        panel.onResignKey = { [weak self] in self?.dismiss(restoringFocus: false) }
        self.panel = panel
        return panel
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 53: dismiss(restoringFocus: true)          // Escape
        case 36, 76: model.activate()                   // Return, Enter
        case 123: model.move(.left)
        case 124: model.move(.right)
        case 125: model.move(.down)
        case 126: model.move(.up)
        default:
            guard let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) else { return false }
            model.activateWorkspace(number: digit)
        }
        return true
    }
}

extension KeyPanel {
    /// `root` over the window server's blur of whatever is behind the panel: blurring there is
    /// far cheaper than a SwiftUI material, and it fades with the panel for free.
    func setBlurredContent<Content: View>(_ root: Content) {
        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        let hosting = NSHostingView(rootView: root)
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        contentView = blur
    }

    /// Renders the panel once, invisibly, so the first real opening doesn't pay for building
    /// the view (about 100 ms otherwise).
    func warmUp(on screen: NSScreen?) {
        guard let screen else { return }
        setFrame(screen.frame, display: false)
        alphaValue = 0
        ignoresMouseEvents = true
        orderFrontRegardless()
        contentView?.layoutSubtreeIfNeeded()
        display()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
                self.ignoresMouseEvents = false
            }
        }
    }
}

/// A borderless full-screen overlay that takes the keyboard and every click, even where it's
/// see-through: a click falling through would land on a window underneath (a double-click on a
/// title bar makes that window fill the screen).
final class KeyPanel: NSPanel {
    var onKey: (NSEvent) -> Bool = { _ in false }
    var onResignKey: () -> Void = {}

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        // Set explicitly, a window gets clicks even in transparent areas.
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    /// Fades out, still catching clicks (and doing nothing with them) until the double-click
    /// interval has passed, so the second click of a double-click can't reach the window below.
    func fadeOut(duration: TimeInterval, shieldingClicks: Bool) {
        isFadingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            animator().alphaValue = 0
        }
        let linger = shieldingClicks ? max(duration, NSEvent.doubleClickInterval) : duration
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isFadingOut else { return }
                self.orderOut(nil)
                self.isFadingOut = false
            }
        }
    }

    /// Between a pick and being gone: clicks are swallowed.
    private(set) var isFadingOut = false

    override func makeKeyAndOrderFront(_ sender: Any?) {
        isFadingOut = false
        ignoresMouseEvents = false
        super.makeKeyAndOrderFront(sender)
    }

    override func sendEvent(_ event: NSEvent) {
        if isFadingOut, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type) {
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}
