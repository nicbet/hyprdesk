import Foundation
import Observation

/// The app's settings: which macOS shortcuts HyprDesk takes over (saved, all on by default),
/// and whether it's suspended (for this run).
@MainActor
@Observable
final class Preferences {
    /// ⌘Tab shows the current workspace's windows instead of macOS's app switcher.
    var replacesCommandTab: Bool { didSet { save(replacesCommandTab, Self.commandTabKey) } }
    /// ⌃↑ opens the overview and ⌃↓ the workspace's Mission Control, instead of macOS's Mission
    /// Control and app windows.
    var replacesMissionControl: Bool { didSet { save(replacesMissionControl, Self.missionControlKey) } }
    /// ⌃← ⌃→ switch between workspaces instead of macOS's desktops.
    var replacesSpaceArrows: Bool { didSet { save(replacesSpaceArrows, Self.spaceArrowsKey) } }
    /// Which key HyprDesk turns into the hyper key (⌃⌥⌘), if any. Off by default: many people
    /// already have one (Raycast, Karabiner).
    var hyperKey: HyperKey {
        didSet {
            defaults.set(hyperKey.rawValue, forKey: Self.hyperKeyKey)
            onHyperKeyChange?()
        }
    }
    @ObservationIgnored var onHyperKeyChange: (() -> Void)?
    /// Every window on screen, no hiding, no shortcuts: macOS as if HyprDesk weren't running.
    var isSuspended = false

    private static let commandTabKey = "replacesCommandTab"
    private static let missionControlKey = "replacesMissionControl"
    private static let spaceArrowsKey = "replacesSpaceArrows"
    private static let hyperKeyKey = "hyperKey"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        replacesCommandTab = defaults.object(forKey: Self.commandTabKey) as? Bool ?? true
        replacesMissionControl = defaults.object(forKey: Self.missionControlKey) as? Bool ?? true
        replacesSpaceArrows = defaults.object(forKey: Self.spaceArrowsKey) as? Bool ?? true
        hyperKey = defaults.string(forKey: Self.hyperKeyKey).flatMap(HyperKey.init(rawValue:)) ?? .off
    }

    @ObservationIgnored private let defaults: UserDefaults

    private func save(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
