import AppKit
import Control
import OSLog
import Overview
import Spaces
import SwiftUI
import WindowKit
import Workspaces

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let inventory = WindowInventory()
    private let spaces = SpaceStore()
    private lazy var engine = WorkspaceEngine(inventory: inventory, spaces: spaces)
    private let keys = KeyTap()
    private let preferences = Preferences()
    private lazy var switcher = SpaceSwitcher(engine: engine, keys: keys) { [weak self] in
        guard let self else { return false }
        return preferences.replacesCommandTab && !handsOff
    }

    /// Suspended, or on another macOS desktop: our shortcuts and key overrides step aside, and
    /// ⌘Tab and the ⌃-arrows are macOS's.
    private var handsOff: Bool { preferences.isSuspended || engine.isAway }
    private lazy var expose = ExposePanel(engine: engine)
    private let nameTag = NameTagPanel()
    private var signalSources: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem?
    private var manageWindow: NSWindow?
    private lazy var overview = OverviewPanel(model: makeOverviewModel())
    private lazy var search = SearchPanel(engine: engine)
    private lazy var backdrop = ScratchpadBackdrop { [weak self] in self?.engine.setScratchpad(shown: false) }
    private lazy var commands = Commands(engine: engine, search: search, isHandsOff: { [weak self] in self?.handsOff ?? true }) { [weak self] in
        self?.overview.dismiss(restoringFocus: false)
        self?.expose.dismiss(restoringFocus: false)
        self?.search.dismiss(restoringFocus: false)
    }
    /// `hyprdesk <command>` reaches the app here.
    private var control: ControlServer?
    /// What `hyprdesk subscribe` hears about.
    private lazy var events = EventFeed(engine: engine, isHandsOff: { [weak self] in self?.handsOff ?? true })
    private static let log = Logger(subsystem: "com.github.nicbet.hyprdesk", category: "control")
    private var hotKeys: [HotKey] = []
    private let accessItem = NSMenuItem(title: "Allow Accessibility…", action: #selector(requestAccess), keyEquivalent: "")
    private let suspendItem = NSMenuItem(title: "Suspend HyprDesk", action: #selector(toggleSuspended), keyEquivalent: "")
    private let cliItem = NSMenuItem(title: "Install Command Line Tool…", action: #selector(toggleCLI), keyEquivalent: "")
    /// The ⌃-arrow presses we took, so their key-ups are swallowed too.
    private var tookArrows: Set<Int64> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onSwitch = { [weak self] id in
            guard let self else { return }
            if let index = spaces.spaces.firstIndex(where: { $0.id == id }) {
                nameTag.show(name: spaces.spaces[index].name, index: index, count: spaces.spaces.count)
            }
            expose.prefetch()
        }
        // ✦ S: picture the screens first, while the workspace is untouched; the backdrop shows
        // them dimmed. A slow capture never holds the scratchpad up for long.
        engine.prepareScratchpad = { [weak self] done in
            guard let self else { return done() }
            let start = ContinuousClock.now
            var finished = false
            let finish: @MainActor ([CGDirectDisplayID: CGImage]) -> Void = { [weak self] pictures in
                guard !finished else { return }
                finished = true
                self?.backdrop.show(pictures: pictures)
                Self.log.info("scratchpad backdrop: \(pictures.count) screens pictured in \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds], width: .narrow)), privacy: .public)")
                done()
            }
            Task { @MainActor in finish(await WindowCapture.captureDisplays()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { finish([:]) } }
        }
        engine.onScratchpad = { [weak self] shown in
            guard let self else { return }
            if shown {
                if !backdrop.isShown { backdrop.show() }
                layerBackdrop()
            } else {
                backdrop.hide()
            }
        }
        engine.onFocus = { [weak self] in
            guard let self else { return }
            events.update()
            guard backdrop.isShown else { return }
            layerBackdrop()
        }
        engine.start()
        inventory.start()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.expose.prefetch()
        }
        restoreWindowsOnSignals()
        statusItem = makeStatusItem()
        observeStatusItem()
        registerHotKeys()
        startControl()
        // Build the overlays now, so their first opening isn't slow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.expose.prepare()
                self?.overview.prepare()
                self?.switcher.prepare()
                self?.nameTag.prepare()
            }
        }
        _ = switcher
        keys.add { [weak self] type, keyCode, flags in
            self?.handleControlArrow(type, keyCode: keyCode, flags: flags) ?? false
        }
        startKeyTap()
        if CommandLine.arguments.contains("--overview") { overview.show() }
        if CommandLine.arguments.contains("--bench") {
            Task { @MainActor [self] in
                try? await Task.sleep(for: .seconds(4))  // listed, thumbnails captured
                await Bench.run([
                    ("expose", { self.expose.show() }, { self.expose.dismiss(restoringFocus: true) }),
                    ("overview", { self.overview.show() }, { self.overview.dismiss(restoringFocus: true) }),
                    ("switcher", { self.switcher.benchShow() }, { self.switcher.benchHide() }),
                ])
            }
        }
        if !inventory.isTrusted || CommandLine.arguments.contains("--manage") { showManageWindow() }
        // Dev tool: `--snapshot-search <file> [query]` renders the window search (real windows) to a PNG.
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-search"), let path = CommandLine.arguments.dropFirst(flag + 1).first {
            let query = CommandLine.arguments.dropFirst(flag + 2).first
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    self?.search.show(query: query)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        MainActor.assumeIsolated {
                            self?.search.snapshot(to: URL(fileURLWithPath: path))
                            self?.search.dismiss(restoringFocus: true)
                        }
                    }
                }
            }
        }
        // Dev tool: `--snapshot-manage <file>` renders the Manage window (real data) to a PNG.
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-manage"), let path = CommandLine.arguments.dropFirst(flag + 1).first {
            showManageWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let view = self?.manageWindow?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
        if preferences.hyperKey != .off { HyperKey.remove() }
        keys.stop()
        engine.stop()
        inventory.stop()
    }

    /// `pkill` and Ctrl-C skip `applicationWillTerminate`; parked windows must come back anyway.
    private func restoreWindowsOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    if self?.preferences.hyperKey != .off { HyperKey.remove() }
                    self?.engine.stop()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Hyper + 1–9: that workspace. Hyper + ⇧ + 1–9: the focused window goes there, and you with it.
    /// Hyper + `: the previous workspace. (The overview and Mission Control are ⌃↑ and ⌃↓,
    /// through the key tap.)
    private func registerHotKeys() {
        hotKeys = []
        for (index, key) in HotKey.digits.enumerated() {
            hotKeys += [HotKey.register(hyperShift: false, key) { [weak self] in self?.switchToSpace(at: index) }].compactMap { $0 }
            hotKeys += [HotKey.register(hyperShift: true, key) { [weak self] in self?.moveFocusedWindow(toSpaceAt: index) }].compactMap { $0 }
        }
        hotKeys += HotKey.registerHyper(HotKey.grave) { [weak self] in
            guard let self, !handsOff else { return }
            engine.switchToPrevious()
        }
        // ✦ S: the scratchpad over this workspace, or away. ✦ ⇧ S: the focused window in or out.
        hotKeys += [HotKey.register(hyperShift: false, HotKey.s) { [weak self] in
            guard let self, !handsOff else { return }
            overview.dismiss(restoringFocus: false)
            engine.toggleScratchpad()
        }].compactMap { $0 }
        hotKeys += [HotKey.register(hyperShift: true, HotKey.s) { [weak self] in
            guard let self, !handsOff else { return }
            engine.toggleFocusedWindowInScratchpad()
        }].compactMap { $0 }
        // ✦ Space: find any window.
        hotKeys += [HotKey.register(hyperShift: false, HotKey.space) { [weak self] in
            guard let self, !handsOff else { return }
            overview.dismiss(restoringFocus: false)
            expose.dismiss(restoringFocus: false)
            search.toggle()
        }].compactMap { $0 }
    }

    /// The backdrop under the scratchpad's windows, again as each app finishes coming forward
    /// (activation is asynchronous: an app's other windows can arrive a moment later).
    private func layerBackdrop() {
        for delay in [0.0, 0.08, 0.25, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.spaces.isScratchpadShown else { return }
                    self.backdrop.layer(below: self.engine.scratchpadWindows.map(\.id))
                }
            }
        }
    }

    // MARK: Command line and links

    /// Listens for `hyprdesk <command>` (see `Commands`).
    private func startControl() {
        let server = ControlServer { [weak self] args in
            await MainActor.run { self?.commands.run(args) ?? .failure("HyprDesk is quitting") }
        }
        do {
            try server.start()
            control = server
            events.send = { [weak server] in server?.broadcast($0) }
            events.start()
        } catch {
            Self.log.error("command line unavailable: \(error.description, privacy: .public)")
        }
    }

    /// `hyprdesk://switch/2` and friends: the same commands as the command line.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                let answer = commands.run(try Command.parse(url: url))
                if answer["ok"] == false { NSSound.beep() }
                Self.log.info("\(url.absoluteString, privacy: .public): \(String(decoding: answer.encoded(), as: UTF8.self), privacy: .public)")
            } catch {
                NSSound.beep()
                Self.log.error("\(url.absoluteString, privacy: .public): \(error.description, privacy: .public)")
            }
        }
    }

    /// The key tap needs Accessibility; until it's allowed, keep trying.
    private func startKeyTap() {
        preferences.onHyperKeyChange = { [weak self] in self?.applyHyperKey() }
        guard !keys.start() else { return applyHyperKey() }
        Task { @MainActor [weak self] in
            while let self, !keys.isRunning {
                try? await Task.sleep(for: .seconds(2))
                if keys.start() { applyHyperKey() }
            }
        }
    }

    /// The hyper key per the setting. Only with the key tap running: without it, the remapped key
    /// would arrive as a plain F18 and do nothing.
    private func applyHyperKey() {
        guard keys.isRunning else { return }
        keys.hyperEnabled = preferences.hyperKey != .off
        preferences.hyperKey.apply()
    }

    /// macOS's ⌃-arrow shortcuts, ours instead while we run: ⌃↑ opens the overview of all
    /// workspaces (macOS: Mission Control), ⌃↓ the workspace's Mission Control (macOS: the app's
    /// windows), ⌃← ⌃→ switch to the previous and next workspace (macOS: desktops).
    /// Only plain ⌃: with ⇧, ⌥ or ⌘ it's someone else's shortcut. Trackpad gestures and the
    /// Mission Control key don't come through here and still do macOS's thing.
    private func handleControlArrow(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
        guard [left, right, down, up].contains(keyCode) else { return false }
        if type == .keyUp, tookArrows.contains(keyCode) {
            tookArrows.remove(keyCode)
            return true
        }
        guard type == .keyDown, !handsOff, flags.contains(.maskControl),
              !flags.contains(.maskCommand), !flags.contains(.maskAlternate), !flags.contains(.maskShift) else { return false }
        switch keyCode {
        case up where preferences.replacesMissionControl:
            expose.dismiss(restoringFocus: false)
            overview.toggle()
        case down where preferences.replacesMissionControl:
            overview.dismiss(restoringFocus: false)
            expose.toggle()
        // Past either end, the key goes on to macOS: on to the next desktop and back.
        case left where preferences.replacesSpaceArrows:
            guard switchToAdjacentSpace(-1) else { return false }
        case right where preferences.replacesSpaceArrows:
            guard switchToAdjacentSpace(1) else { return false }
        default:
            return false
        }
        tookArrows.insert(keyCode)
        return true
    }

    /// The workspace `step` places from the current one in the list. False past either end
    /// (nothing to switch to there).
    private func switchToAdjacentSpace(_ step: Int) -> Bool {
        guard let current = spaces.spaces.firstIndex(where: { $0.id == spaces.activeSpaceID }) else {
            switchToSpace(at: 0)
            return !spaces.spaces.isEmpty
        }
        let target = current + step
        guard spaces.spaces.indices.contains(target) else { return false }
        switchToSpace(at: target)
        return true
    }

    private func switchToSpace(at index: Int) {
        guard !handsOff, spaces.spaces.indices.contains(index) else { return }
        overview.dismiss(restoringFocus: false)
        engine.switchTo(spaces.spaces[index].id)
    }

    private func moveFocusedWindow(toSpaceAt index: Int) {
        guard !handsOff, spaces.spaces.indices.contains(index) else { return }
        overview.dismiss(restoringFocus: false)
        engine.moveFocusedWindow(to: spaces.spaces[index].id)
    }

    // MARK: Menu

    /// The version, Manage Workspaces, the command line tool, Suspend and Quit. Everything else has a shortcut, and
    /// the shortcuts are listed in the Manage window.
    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image(number: nil)
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        let title = NSMenuItem(title: "\(HyprDesk.name) \(HyprDesk.version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        accessItem.target = self
        menu.addItem(accessItem)
        // No ⌘, : HyprDesk is never the frontmost app, so the menu's key equivalent never fires.
        menu.addItem(menuItem("Manage Workspaces…", action: #selector(showManageWindow)))
        cliItem.target = self
        menu.addItem(cliItem)
        menu.addItem(.separator())
        suspendItem.target = self
        suspendItem.toolTip = "Every window back on screen, and macOS's own ⌘Tab, Mission Control and desktops, until you resume."
        menu.addItem(suspendItem)
        menu.addItem(NSMenuItem(title: "Quit \(HyprDesk.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        return item
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// The current workspace's number next to the icon, kept up to date through switches,
    /// reordering, adding and deleting.
    private func observeStatusItem() {
        withObservationTracking {
            let index = spaces.spaces.firstIndex { $0.id == spaces.activeSpaceID }
            statusItem?.button?.image = MenuBarIcon.image(number: index.map { $0 + 1 })
            statusItem?.button?.toolTip = index.map { "\(HyprDesk.name): \(spaces.spaces[$0].name)" } ?? HyprDesk.name
        } onChange: {
            Task { @MainActor [weak self] in self?.observeStatusItem() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        accessItem.isHidden = inventory.isTrusted
        suspendItem.title = preferences.isSuspended ? "Resume HyprDesk" : "Suspend HyprDesk"
        let cli = CLIInstaller.state
        cliItem.title = cli == .installed ? "Remove Command Line Tool…" : "Install Command Line Tool…"
        cliItem.toolTip = switch cli {
        case .installed: "“hyprdesk” in \(CLIInstaller.link.deletingLastPathComponent().path) runs this copy of HyprDesk."
        case .otherCopy: "“hyprdesk” in \(CLIInstaller.link.deletingLastPathComponent().path) runs another copy of HyprDesk; install to use this one."
        case .foreign, .missing: "The “hyprdesk” command, in \(CLIInstaller.link.deletingLastPathComponent().path): control HyprDesk from scripts and agents."
        }
    }

    /// Installs `hyprdesk` in /usr/local/bin, or removes it, and says how that went.
    @objc private func toggleCLI() {
        let installing = CLIInstaller.state != .installed
        let result = installing ? CLIInstaller.install() : CLIInstaller.remove()
        let alert = NSAlert()
        switch result {
        case .success where installing:
            alert.messageText = "hyprdesk is installed"
            alert.informativeText = "Try “hyprdesk list” in a new terminal window. The command runs this copy of HyprDesk; if you move the app, install it again."
        case .success:
            alert.messageText = "hyprdesk is removed"
            alert.informativeText = "\(CLIInstaller.link.path) is gone. HyprDesk itself is untouched."
        case .failure(.cancelled):
            return
        case .failure(.message(let message)):
            alert.alertStyle = .warning
            alert.messageText = installing ? "Couldn't install hyprdesk" : "Couldn't remove hyprdesk"
            alert.informativeText = message
        }
        NSApp.activate()
        alert.runModal()
    }

    /// Suspended: every window on screen, no hiding, none of our shortcuts or key overrides,
    /// following focus off. The menu-bar icon dims.
    @objc private func toggleSuspended() {
        preferences.isSuspended.toggle()
        if preferences.isSuspended {
            engine.setScratchpad(shown: false, refocus: false)
            overview.dismiss(restoringFocus: true)
            expose.dismiss(restoringFocus: true)
            engine.pause()
        } else {
            engine.resume()
        }
        statusItem?.button?.appearsDisabled = preferences.isSuspended
    }

    /// Opening a card switches to its workspace (or brings up the scratchpad); a window in a
    /// card's miniature is focused, switching along.
    private func makeOverviewModel() -> OverviewModel {
        let model = OverviewModel(spaces: spaces, inventory: inventory)
        model.onActivate = { [weak self] card in
            guard let self else { return }
            overview.dismiss(restoringFocus: false)
            if let space = card.space {
                engine.switchTo(space.id)
            } else {
                engine.setScratchpad(shown: true)  // over the workspace you're in, as ✦ S
            }
        }
        // Switching to its workspace, or bringing up the scratchpad, as needed.
        model.onRaise = { [weak self] window in
            guard let self else { return }
            overview.dismiss(restoringFocus: false)
            engine.focus(window)
        }
        model.onDismiss = { [weak self] in self?.overview.dismiss(restoringFocus: true) }
        return model
    }

    @objc private func requestAccess() {
        inventory.requestAccess()
    }

    @objc private func showManageWindow() {
        if manageWindow == nil {
            let view = ManageView(engine: engine, preferences: preferences)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
            )
            window.title = "Manage Workspaces"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            // Above other apps' windows and on every macOS desktop, so it can't get buried behind
            // the app you switch to while editing. (Our own windows aren't workspace-managed, so
            // it shows in every workspace too.)
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrameAutosaveName("ManageWindow")
            if !window.setFrameUsingName("ManageWindow") { window.center() }
            manageWindow = window
        }
        NSApp.activate()
        manageWindow?.makeKeyAndOrderFront(nil)
        // Front even if activation is refused (a menu-bar app can't always take focus).
        manageWindow?.orderFrontRegardless()
    }
}
