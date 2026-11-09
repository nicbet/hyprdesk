import AppKit
import SwiftUI
import Switcher
import Workspaces

/// ⌘Tab for the current space: the key tap takes ⌘Tab before the Dock does (as AltTab does) and
/// offers the space's windows, most recent first.
/// Hold ⌘ and press Tab to move on (⇧Tab, ← → back and forth), release ⌘ to switch, Esc to
/// cancel. A quick tap switches to the previous window without showing anything.
@MainActor
final class SpaceSwitcher {
    let model = SwitcherModel()
    private let engine: WorkspaceEngine
    private var panel: NSPanel?
    private var showing: Task<Void, Never>?

    /// The panel waits this long, so a quick ⌘Tab doesn't flash it.
    static let showDelay: Duration = .milliseconds(130)

    init(engine: WorkspaceEngine, keys: KeyTap, isEnabled: @escaping @MainActor () -> Bool) {
        self.engine = engine
        self.isEnabled = isEnabled
        keys.add { [weak self] type, keyCode, flags in
            self?.handle(type, keyCode: keyCode, flags: flags) ?? false
        }
    }

    /// Off: macOS's own ⌘Tab. Checked on every key, so turning it off takes effect at once.
    private let isEnabled: @MainActor () -> Bool

    // MARK: Keys

    /// True: swallow the event (it was ours).
    private func handle(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard isEnabled() else {
            if model.isActive { cancel() }
            return false
        }
        switch type {
        case .keyDown:
            let isCommandTab = keyCode == Key.tab && flags.contains(.maskCommand)
                && !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
            if isCommandTab {
                if model.isActive {
                    flags.contains(.maskShift) ? model.previous() : model.next()
                } else {
                    begin(backwards: flags.contains(.maskShift))
                }
                return true
            }
            guard model.isActive else { return false }
            switch keyCode {
            case Key.escape: cancel()
            case Key.returnKey: commit()
            case Key.left, Key.grave: model.previous()
            case Key.right: model.next()
            default: break
            }
            // While it's up, keys belong to the switcher (⌘Q mustn't quit the app underneath).
            return true
        case .keyUp:
            return model.isActive && keyCode == Key.tab
        case .flagsChanged:
            if model.isActive && !flags.contains(.maskCommand) { commit() }
            return false
        default:
            return false
        }
    }

    private enum Key {
        static let tab: Int64 = 48, escape: Int64 = 53, returnKey: Int64 = 36
        static let left: Int64 = 123, right: Int64 = 124, grave: Int64 = 50
    }

    // MARK: Round

    private func begin(backwards: Bool) {
        model.begin(engine.switcherWindows(), title: engine.spaces.activeSpace?.name ?? "All windows", pointer: NSEvent.mouseLocation)
        if backwards { model.previous(); model.previous() }
        showing = Task { [weak self] in
            try? await Task.sleep(for: Self.showDelay)
            guard let self, !Task.isCancelled, model.isActive else { return }
            show()
        }
    }

    private func commit() {
        let window = model.commit()
        hide()
        if let window { engine.focus(window) }
    }

    private func cancel() {
        model.cancel()
        hide()
    }

    // MARK: Panel

    private func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let panel = self.panel ?? makePanel()
        model.maxWidth = frame.width * 0.9
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                       display: false)
        panel.orderFrontRegardless()
    }

    private func hide() {
        showing?.cancel()
        showing = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Built once: a new hosting view per ⌘Tab costs a visible moment.
        panel.contentView = NSHostingView(rootView: SwitcherView(model: model) { [weak self] index in
            self?.model.select(index)
            self?.commit()
        })
        self.panel = panel
        return panel
    }

    /// Builds the panel ahead of its first use.
    func prepare() {
        _ = panel ?? makePanel()
        panel?.contentView?.layoutSubtreeIfNeeded()
    }

    /// For the benchmark: a round shown at once, and its end.
    func benchShow() {
        model.begin(engine.switcherWindows(), title: engine.spaces.activeSpace?.name ?? "All windows", pointer: NSEvent.mouseLocation)
        show()
    }

    func benchHide() {
        cancel()
    }
}
