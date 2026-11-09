import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon's `RegisterEventHotKey` is still the only API for this
/// that needs no Accessibility or Input Monitoring permission.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32

    /// Hyper (⌃⌥⌘) + `keyCode`, and the same with ⇧ for hyper keys that send all four
    /// modifiers: a hotkey only fires on an exact modifier match.
    static func hyper(_ keyCode: Int) -> [(keyCode: UInt32, modifiers: UInt32)] {
        [
            (UInt32(keyCode), UInt32(controlKey | optionKey | cmdKey)),
            (UInt32(keyCode), UInt32(controlKey | optionKey | cmdKey | shiftKey)),
        ]
    }

    static let space = kVK_Space
    static let s = kVK_ANSI_S
    static let tab = kVK_Tab
    /// The key above Tab (` on US layouts).
    static let grave = kVK_ANSI_Grave
    /// The digit keys 1–9, in order (their key codes aren't).
    static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// Registers hyper + `keyCode` (both variants); empty when another app has both.
    static func registerHyper(_ keyCode: Int, action: @escaping () -> Void) -> [HotKey] {
        hyper(keyCode).compactMap { HotKey(keyCode: $0.keyCode, modifiers: $0.modifiers, action: action) }
    }

    /// Registers exactly ⌃⌥⌘ + `keyCode`, or exactly ⌃⌥⌘⇧ + `keyCode` with `shift`: for keys
    /// where hyper and hyper + ⇧ do different things.
    static func register(hyperShift shift: Bool, _ keyCode: Int, action: @escaping () -> Void) -> HotKey? {
        let modifiers = controlKey | optionKey | cmdKey | (shift ? shiftKey : 0)
        return HotKey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), action: action)
    }

    private static var nextID: UInt32 = 1
    nonisolated static let signature = OSType(0x4153_5053)  // "ASPS"

    /// nil when the shortcut is taken by another app.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Every hotkey's handler sees every press; each answers only its own and passes the rest on.
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard pressed.signature == HotKey.signature, pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
                hotKey.action()
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { return nil }
        guard RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref) == noErr else {
            RemoveEventHandler(handlerRef)
            return nil
        }
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
