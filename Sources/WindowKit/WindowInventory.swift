import AppKit
import ApplicationServices
import Observation
import Synchronization

/// Every standard window of every regular app, kept current.
///
/// Each app gets an `AXObserver` (window created, focused, retitled, minimized, closed); a
/// notification relists that one app shortly after. A slow full sweep catches what observers
/// miss: frames, apps that send nothing, and Accessibility being allowed later.
/// Needs the Accessibility permission; without it `windows` stays empty.
@MainActor
@Observable
public final class WindowInventory {
    public private(set) var windows: [WindowInfo] = []
    public private(set) var isTrusted = AXIsProcessTrusted()
    /// Windows that appeared while we were running (not the ones already open at the start).
    @ObservationIgnored public var onAppear: (([WindowInfo]) -> Void)?
    /// The focused window of the frontmost app changed: another app came forward (⌘Tab, a click,
    /// a notification), or the app switched windows.
    @ObservationIgnored public var onFocusChange: ((CGWindowID) -> Void)?
    /// After every relist that changed something, with the current windows.
    @ObservationIgnored public var onChange: (([WindowInfo]) -> Void)?
    /// The user moved to another macOS desktop (or back). Accessibility lists only the current
    /// desktop's windows, so the listing that follows may be another desktop's.
    @ObservationIgnored public var onDesktopChange: (() -> Void)?

    @ObservationIgnored private var ledger = WindowLedger()
    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    /// Each window's Accessibility element, so moving it needs no search.
    @ObservationIgnored private var elements: [CGWindowID: AXUIElement] = [:]
    @ObservationIgnored private var launched: Set<pid_t> = []
    @ObservationIgnored private var pending: Set<pid_t> = []
    @ObservationIgnored private var flush: Task<Void, Never>?
    @ObservationIgnored private var sweep: Task<Void, Never>?
    @ObservationIgnored private var workspaceTokens: [NSObjectProtocol] = []

    public static let sweepInterval: Duration = .seconds(3)
    /// How long a burst of notifications from one app is gathered before relisting it.
    static let settle: Duration = .milliseconds(120)

    public init() {}

    public func start() {
        guard sweep == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if let pid { self.launched.insert(pid); self.schedule(pid) } }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if let pid { self.forget(pid) } }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.onDesktopChange?() }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.focusChanged() }
            },
        ]
        sweep = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshAll()
                try? await Task.sleep(for: Self.sweepInterval)
            }
        }
    }

    public func stop() {
        sweep?.cancel()
        sweep = nil
        flush?.cancel()
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceTokens = []
        for pid in Array(observers.keys) { forget(pid) }
    }

    /// Asks macOS to show its Accessibility prompt (once; later it's System Settings).
    public func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read as a global var.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Relists every app now.
    public func refreshAll() {
        isTrusted = AXIsProcessTrusted()
        guard isTrusted else { return }
        let apps = Self.regularApps()
        let live = Set(apps.map(\.processIdentifier))
        for pid in ledger.byApp.keys where !live.contains(pid) { forget(pid) }
        var appeared: [WindowInfo] = []
        for app in apps { appeared += relist(app) }
        publish(appeared)
    }

    /// Brings `window` to the front: unminimized, main, raised, its app active. `alone`: only
    /// this window comes forward, not the app's others (making an app frontmost through
    /// Accessibility brings every one of its windows; plain activation brings just the main one).
    @discardableResult
    public func raise(_ window: WindowInfo, alone: Bool = false) -> Bool {
        guard isTrusted, let element = element(for: window) else { return false }
        if window.isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return activate(window.pid, allWindows: !alone)
    }

    /// The window's frame right now, in Accessibility coordinates (origin top left of the main
    /// screen, y down). `WindowInfo.frame` is only as fresh as the last relist.
    public func frame(of window: WindowInfo) -> CGRect? {
        guard isTrusted, let element = element(for: window) else { return nil }
        return AX.frame(element)
    }

    /// Moves the window's top-left corner to `origin` (Accessibility coordinates). Doesn't resize.
    @discardableResult
    public func move(_ window: WindowInfo, to origin: CGPoint) -> Bool {
        move([(window, origin)]) == 1
    }

    /// Moves many windows at once: every app is asked in parallel, each app's windows in order
    /// (an app answers Accessibility on its own main thread, so that's where the time goes).
    /// Returns how many moved; waits for all.
    @discardableResult
    public func move(_ moves: [(window: WindowInfo, origin: CGPoint)]) -> Int {
        move(moves.compactMap { move in handle(for: move.window).map { ($0, move.origin) } })
    }

    /// The same, through handles: works for windows that aren't listed right now (on another
    /// macOS desktop, say), as long as they still exist.
    @discardableResult
    public func move(_ moves: [(handle: WindowHandle, origin: CGPoint)]) -> Int {
        let origins = Dictionary(moves.map { ($0.handle.id, $0.origin) }, uniquingKeysWith: { _, last in last })
        let done = perApp(moves.map(\.handle)) { id, element -> Bool? in
            guard var point = origins[id], let value = AXValueCreate(.cgPoint, &point) else { return nil }
            return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success ? true : nil
        }
        return done.count
    }

    /// Moves and resizes windows (Accessibility coordinates), all apps asked in parallel. Position,
    /// size, then position again: a window may refuse a size that would cross the screen's edge
    /// from where it was. Returns how many were set.
    @discardableResult
    public func setFrames(_ frames: [(window: WindowInfo, frame: CGRect)]) -> Int {
        let targets = Dictionary(frames.map { ($0.window.id, $0.frame) }, uniquingKeysWith: { _, last in last })
        let done = perApp(frames.compactMap { handle(for: $0.window) }) { id, element -> Bool? in
            guard let frame = targets[id] else { return nil }
            var origin = frame.origin, size = frame.size
            guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return nil }
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
            let sized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent) == .success
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
            return sized ? true : nil
        }
        return done.count
    }

    /// Resizes windows without moving them (for parked ones, which must stay out of sight).
    @discardableResult
    public func setSizes(_ sizes: [(window: WindowInfo, size: CGSize)]) -> Int {
        let targets = Dictionary(sizes.map { ($0.window.id, $0.size) }, uniquingKeysWith: { _, last in last })
        let done = perApp(sizes.compactMap { handle(for: $0.window) }) { id, element -> Bool? in
            guard var size = targets[id], let extent = AXValueCreate(.cgSize, &size) else { return nil }
            return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent) == .success ? true : nil
        }
        return done.count
    }

    /// The windows' frames right now, all apps asked in parallel. Missing: windows that are gone.
    public func frames(of windows: [WindowInfo]) -> [CGWindowID: CGRect] {
        perApp(windows.compactMap(handle(for:))) { _, element in AX.frame(element) }
    }

    /// Whether the window behind `handle` still exists (listed or not).
    public func exists(_ handle: WindowHandle) -> Bool {
        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(handle.element, kAXRoleAttribute as CFString, &role)
        return result != .invalidUIElement && result != .cannotComplete
    }

    /// A lasting reference to `window`, usable after it drops out of the listing.
    public func handle(for window: WindowInfo) -> WindowHandle? {
        element(for: window).map { WindowHandle(id: window.id, pid: window.pid, element: $0) }
    }

    /// Runs `work` for each window on its Accessibility element: apps in parallel, each app's
    /// windows in order. Blocks until all are done, at most about one messaging timeout.
    private func perApp<T: Sendable>(_ handles: [WindowHandle],
                                     _ work: @escaping @Sendable (CGWindowID, AXUIElement) -> T?) -> [CGWindowID: T] {
        guard isTrusted, !handles.isEmpty else { return [:] }
        var groups: [pid_t: [WindowHandle]] = [:]
        for handle in handles { groups[handle.pid, default: []].append(handle) }
        let batches = Array(groups.values)
        let results = Mutex<[CGWindowID: T]>([:])
        DispatchQueue.concurrentPerform(iterations: batches.count) { index in
            for handle in batches[index] {
                guard let result = work(handle.id, handle.element) else { continue }
                results.withLock { $0[handle.id] = result }
            }
        }
        return results.withLock { $0 }
    }

    /// The focused window of the frontmost app, if it's one we list.
    public func focusedWindowID() -> CGWindowID? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        guard let focused = AX.value(root, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return AX.windowID(focused as! AXUIElement)
    }

    /// Since macOS 14 an app can only activate another by yielding to it while it's active itself,
    /// so after the first app of a group comes forward that stops working. Setting `AXFrontmost`
    /// through Accessibility has no such limit; `activate` covers apps that ignore it.
    @discardableResult
    private func activate(_ pid: pid_t, allWindows: Bool = true) -> Bool {
        var viaAX = false
        if allWindows {
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.25)
            viaAX = AXUIElementSetAttributeValue(root, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return viaAX }
        NSApp.yieldActivation(to: app)
        return app.activate() || viaAX
    }

    // MARK: Listing

    private static func regularApps() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
        }
    }

    /// Lists `app`'s windows into the ledger; returns the ones that are new.
    private func relist(_ app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        // A hung app would otherwise stall the main thread for the default 6 s.
        AXUIElementSetMessagingTimeout(root, 0.25)
        observe(pid, root)
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
        var windows: [WindowInfo] = []
        for id in ledger.byApp[pid]?.map(\.id) ?? [] { elements[id] = nil }
        for element in AX.elements(root, kAXWindowsAttribute) {
            guard AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                  let id = AX.windowID(element) else { continue }
            // A hung app must not hold a switch for the default 6 s.
            AXUIElementSetMessagingTimeout(element, 0.25)
            elements[id] = element
            observeWindow(pid, element)
            windows.append(WindowInfo(
                id: id, pid: pid, bundleID: app.bundleIdentifier, appName: name,
                title: AX.string(element, kAXTitleAttribute) ?? "",
                document: AX.document(element), frame: AX.frame(element),
                isMinimized: AX.bool(element, kAXMinimizedAttribute) ?? false
            ))
        }
        return ledger.update(pid, windows: windows, launchedSinceStart: launched.contains(pid))
    }

    private func publish(_ appeared: [WindowInfo]) {
        let all = ledger.all
        let changed = all != windows
        if changed { windows = all }
        if !appeared.isEmpty { onAppear?(appeared) }
        if changed { onChange?(all) }
    }

    private func element(for window: WindowInfo) -> AXUIElement? {
        if let element = elements[window.id] { return element }
        let root = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(root, 0.25)
        return AX.elements(root, kAXWindowsAttribute).first { AX.windowID($0) == window.id }
    }

    fileprivate func focusChanged() {
        guard let id = focusedWindowID() else { return }
        onFocusChange?(id)
    }

    private func forget(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        launched.remove(pid)
        pending.remove(pid)
        for id in ledger.byApp[pid]?.map(\.id) ?? [] { elements[id] = nil }
        ledger.remove(pid)
        publish([])
    }

    // MARK: Observing

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
    ]
    /// Sent by the window itself, so registered per window. Registering again is a harmless error.
    private static let windowNotifications = [
        kAXTitleChangedNotification, kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    private func observe(_ pid: pid_t, _ root: AXUIElement) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.appNotifications {
            AXObserverAddNotification(observer, root, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func observeWindow(_ pid: pid_t, _ window: AXUIElement) {
        guard let observer = observers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
    }

    /// Relists `pid` once its burst of notifications settles.
    fileprivate func schedule(_ pid: pid_t) {
        pending.insert(pid)
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            self?.flushPending()
        }
    }

    private func flushPending() {
        flush = nil
        let pids = pending
        pending = []
        guard AXIsProcessTrusted() else { return }
        var appeared: [WindowInfo] = []
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  app.activationPolicy == .regular else { continue }
            appeared += relist(app)
        }
        publish(appeared)
    }
}

/// A window's Accessibility element, kept: it stays valid while the window exists, listed or
/// not. Sendable because the C API may be called from any thread, one at a time per element.
public struct WindowHandle: @unchecked Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    let element: AXUIElement
}

/// Runs on the main run loop, where every observer's source is added.
private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }
    let inventory = Unmanaged<WindowInventory>.fromOpaque(refcon).takeUnretainedValue()
    let isFocus = notification as String == kAXFocusedWindowChangedNotification as String
        || notification as String == kAXMainWindowChangedNotification as String
    MainActor.assumeIsolated {
        inventory.schedule(pid)
        if isFocus { inventory.focusChanged() }
    }
}
