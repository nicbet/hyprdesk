import Foundation
import Observation
import WindowKit

/// The space switcher's state: the windows on offer, most recently used first, and which one is
/// selected. Driven by keys (⌘Tab cycles, release commits); knows nothing about event taps.
@MainActor
@Observable
public final class SwitcherModel {
    public private(set) var windows: [WindowInfo] = []
    public private(set) var selection = 0
    /// Shown while it's up: the space's name.
    public private(set) var title = ""
    public private(set) var isActive = false
    /// How wide the HUD may get (most of the screen it shows on); icons shrink to fit.
    public var maxWidth: CGFloat = 1600
    /// Hover selects only after the pointer has moved (see `PointerGate`): the HUD appearing
    /// under a resting pointer mustn't take the selection from ⌘Tab.
    @ObservationIgnored public var pointer = PointerGate()

    public init() {}

    /// Starts a round on `windows` (most recent first) with the previous window selected, as
    /// ⌘Tab does: one quick tap goes back to where you were. `pointer`: where the mouse is now.
    public func begin(_ windows: [WindowInfo], title: String, pointer location: CGPoint) {
        pointer.reset(at: location)
        self.windows = windows
        self.title = title
        selection = windows.count > 1 ? 1 : 0
        isActive = true
    }

    public func next() { step(1) }
    public func previous() { step(-1) }

    /// The pointer, at `location`, is over the icon at `index`: selects it once the pointer has
    /// moved since the round began.
    public func hover(_ index: Int, at location: CGPoint) {
        guard pointer.allows(at: location) else { return }
        select(index)
    }

    public func select(_ index: Int) {
        guard windows.indices.contains(index) else { return }
        selection = index
    }

    /// Ends the round; the chosen window, if there is one.
    public func commit() -> WindowInfo? {
        defer { cancel() }
        return windows.indices.contains(selection) ? windows[selection] : nil
    }

    public func cancel() {
        isActive = false
    }

    private func step(_ delta: Int) {
        guard !windows.isEmpty else { return }
        selection = (selection + delta + windows.count) % windows.count
    }
}
