import AppKit
import Expose
import SwiftUI
import WindowKit
import Workspaces

/// The space's Mission Control (⌃↓, in place of macOS's app windows): a full-screen overlay on the screen under the pointer
/// with the current space's windows (and sticky ones) as thumbnails. They zoom out of the windows
/// when it opens; picking one focuses it and the overlay fades onto it.
///
/// Pictures are still, not live: captured in the background shortly after each switch (so
/// opening is instant), then once more after the zoom-out has finished, swapped in at once.
@MainActor
final class ExposePanel {
    let model = ExposeModel()
    private let engine: WorkspaceEngine
    private var panel: KeyPanel?
    /// The app in front before, to go back to when nothing is picked.
    private var previous: NSRunningApplication?
    private var capturing: Task<Void, Never>?
    /// The latest picture of each window, at thumbnail size.
    private var cache: [CGWindowID: CGImage] = [:]

    /// After a switch, windows settle (and get focused) before they're captured.
    static let prefetchDelay: Duration = .milliseconds(600)
    /// The fresh capture after opening waits for the zoom-out to end.
    static let refreshDelay: Duration = .milliseconds(380)

    init(engine: WorkspaceEngine) {
        self.engine = engine
        model.onPick = { [weak self] window in self?.pick(window) }
        model.onDismiss = { [weak self] in self?.dismiss(restoringFocus: true) }
        model.onAllowCapture = { [weak self] in self?.allowCapture() }
    }

    var isVisible: Bool { panel.map { $0.isVisible && !$0.isFadingOut } == true }

    /// Builds and renders the panel ahead of its first use.
    func prepare() {
        let panel = self.panel ?? makePanel()
        panel.warmUp(on: NSScreen.main)
    }

    func toggle() {
        isVisible ? dismiss(restoringFocus: true) : show()
    }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen, let main = NSScreen.screens.first else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previous : front

        let windows = engine.switcherWindows().filter { !$0.isMinimized }
        let axScreen = CGRect(x: screen.frame.minX, y: main.frame.height - screen.frame.maxY,
                              width: screen.frame.width, height: screen.frame.height)
        // Read before the overlay takes focus: the window you came from starts selected.
        let focused = engine.inventory.focusedWindowID()
        model.begin(windows, title: engine.spaces.activeSpace?.name ?? "All windows", screen: axScreen, selecting: focused)
        model.pointer.reset(at: NSEvent.mouseLocation)
        model.images = cache.filter { id, _ in windows.contains { $0.id == id } }
        model.canCapture = WindowCapture.isAllowed

        let panel = self.panel ?? makePanel()
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        // One frame on the windows, then zoom out into the grid; shadows and labels after.
        Task { @MainActor [model] in
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(.spring(duration: 0.32, bounce: 0.12)) {
                model.setExpanded(true)
            } completion: {
                model.isSettled = true
            }
        }
        capture(windows, for: screen, after: Self.refreshDelay)
    }

    /// Captures the current space's windows in the background, for the next open.
    func prefetch() {
        guard !isVisible else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        capture(engine.switcherWindows().filter { !$0.isMinimized }, for: screen, after: Self.prefetchDelay)
    }

    /// One capture of `windows` at the size their thumbnails get on `screen`, into the cache
    /// (and onto the open overlay). A newer request replaces a pending one.
    private func capture(_ windows: [WindowInfo], for screen: NSScreen, after delay: Duration) {
        capturing?.cancel()
        guard WindowCapture.isAllowed, !windows.isEmpty else { return }
        let layout = ExposeLayout.layout(windows.map(\.frame), ids: windows.map(\.id), in: ExposeView.bounds(for: screen.frame.size))
        var sizes: [CGWindowID: CGSize] = [:]
        for (window, frame) in zip(windows, layout.frames) { sizes[window.id] = frame.size }
        let scale = screen.backingScaleFactor
        capturing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let images = await WindowCapture.capture(sizes, scale: scale)
            guard let self, !Task.isCancelled else { return }
            let live = Set(engine.inventory.windows.map(\.id))
            cache = cache.filter { live.contains($0.key) }.merging(images) { _, new in new }
            if isVisible { model.images.merge(images) { _, new in new } }
        }
    }

    /// `restoringFocus`: nothing was picked, go back to the app that was in front.
    func dismiss(restoringFocus: Bool) {
        guard let panel, panel.isVisible, !panel.isFadingOut else { return }
        capturing?.cancel()
        model.isSettled = false
        withAnimation(.easeIn(duration: 0.16)) { model.setExpanded(false) }
        panel.fadeOut(duration: 0.18, shieldingClicks: !restoringFocus)
        if restoringFocus, let previous, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
    }

    private func pick(_ window: WindowInfo) {
        engine.focus(window)
        dismiss(restoringFocus: false)
    }

    /// macOS shows its prompt only once; after that, System Settings is the way.
    private func allowCapture() {
        WindowCapture.requestAccess()
        if !WindowCapture.isAllowed,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        dismiss(restoringFocus: false)
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
        panel.setBlurredContent(ExposeView(model: model))
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        panel.onResignKey = { [weak self] in self?.dismiss(restoringFocus: false) }
        self.panel = panel
        return panel
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 53: dismiss(restoringFocus: true)   // Escape
        case 36, 76: model.pick()                // Return, Enter
        case 123: model.move(.left)
        case 124: model.move(.right)
        case 125: model.move(.down)
        case 126: model.move(.up)
        default: return false
        }
        return true
    }
}
