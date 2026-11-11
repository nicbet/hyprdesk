import AppKit
import Observation
import OSLog
import Spaces
import WindowKit

/// Makes the screen show exactly the current space: its windows and the sticky ones where they
/// belong, every other window parked just past a corner of its screen (how AeroSpace hides
/// windows: no animation, no Space switch, one Accessibility call per window).
///
/// Switching is `apply()` after changing the current space, then focusing the space's last
/// focused window. Focusing a parked window some other way (⌘Tab, a notification, the Dock)
/// switches to its space, unless its app came forward (the Dock, a notification) and has a window
/// in this space: then that one comes forward instead.
///
/// It works on one macOS desktop, the one its windows are on. Accessibility lists only the
/// current desktop's windows, so on another desktop HyprDesk is *away*: it ignores what it
/// sees there (nothing forgotten, parked, placed or switched) until you come back.
///
/// Display changes are handled the same way: while the displays sleep, or come and go (a lone
/// external display drops off the bus in standby), the listing and the screen geometry can't be
/// trusted, so HyprDesk is hands off until they've settled and it's home again.
@MainActor
@Observable
public final class WorkspaceEngine {
    public let inventory: WindowInventory
    public let spaces: SpaceStore

    /// How long the last switch took, from the request to the focused window.
    public private(set) var lastSwitch: Duration?
    /// The space before the current one, for "switch back".
    public private(set) var previousID: UUID?
    /// After every switch, with the space now on screen.
    @ObservationIgnored public var onSwitch: ((UUID) -> Void)?
    /// The scratchpad came up (true) or went away (false). Called when it comes up after its
    /// windows are back on screen but before they're raised, so whatever this puts on screen
    /// (the dimmed backdrop) lands between the workspace and the scratchpad.
    @ObservationIgnored public var onScratchpad: ((Bool) -> Void)?
    /// Before the scratchpad comes up, while the screen still shows the workspace untouched:
    /// gets a chance to picture it (the backdrop), then calls `done` (on the main actor) to go on.
    @ObservationIgnored public var prepareScratchpad: ((_ done: @escaping @MainActor () -> Void) -> Void)?
    /// After any window takes focus (an app coming forward brings all its windows along).
    @ObservationIgnored public var onFocus: (() -> Void)?

    /// Parking off: every window on screen, nothing parked, until resumed.
    public private(set) var isPaused = false
    /// On another macOS desktop than HyprDesk's own: hands off until the user is back.
    public private(set) var isAway = false

    /// Each parked window's real frame (Accessibility coordinates, always on screen), to put it
    /// back. Also written to disk, so a crash doesn't leave windows stranded in the corner.
    @ObservationIgnored private var parked: [CGWindowID: CGRect] = [:]
    /// Handles to parked windows: they still work when the window isn't listed (from another
    /// desktop), so quitting can always put every parked window back.
    @ObservationIgnored private var parkedHandles: [CGWindowID: WindowHandle] = [:]
    /// Each window's last frame seen on screen (from listings, and when it parks): where it goes
    /// back if it's ever found out of sight without a parked spot to return to.
    @ObservationIgnored private var lastOnScreen: [CGWindowID: CGRect] = [:]
    /// The windows last listed on HyprDesk's desktop (minimized ones left out), to recognize
    /// it after a desktop change.
    @ObservationIgnored private var homeWindows: Set<CGWindowID> = []
    /// A desktop change happened and isn't settled: listings may be another desktop's.
    @ObservationIgnored private var desktopUnsettled = false
    @ObservationIgnored private var desktopCheck: Task<Void, Never>?
    /// The displays (or the whole Mac) are asleep: nothing to check until they wake.
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var systemAsleep = false
    /// A display change happened and isn't settled: the screens may be missing or a stand-in.
    @ObservationIgnored private var displaysUnsettled = false
    /// The shown windows' frames, and the screens, from just before the displays changed: macOS
    /// moves windows off a display that goes away and doesn't always put them back.
    @ObservationIgnored private var beforeDisplayChange: (screens: [CGRect], frames: [CGWindowID: CGRect])?
    /// Since when the screens back from a display change aren't the ones from before it.
    @ObservationIgnored private var otherScreensSince: ContinuousClock.Instant?
    @ObservationIgnored private var displayTokens: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var lastFocused: [UUID: CGWindowID] = [:]
    /// The scratchpad's last focused window.
    @ObservationIgnored private var lastScratchpad: CGWindowID?
    /// The app whose window last took focus: when another one comes forward (the Dock, a
    /// notification), it may have a window right here to use instead of switching away.
    @ObservationIgnored private var frontApp: pid_t?
    /// Scratchpad windows' frames from before they were fitted into it, to give back when they
    /// leave. This run only.
    @ObservationIgnored private var scratchpadHomes: [CGWindowID: CGRect] = [:]
    /// The workspace's windows, front to back, as they were when the scratchpad came up: an app
    /// coming forward for the scratchpad drags its other windows along, and they're put back.
    @ObservationIgnored private var orderBeforeScratchpad: [CGWindowID] = []
    @ObservationIgnored private var preparingScratchpad = false
    /// Focused windows, most recent first, for the switcher.
    @ObservationIgnored public private(set) var recentWindows: [CGWindowID] = []
    /// Focus events right after a switch are our own doing (or the parked app letting go).
    @ObservationIgnored private var quietUntil = ContinuousClock.now
    @ObservationIgnored private var recovery: [CGWindowID: CGRect]?
    @ObservationIgnored private let recoveryURL: URL?

    static let quietAfterSwitch: Duration = .milliseconds(400)
    /// After a desktop change, the slide animation settles before the check.
    static let desktopSettle: Duration = .milliseconds(400)
    /// After the last display change (waking, a display coming back), before the check: the
    /// screens arrive one notification at a time, and apps answer slowly just after waking.
    static let displaySettle: Duration = .seconds(2)
    /// How long to wait for the screens from before a display change to come back: a display
    /// returning through a hub or KVM shows up in stages (a stand-in mode first, then its own).
    static let sameScreensWait: Duration = .seconds(10)
    /// `log stream --predicate 'subsystem == "com.github.nicbet.hyprdesk"'`
    private static let log = Logger(subsystem: "com.github.nicbet.hyprdesk", category: "engine")

    /// `~/Library/Application Support/HyprDesk/parked.json`.
    public static var defaultRecoveryURL: URL {
        URL.applicationSupportDirectory.appending(path: "HyprDesk/parked.json")
    }

    public init(inventory: WindowInventory, spaces: SpaceStore, recoveryURL: URL? = WorkspaceEngine.defaultRecoveryURL) {
        self.inventory = inventory
        self.spaces = spaces
        self.recoveryURL = recoveryURL
    }

    /// Takes over the inventory's callbacks. On the first listing, windows a previous run left
    /// parked (or any window stranded off screen) are put back before anything is parked again.
    public func start() {
        recovery = loadRecovery() ?? [:]  // non-nil: the first listing always rescues
        // A new window joins the current workspace, unless its app just launched: then it's being
        // restored and may find its old workspace.
        inventory.onAppear = { [weak self] windows in
            guard let self, !desktopUnsettled else { return }
            spaces.place(windows, restoring: Self.appJustLaunched)
        }
        inventory.onChange = { [weak self] in self?.windowsChanged($0) }
        inventory.onFocusChange = { [weak self] in self?.focusChanged($0) }
        inventory.onDesktopChange = { [weak self] in self?.desktopDidChange() }
        observeDisplays()
        if !inventory.windows.isEmpty { windowsChanged(inventory.windows) }
    }

    /// Puts every parked window back. Call before quitting.
    public func stop() {
        spaces.flush()
        inventory.onAppear = nil
        inventory.onChange = nil
        inventory.onFocusChange = nil
        inventory.onDesktopChange = nil
        for (center, token) in displayTokens { center.removeObserver(token) }
        displayTokens = []
        desktopCheck?.cancel()
        unparkAll()
    }

    /// Every window back on screen, and no parking until `resume()`. The way out if anything
    /// ever goes wrong.
    public func pause() {
        isPaused = true
        unparkAll()
        rescueStranded()
    }

    public func resume() {
        isPaused = false
        apply()
    }

    /// Every parked window back where it was, through its handle: listed or not, from any
    /// desktop.
    private func unparkAll() {
        let screens = ScreenGeometry.screens()
        inventory.move(parked.compactMap { id, frame in
            parkedHandles[id].map { (handle: $0, origin: ScreenGeometry.onScreen(frame, in: screens).origin) }
        })
        parked = [:]
        parkedHandles = [:]
        saveRecovery()
    }

    /// Brings back windows that are off screen without being parked by us: left by a crash or
    /// an older build. A window the user can't see or grab is never what they want.
    private func rescueStranded() {
        let screens = ScreenGeometry.screens()
        let candidates = inventory.windows.filter { parked[$0.id] == nil && !$0.isMinimized }
        let frames = inventory.frames(of: candidates)
        let stranded = candidates.filter { frames[$0.id].map { ScreenGeometry.isMostlyOffscreen($0, in: screens) } == true }
        inventory.move(stranded.map { ($0, ScreenGeometry.onScreen(frames[$0.id]!, in: screens).origin) })
        for window in stranded {
            Self.log.info("rescued \(window.appName, privacy: .public) “\(window.title, privacy: .public)” from off screen")
        }
    }

    // MARK: Switching

    public func switchTo(_ id: UUID, focusing target: WindowInfo? = nil) {
        let start = ContinuousClock.now
        guard spaces.space(id) != nil, !desktopUnsettled else { return }
        let current = spaces.activeSpaceID
        if let current, let focused = inventory.focusedWindowID(),
           inventory.windows.first(where: { $0.id == focused }).flatMap(spaces.placement(of:))?.spaceID == current {
            lastFocused[current] = focused
        }
        if id != current { previousID = current }
        quietUntil = start + Self.quietAfterSwitch
        // The scratchpad is a quick look over one workspace; switching away puts it away.
        let hadScratchpad = spaces.isScratchpadShown
        spaces.isScratchpadShown = false
        if hadScratchpad { onScratchpad?(false) }
        spaces.activeSpaceID = id
        let moved = apply()
        let applied = start.duration(to: .now)
        focus(in: id, preferring: target)
        lastSwitch = start.duration(to: .now)
        onSwitch?(id)
        Self.log.info("switch to \(self.spaces.space(id)?.name ?? "?", privacy: .public): \(moved) windows moved in \(applied.formatted(.units(allowed: [.milliseconds], width: .narrow)), privacy: .public), focused after \(self.lastSwitch!.formatted(.units(allowed: [.milliseconds], width: .narrow)), privacy: .public)")
    }

    public func switchToPrevious() {
        if let previousID { switchTo(previousID) }
    }

    /// Focuses `window`, switching to its space first if it's parked in another one (or
    /// showing the scratchpad, if it's in there).
    public func focus(_ window: WindowInfo) {
        if spaces.placement(of: window)?.placement == .scratchpad, !spaces.isScratchpadShown {
            setScratchpad(shown: true, focusing: window)
        } else if let id = spaces.placement(of: window)?.spaceID, id != spaces.activeSpaceID {
            switchTo(id, focusing: window)
        } else {
            inventory.raise(window)
            noteFocus(window.id)
        }
    }

    /// The windows on screen in the current space (its own and sticky ones), for the switcher:
    /// most recently focused first, then frontmost first.
    public func switcherWindows() -> [WindowInfo] {
        let shown = inventory.windows.filter { spaces.isShown($0) }
        return SwitcherOrder.ordered(shown, recent: recentWindows, fallback: WindowOrder.current())
    }

    private func noteFocus(_ id: CGWindowID) {
        recentWindows.removeAll { $0 == id }
        recentWindows.insert(id, at: 0)
        if recentWindows.count > 200 { recentWindows.removeLast() }
        switch inventory.windows.first(where: { $0.id == id }).flatMap(spaces.placement(of:))?.placement {
        case .space(let spaceID): lastFocused[spaceID] = id
        case .scratchpad: lastScratchpad = id
        default: break
        }
    }

    // MARK: Scratchpad

    /// The scratchpad's windows, in no particular order.
    public var scratchpadWindows: [WindowInfo] {
        inventory.windows.filter { spaces.placement(of: $0)?.placement == .scratchpad }
    }

    /// ✦ S: the scratchpad over the current workspace, or put away again.
    public func toggleScratchpad() {
        setScratchpad(shown: !spaces.isScratchpadShown)
    }

    /// Shows the scratchpad (focusing `target`, else its last focused window, else its frontmost)
    /// or hides it. `refocus`: on hiding, the workspace's last focused window takes focus back
    /// (not when something else just took it).
    public func setScratchpad(shown: Bool, focusing target: WindowInfo? = nil, refocus: Bool = true) {
        guard !desktopUnsettled, !preparingScratchpad, spaces.isScratchpadShown != shown else {
            if shown, let target, spaces.isScratchpadShown { inventory.raise(target, alone: true); noteFocus(target.id) }
            return
        }
        let windows = scratchpadWindows.filter { !$0.isMinimized }
        if shown, windows.isEmpty { return }
        if shown, let prepare = prepareScratchpad {
            preparingScratchpad = true
            prepare { [weak self] in
                guard let self else { return }
                preparingScratchpad = false
                showScratchpad(focusing: target)
            }
        } else if shown {
            showScratchpad(focusing: target)
        } else {
            hideScratchpad(refocus: refocus)
        }
    }

    private func showScratchpad(focusing target: WindowInfo?) {
        let windows = scratchpadWindows.filter { !$0.isMinimized }
        guard !desktopUnsettled, !spaces.isScratchpadShown, !windows.isEmpty else { return }
        quietUntil = .now + Self.quietAfterSwitch
        let focused = inventory.focusedWindowID()
        if let current = spaces.activeSpaceID, let focused,
           inventory.windows.first(where: { $0.id == focused }).flatMap(spaces.placement(of:))?.spaceID == current {
            lastFocused[current] = focused
        }
        let workspace = inventory.windows.filter { spaces.isShown($0) && !$0.isMinimized }
        orderBeforeScratchpad = WindowOrder.sorted(workspace, by: WindowOrder.current()).map(\.id)
        spaces.isScratchpadShown = true
        apply()
        fitScratchpad(windows)
        onScratchpad?(true)
        // All of them above the backdrop, the one taking focus last.
        let remembered = lastScratchpad.flatMap { last in windows.first { $0.id == last } }
        let front = target ?? remembered ?? WindowOrder.sorted(windows, by: WindowOrder.current()).first
        for window in WindowOrder.sorted(windows, by: WindowOrder.current()).reversed() where window.id != front?.id {
            inventory.raise(window, alone: true)
        }
        if let front {
            inventory.raise(front, alone: true)
            noteFocus(front.id)
        }
        Self.log.info("scratchpad shown")
    }

    /// `refocus`: put the workspace back as it was (its windows' order, its focused window).
    /// Not when a workspace window just took focus: that one stays in front.
    private func hideScratchpad(refocus: Bool) {
        quietUntil = .now + Self.quietAfterSwitch
        spaces.isScratchpadShown = false
        // One motion: the dim starts going in the same moment the scratchpad's windows do.
        onScratchpad?(false)
        apply()
        if refocus { restoreOrderBeforeScratchpad() }
        orderBeforeScratchpad = []
        Self.log.info("scratchpad hidden")
    }

    /// Windows that came forward with a scratchpad window's app go back behind the ones that were
    /// in front of them: those are raised again, back to front, ending with the frontmost (which
    /// takes focus). With nothing out of place, only the focus goes back.
    private func restoreOrderBeforeScratchpad() {
        let before = orderBeforeScratchpad.filter { id in inventory.windows.contains { $0.id == id && spaces.isShown($0) } }
        let now = WindowOrder.current()
        let ranked = before.sorted { (now[$0] ?? .max) < (now[$1] ?? .max) }
        // How deep the order is wrong: the furthest-back window that jumped ahead of its place.
        let depth = before.indices.filter { ranked.firstIndex(of: before[$0])! < $0 }.max()
        let windows = inventory.windows
        if let depth {
            for id in before[..<depth].reversed() {
                if let window = windows.first(where: { $0.id == id }) { inventory.raise(window) }
            }
            if let front = before.first { noteFocus(front) }
        } else if let current = spaces.activeSpaceID {
            focus(in: current, preferring: nil)
        }
    }

    /// Scratchpad windows sit inset over the workspace: each fitted into most of its screen and
    /// centered, its own frame kept to give back when it leaves the scratchpad.
    private func fitScratchpad(_ windows: [WindowInfo]) {
        let screens = ScreenGeometry.screens(), visible = ScreenGeometry.visibleScreens()
        let frames = inventory.frames(of: windows)
        var fitted: [(window: WindowInfo, frame: CGRect)] = []
        for window in windows {
            guard let frame = frames[window.id] else { continue }
            if scratchpadHomes[window.id] == nil { scratchpadHomes[window.id] = frame }
            let screen = ScreenGeometry.screen(for: frame, in: screens)
            let area = screen.flatMap { screens.firstIndex(of: $0) }.map { visible[$0] } ?? visible.first ?? frame
            let target = ScreenGeometry.scratchpadFrame(for: scratchpadHomes[window.id]!.size, in: area)
            if target != frame { fitted.append((window, target)) }
        }
        inventory.setFrames(fitted)
    }

    /// A window left the scratchpad: its own frame back. If it's out of sight now, only its size
    /// changes and its parked spot is told where it really belongs.
    private func leftScratchpad(_ window: WindowInfo) {
        guard let home = scratchpadHomes.removeValue(forKey: window.id) else { return }
        if parked[window.id] != nil {
            inventory.setSizes([(window, home.size)])
            parked[window.id] = home
            saveRecovery()
        } else {
            inventory.setFrames([(window, home)])
        }
    }

    /// ✦ ⇧ S: the focused window into the scratchpad, or, if it's already there, out of it into
    /// the current workspace (it stays focused). A window sent in while the scratchpad is hidden
    /// goes out of sight, and the workspace's next window takes focus.
    public func toggleFocusedWindowInScratchpad() {
        guard !desktopUnsettled, let focused = inventory.focusedWindowID(),
              let window = inventory.windows.first(where: { $0.id == focused }) else { return }
        if spaces.placement(of: window)?.placement == .scratchpad {
            guard let current = spaces.activeSpaceID else { return }
            if lastScratchpad == focused { lastScratchpad = nil }
            move(window, to: .space(current))
            noteFocus(focused)
            if spaces.isScratchpadShown, scratchpadWindows.isEmpty { setScratchpad(shown: false, refocus: false) }
            return
        }
        if let from = spaces.placement(of: window)?.spaceID, lastFocused[from] == focused { lastFocused[from] = nil }
        lastScratchpad = focused
        quietUntil = .now + Self.quietAfterSwitch
        move(window, to: .scratchpad)
        if spaces.isScratchpadShown {
            fitScratchpad([window])
        } else if let current = spaces.activeSpaceID {
            focus(in: current, preferring: nil)
        }
    }

    /// The space's last focused window, else its frontmost one; with none, Finder takes focus so
    /// typing doesn't go to a parked window.
    private func focus(in id: UUID, preferring target: WindowInfo?) {
        let windows = inventory.windows.filter { spaces.placement(of: $0)?.spaceID == id && !$0.isMinimized }
        let remembered = lastFocused[id].flatMap { last in windows.first { $0.id == last } }
        let frontmost = WindowOrder.sorted(windows, by: WindowOrder.current()).first
        if let window = target ?? remembered ?? frontmost {
            inventory.raise(window)
            noteFocus(window.id)
        } else if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            NSApp.yieldActivation(to: finder)
            finder.activate()
        }
    }

    // MARK: Applying

    /// Brings every window in line with the current space: first puts back what should show (so
    /// the screen never flashes empty), then parks what shouldn't. Each step asks every app at
    /// once (`WindowInventory.move`), so a switch takes about as long as the slowest app.
    /// Returns how many windows moved.
    @discardableResult
    public func apply() -> Int {
        // On another desktop the listing isn't ours: parking from it would hide the wrong windows.
        guard !isPaused, !desktopUnsettled else { return 0 }
        let screens = ScreenGeometry.screens()
        // No screen to measure against: every window would look on screen, parked ones too.
        guard !screens.isEmpty else { return 0 }
        let windows = inventory.windows

        // 1. Back on screen.
        let unparking = windows.filter { spaces.isShown($0) && parked[$0.id] != nil }.map { window in
            parkedHandles[window.id] = nil
            return (window: window, origin: ScreenGeometry.onScreen(parked.removeValue(forKey: window.id)!, in: screens).origin)
        }
        inventory.move(unparking)

        // Shown but out of sight without being parked: its parked spot was lost somehow. It goes
        // back where it was last seen on screen (centered only if it never was). The listing
        // picks candidates; the app confirms.
        let unparked = Set(unparking.map(\.window.id))
        let strandedCandidates = windows.filter {
            spaces.isShown($0) && parked[$0.id] == nil && !unparked.contains($0.id) && !$0.isMinimized
                && ScreenGeometry.isMostlyOffscreen($0.frame, in: screens)
        }
        let strandedFrames = inventory.frames(of: strandedCandidates)
        let rescuing = strandedCandidates.compactMap { window -> (window: WindowInfo, origin: CGPoint)? in
            guard let frame = strandedFrames[window.id], ScreenGeometry.isMostlyOffscreen(frame, in: screens) else { return nil }
            let known = lastOnScreen[window.id].map { CGRect(origin: $0.origin, size: frame.size) }
            let home = known.flatMap { ScreenGeometry.isMostlyOffscreen($0, in: screens) ? nil : $0 }
            Self.log.info("rescued \(window.appName, privacy: .public) “\(window.title, privacy: .public)”: shown but out of sight, \(home == nil ? "centered" : "back where it was", privacy: .public)")
            return (window, (home ?? ScreenGeometry.onScreen(frame, in: screens)).origin)
        }
        inventory.move(rescuing)

        // 2. Out of sight. "Parked" means mostly off screen, not an exact spot: macOS clamps where a
        // window may go. A parked window still out of sight by the last listing needs nothing;
        // the others are asked where they are (the listing can lag behind a move).
        let hiding = windows.filter { window in
            !spaces.isShown(window) && !window.isMinimized
                && !(parked[window.id] != nil && ScreenGeometry.isMostlyOffscreen(window.frame, in: screens))
        }
        let live = inventory.frames(of: hiding)
        var parking: [(window: WindowInfo, origin: CGPoint)] = []
        for window in hiding {
            guard let frame = live[window.id], !ScreenGeometry.isMostlyOffscreen(frame, in: screens) else { continue }
            // Something moved a parked window back (its app, the user): keep its real frame.
            // Otherwise this is its real frame; never remember a hidden spot as one.
            let real = parked[window.id] ?? ScreenGeometry.onScreen(frame, in: screens)
            parked[window.id] = real
            lastOnScreen[window.id] = real
            if parkedHandles[window.id] == nil { parkedHandles[window.id] = inventory.handle(for: window) }
            parking.append((window, ScreenGeometry.parkingOrigin(for: CGRect(origin: real.origin, size: frame.size), in: screens)))
        }
        inventory.move(parking)
        saveRecovery()
        return unparking.count + rescuing.count + parking.count
    }

    // MARK: Editing (keeps the screen in line)

    public func move(_ window: WindowInfo, to placement: Placement) {
        let wasScratchpad = spaces.placement(of: window)?.placement == .scratchpad
        spaces.move(window, to: placement)
        apply()
        if wasScratchpad, placement != .scratchpad { leftScratchpad(window) }
        if placement == .scratchpad, spaces.isScratchpadShown { fitScratchpad([window]) }
    }

    /// Sends the focused window to workspace `id` and follows it there: `id` becomes the
    /// current workspace, with the window still focused. A window shown in every workspace then
    /// lives in `id` only.
    public func moveFocusedWindow(to id: UUID) {
        guard spaces.space(id) != nil, !desktopUnsettled, let focused = inventory.focusedWindowID(),
              let window = inventory.windows.first(where: { $0.id == focused }) else { return }
        // The workspace left behind focuses what else was there, not the window that left.
        if let from = spaces.placement(of: window)?.spaceID, lastFocused[from] == focused { lastFocused[from] = nil }
        // Placed first and applied once by the switch: the window never parks on the way.
        let wasScratchpad = spaces.placement(of: window)?.placement == .scratchpad
        spaces.move(window, to: .space(id))
        if wasScratchpad { leftScratchpad(window) }
        Self.log.info("moved \(window.appName, privacy: .public) “\(window.title, privacy: .public)” to \(self.spaces.space(id)?.name ?? "?", privacy: .public)")
        switchTo(id, focusing: window)
    }

    public func setSticky(_ app: String, _ sticky: Bool) {
        spaces.setSticky(app, sticky, windows: inventory.windows)
        apply()
    }

    public func removeSpace(_ id: UUID) {
        spaces.removeSpace(id)
        apply()
    }

    /// Whether the window is parked right now.
    public func isParked(_ window: WindowInfo) -> Bool { parked[window.id] != nil }

    // MARK: Events

    private func windowsChanged(_ windows: [WindowInfo]) {
        // Another desktop's listing (or one taken mid-slide): not ours to act on.
        guard !desktopUnsettled else { return }
        homeWindows = Set(windows.filter { !$0.isMinimized }.map(\.id))
        if let recovery {
            self.recovery = nil
            let screens = ScreenGeometry.screens()
            inventory.move(windows.compactMap { window in
                recovery[window.id].map { (window, ScreenGeometry.onScreen($0, in: screens).origin) }
            })
            rescueStranded()
        }
        // Placed first, so a relaunched app's windows claim their records before closed ones
        // are forgotten. Anything unplaced here was open before we saw it: it's being restored.
        spaces.place(windows, restoring: { _ in true })
        spaces.windowsChanged(windows, runningApps: Self.runningApps())
        // Where every window on screen is, in case it ever needs putting back without a parked spot.
        let screens = ScreenGeometry.screens()
        for window in windows where parked[window.id] == nil && !window.isMinimized
            && spaces.placement(of: window)?.placement != .scratchpad
            && !ScreenGeometry.isMostlyOffscreen(window.frame, in: screens) {
            lastOnScreen[window.id] = window.frame
        }
        // A parked window that isn't listed is only forgotten once it's really gone.
        let ids = Set(windows.map(\.id))
        // Kept through gaps in the listing (that's when it's needed); trimmed only once it grows.
        if lastOnScreen.count > 1000 { lastOnScreen = lastOnScreen.filter { ids.contains($0.key) || parked[$0.key] != nil } }
        for id in parked.keys where !ids.contains(id) {
            if let handle = parkedHandles[id], inventory.exists(handle) { continue }
            parked[id] = nil
            parkedHandles[id] = nil
        }
        apply()
    }

    /// The user moved to another desktop, or back. Hands off at once (the shortcuts step aside
    /// too); once the slide has settled, check: if HyprDesk's windows are on screen again,
    /// it's home, and the windows are listed afresh.
    private func desktopDidChange() {
        handOff(checkAfter: Self.desktopSettle)
    }

    /// Hands off now; after `delay` (longer while the displays are unsettled), if the displays
    /// are awake and HyprDesk's windows are on screen again, it's home: the windows are listed
    /// afresh and, after a display change, put back where they were. Not home: it stays away
    /// until the next desktop or display change.
    private func handOff(checkAfter delay: Duration) {
        desktopUnsettled = true
        isAway = true
        desktopCheck?.cancel()
        desktopCheck = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: displaysUnsettled ? max(delay, Self.displaySettle) : delay)
            guard !Task.isCancelled else { return }
            // Waking (the displays, or the Mac) checks again.
            guard !screensAsleep, !systemAsleep, !NSScreen.screens.isEmpty else { return }
            // Other screens than before: likely still arriving. Wait (a while) for the real ones.
            if displaysUnsettled, let before = beforeDisplayChange,
               !Self.sameScreens(before.screens, ScreenGeometry.screens()) {
                let since = otherScreensSince ?? .now
                otherScreensSince = since
                if since.duration(to: .now) < Self.sameScreensWait {
                    Self.log.info("screens \(Self.describe(ScreenGeometry.screens()), privacy: .public), before \(Self.describe(before.screens), privacy: .public): waiting")
                    handOff(checkAfter: Self.displaySettle)
                    return
                }
            }
            let home = Desktop.isHome(homeWindows, onScreen: Desktop.onScreenWindowIDs())
            Self.log.info("\(self.displaysUnsettled ? "displays" : "desktop", privacy: .public) changed: \(home ? "home" : "away", privacy: .public)")
            guard home else { return }
            desktopUnsettled = false
            isAway = false
            let displaysChanged = displaysUnsettled
            displaysUnsettled = false
            otherScreensSince = nil
            inventory.refreshAll()
            guard displaysChanged else { return }
            // The listing may be just what it was before (relisting reports only changes).
            windowsChanged(inventory.windows)
            restoreFramesFromBeforeDisplayChange()
        }
    }

    // MARK: Displays

    private func observeDisplays() {
        guard displayTokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let observe = { (center: NotificationCenter, name: Notification.Name, handle: @escaping @MainActor (WorkspaceEngine) -> Void) in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { handle(self) } }
            }
            self.displayTokens.append((center, token))
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true; $0.displaysDidChange("screens asleep") }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; $0.displaysDidChange("screens awake") }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemAsleep = true; $0.displaysDidChange("going to sleep") }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemAsleep = false; $0.displaysDidChange("woke") }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.displaysDidChange("screens changed") }
        // After waking to the lock screen, the windows may not count as on screen until unlocked.
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.displaysDidChange("unlocked") }
    }

    /// The displays slept, woke or changed. Whatever is listed until they settle may be wrong
    /// (windows missing, every one of them on a stand-in screen): taken at its word, windows
    /// would lose their workspace, or be parked and put back against the wrong screens.
    private func displaysDidChange(_ what: String) {
        Self.log.info("\(what, privacy: .public): \(Self.describe(ScreenGeometry.screens()), privacy: .public)")
        // Where the shown windows were, from the last listing while settled.
        if !desktopUnsettled, beforeDisplayChange == nil {
            let shown = inventory.windows.filter(isPlainlyShown)
            beforeDisplayChange = (ScreenGeometry.screens(),
                                   Dictionary(shown.compactMap { w in lastOnScreen[w.id].map { (w.id, $0) } }, uniquingKeysWith: { a, _ in a }))
        }
        displaysUnsettled = true
        handOff(checkAfter: Self.displaySettle)
    }

    /// Back from a display change on the same screens: every shown window macOS moved goes
    /// back where it was. Parked windows need nothing: `apply()` parks them again from their
    /// parked frames, wherever macOS put them.
    private func restoreFramesFromBeforeDisplayChange() {
        guard let before = beforeDisplayChange else { return }
        beforeDisplayChange = nil
        let screens = ScreenGeometry.screens()
        guard Self.sameScreens(before.screens, screens) else {
            Self.log.info("other screens than before the display change (\(Self.describe(screens), privacy: .public), before \(Self.describe(before.screens), privacy: .public)): windows stay where macOS put them")
            return
        }
        let shown = inventory.windows.filter { isPlainlyShown($0) && before.frames[$0.id] != nil }
        let now = inventory.frames(of: shown)
        let moves = shown.compactMap { window -> (window: WindowInfo, frame: CGRect)? in
            guard let old = before.frames[window.id], let frame = now[window.id], frame != old,
                  !ScreenGeometry.isMostlyOffscreen(old, in: screens) else { return nil }
            return (window, old)
        }
        let moved = inventory.setFrames(moves)
        if moved > 0 { Self.log.info("put \(moved) windows back where they were before the display change") }
    }

    /// On screen in the current workspace as itself: not parked, minimized or in the scratchpad.
    private func isPlainlyShown(_ window: WindowInfo) -> Bool {
        spaces.isShown(window) && !window.isMinimized && parked[window.id] == nil
            && spaces.placement(of: window)?.placement != .scratchpad
    }

    /// "3360×1890 at 0,0 + …", or "none".
    private static func describe(_ screens: [CGRect]) -> String {
        screens.isEmpty ? "none" : screens.map { "\(Int($0.width))×\(Int($0.height)) at \(Int($0.minX)),\(Int($0.minY))" }.joined(separator: " + ")
    }

    private static func sameScreens(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        let order = { (r: CGRect, s: CGRect) in (r.minX, r.minY, r.width, r.height) < (s.minX, s.minY, s.width, s.height) }
        return a.sorted(by: order) == b.sorted(by: order)
    }

    private func focusChanged(_ id: CGWindowID) {
        defer { onFocus?() }
        guard !isPaused, !desktopUnsettled, let window = inventory.windows.first(where: { $0.id == id }) else { return }
        let cameForward = frontApp != window.pid
        frontApp = window.pid
        if spaces.placement(of: window)?.placement == .scratchpad, !spaces.isScratchpadShown {
            // ⌘Tab, a click in the Dock or a notification reached a scratchpad window.
            if ContinuousClock.now >= quietUntil { setScratchpad(shown: true, focusing: window) }
            return
        }
        if spaces.isScratchpadShown, spaces.placement(of: window)?.placement != .scratchpad, ContinuousClock.now >= quietUntil {
            // A workspace window came forward (⌘Tab, a click): the scratchpad steps aside.
            setScratchpad(shown: false, refocus: false)
        }
        let spaceID = spaces.placement(of: window)?.spaceID
        if spaceID == nil || spaceID == spaces.activeSpaceID || ContinuousClock.now < quietUntil {
            if spaces.isShown(window) { noteFocus(id) }
        } else if cameForward, let here = windowHere(of: window.pid) {
            // The app came forward (the Dock, a notification) and macOS picked its last used
            // window, in another workspace; it has one here, so that's the one, and you stay.
            quietUntil = .now + Self.quietAfterSwitch
            inventory.raise(here, alone: true)
            noteFocus(here.id)
        } else if let spaceID {
            switchTo(spaceID, focusing: window)
        }
    }

    /// `pid`'s frontmost window in the current workspace (its own, not one shown everywhere).
    private func windowHere(of pid: pid_t) -> WindowInfo? {
        let here = inventory.windows.filter {
            $0.pid == pid && !$0.isMinimized && spaces.placement(of: $0)?.spaceID == spaces.activeSpaceID
        }
        return WindowOrder.sorted(here, by: WindowOrder.current()).first
    }

    /// Windows of an app launched this recently are being restored, not opened.
    static let restoreWindow: TimeInterval = 60

    private static func appJustLaunched(_ window: WindowInfo) -> Bool {
        guard let launched = NSRunningApplication(processIdentifier: window.pid)?.launchDate else { return false }
        return Date.now.timeIntervalSince(launched) < restoreWindow
    }

    /// What `WindowInfo.appKey` is for every running app: bundle ID, else name.
    private static func runningApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier ?? $0.localizedName })
    }

    // MARK: Recovery

    private struct Parked: Codable {
        var id: CGWindowID
        var x, y, width, height: Double
    }

    private func saveRecovery() {
        guard let recoveryURL else { return }
        let list = parked.map { Parked(id: $0.key, x: $0.value.minX, y: $0.value.minY, width: $0.value.width, height: $0.value.height) }
        if list.isEmpty {
            try? FileManager.default.removeItem(at: recoveryURL)
            return
        }
        try? FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: recoveryURL, options: .atomic)
    }

    private func loadRecovery() -> [CGWindowID: CGRect]? {
        guard let recoveryURL, let data = try? Data(contentsOf: recoveryURL),
              let list = try? JSONDecoder().decode([Parked].self, from: data), !list.isEmpty else { return nil }
        return Dictionary(list.map { ($0.id, CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) }, uniquingKeysWith: { a, _ in a })
    }
}
