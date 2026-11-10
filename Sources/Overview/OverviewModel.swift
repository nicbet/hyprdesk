import CoreGraphics
import Foundation
import Observation
import Spaces
import WindowKit

/// What the overview shows and which card is selected. The app supplies the actions.
@MainActor
@Observable
public final class OverviewModel {
    private let live: (spaces: SpaceStore, inventory: WindowInventory)?
    private let sample: (cards: [SpaceCard], now: Date)
    /// The screens (Accessibility coordinates) the miniatures stand for; the first sets their shape.
    public private(set) var screens: [CGRect]

    public var selection = 0
    /// Set by the grid from its width, for up and down.
    public var columns = 1

    @ObservationIgnored public var onActivate: (SpaceCard) -> Void = { _ in }
    @ObservationIgnored public var onRaise: (WindowInfo) -> Void = { _ in }
    @ObservationIgnored public var onDismiss: () -> Void = {}

    public init(spaces: SpaceStore, inventory: WindowInventory) {
        live = (spaces, inventory)
        sample = ([], .now)
        screens = []
    }

    /// Fixed cards, for snapshots, on `screens`.
    public init(cards: [SpaceCard], now: Date, screens: [CGRect] = [CGRect(x: 0, y: 0, width: 1512, height: 982)]) {
        live = nil
        sample = (cards, now)
        self.screens = screens
    }

    /// Width over height of the miniatures: the main screen's.
    public var aspect: CGFloat {
        guard let main = screens.first, main.height > 0 else { return 16 / 10 }
        return main.width / main.height
    }

    /// Stacking order, read when the overview opens: windows don't move while it's up.
    private var order: [CGWindowID: Int] = [:]

    public var cards: [SpaceCard] {
        guard let live else { return sample.cards }
        return SpaceCard.make(spaces: live.spaces, windows: live.inventory.windows, order: order)
    }

    public var now: Date { live == nil ? sample.now : .now }

    /// Call before showing: rereads the stacking order and starts on the active space, else
    /// the first card.
    /// Hover selects only after the pointer has moved (see `PointerGate`).
    @ObservationIgnored public var pointer = PointerGate()

    public func reset() {
        order = WindowOrder.current()
        if live != nil { screens = ScreenGeometry.screens() }
        selection = cards.firstIndex(where: \.isActive) ?? 0
    }

    public func move(_ direction: MoveDirection) {
        selection = GridNavigation.move(from: selection, direction, count: cards.count, columns: columns)
    }

    /// Workspace `number` (1 = the first), as on ✦ 1–9: never the scratchpad's card.
    public func activateWorkspace(number: Int) {
        let cards = cards
        guard cards.indices.contains(number - 1), !cards[number - 1].isScratchpad else { return }
        onActivate(cards[number - 1])
    }

    /// Opens the selected card, or card `index` (0-based) when given.
    public func activate(_ index: Int? = nil) {
        let cards = cards
        let index = index ?? selection
        guard cards.indices.contains(index) else { return }
        onActivate(cards[index])
    }
}
