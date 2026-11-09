import CoreGraphics
import Foundation
import Spaces
import WindowKit

/// One card in the overview: a workspace with its windows, or the scratchpad with its own.
/// Windows shown in every workspace get no card of their own: they come along everywhere, so a
/// workspace's card lists their apps (`shared`).
public struct SpaceCard: Identifiable, Equatable {
    /// The workspace, or nil for the scratchpad.
    public var space: Space?
    public var windows: [WindowInfo]
    /// On screen right now: the current workspace, or the scratchpad while it's up.
    public var isActive: Bool
    /// Windows shown in every workspace (none on the scratchpad's card).
    public var shared: [WindowInfo]

    public init(space: Space?, windows: [WindowInfo], isActive: Bool, shared: [WindowInfo] = []) {
        self.space = space
        self.windows = windows
        self.isActive = isActive
        self.shared = shared
    }

    public var isScratchpad: Bool { space == nil }
    public var id: String { space?.id.uuidString ?? "scratchpad" }
    public var name: String { space?.name ?? "Scratchpad" }

    /// Windows grouped by app, the app with most windows first; ties by name.
    public var apps: [(key: String, windows: [WindowInfo])] {
        Dictionary(grouping: windows, by: \.appKey)
            .map { (key: $0.key, windows: $0.value) }
            .sorted { ($0.windows.count, $1.windows[0].appName) > ($1.windows.count, $0.windows[0].appName) }
    }

    /// The apps of `shared`, one window each, frontmost first.
    public var sharedApps: [WindowInfo] {
        var seen = Set<String>()
        return shared.filter { seen.insert($0.appKey).inserted }
    }

    /// Builds the cards: one per workspace in order, then the scratchpad's when it holds any
    /// windows. Each card's windows are frontmost first (`order`, see `WindowOrder`).
    @MainActor
    public static func make(spaces: SpaceStore, windows: [WindowInfo], order: [CGWindowID: Int] = [:]) -> [SpaceCard] {
        var bySpace: [UUID: [WindowInfo]] = [:], shared: [WindowInfo] = [], scratchpad: [WindowInfo] = []
        for window in WindowOrder.sorted(windows, by: order) {
            switch spaces.placement(of: window)?.placement {
            case .space(let id): bySpace[id, default: []].append(window)
            case .everywhere: shared.append(window)
            case .scratchpad: scratchpad.append(window)
            case nil: break
            }
        }
        var cards = spaces.spaces.map { space in
            SpaceCard(space: space, windows: bySpace[space.id] ?? [], isActive: spaces.activeSpaceID == space.id, shared: shared)
        }
        if !scratchpad.isEmpty {
            cards.append(SpaceCard(space: nil, windows: scratchpad, isActive: spaces.isScratchpadShown))
        }
        return cards
    }
}

/// Where a window sits on a card's miniature desktop: each window is placed relative to the
/// screen holding it (with several screens, they share the one miniature).
public enum MiniDesktop {
    /// `frame` (Accessibility coordinates) on a miniature `size` of its screen; clipped to the
    /// miniature, nil when nothing of it is on a screen.
    public static func frame(of frame: CGRect, screens: [CGRect], in size: CGSize) -> CGRect? {
        guard let screen = ScreenGeometry.screen(for: frame, in: screens), screen.width > 0, screen.height > 0 else { return nil }
        let sx = size.width / screen.width, sy = size.height / screen.height
        let mini = CGRect(x: (frame.minX - screen.minX) * sx, y: (frame.minY - screen.minY) * sy,
                          width: frame.width * sx, height: frame.height * sy)
        let clipped = mini.intersection(CGRect(origin: .zero, size: size))
        return clipped.isNull || clipped.width < 1 || clipped.height < 1 ? nil : clipped
    }
}

public enum MoveDirection: Sendable {
    case left, right, up, down
}

/// Moving the selection around a grid filled row by row.
public enum GridNavigation {
    /// Left and right wrap through the rows; up and down stay in the column and stop at the edges.
    public static func move(from index: Int, _ direction: MoveDirection, count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        let columns = max(1, columns)
        let index = min(max(0, index), count - 1)
        switch direction {
        case .left: return (index - 1 + count) % count
        case .right: return (index + 1) % count
        case .up: return index - columns >= 0 ? index - columns : index
        case .down: return index + columns < count ? index + columns : index
        }
    }
}
