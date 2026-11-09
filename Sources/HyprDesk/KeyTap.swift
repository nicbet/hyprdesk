import AppKit

/// One system-wide event tap for the keys HyprDesk takes over from the Dock (⌘Tab, the ⌃-arrows): it
/// sees key presses before the Dock does and can swallow them. Needs the Accessibility
/// permission. Handlers are asked in order; the first to return true swallows the event.
///
/// It's also HyprDesk's hyper key (see `HyperKey`): while F18 is held, every other key comes with
/// ⌃⌥⌘ added, for every app, and F18 itself goes nowhere.
@MainActor
final class KeyTap {
    typealias Handler = (_ type: CGEventType, _ keyCode: Int64, _ flags: CGEventFlags) -> Bool

    private var handlers: [Handler] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }
    /// F18 is the hyper key (`HyperKey` remapped one onto it).
    var hyperEnabled = false {
        didSet { if !hyperEnabled { hyperHeld = false } }
    }
    private var hyperHeld = false
    static let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    func add(_ handler: @escaping Handler) {
        handlers.append(handler)
    }

    /// Installs the tap; false without Accessibility (try again once it's allowed).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let events: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: keyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    /// True: swallow the event. May add the hyper modifiers to `event` first.
    fileprivate func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns a slow tap off; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if hyperEnabled, keyCode == HyperKey.f18KeyCode, type == .keyDown || type == .keyUp {
            hyperHeld = type == .keyDown  // repeats while held change nothing
            return true
        }
        if hyperHeld { event.flags.formUnion(Self.hyperFlags) }
        let flags = event.flags
        return handlers.contains { $0(type, keyCode, flags) }
    }
}

/// Runs on the main run loop, where the tap's source is added.
private let keyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
    // The callback already runs on the main thread (the source is on the main run loop).
    nonisolated(unsafe) let event = event
    let swallow = MainActor.assumeIsolated { tap.handle(type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
