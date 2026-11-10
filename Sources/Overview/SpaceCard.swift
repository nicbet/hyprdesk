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

/// Where a card's windows go on its miniature desktop: a main-and-stack layout, as tiling
/// window managers have it. The frontmost window takes the left half; the others share the
/// right half, one above another, in two columns once there are more than three of them. Real
/// sizes and positions don't count: on macOS windows mostly overlap, and drawn where they
/// really sit, the frontmost hides the rest. Every card fills its miniature the same way.
public enum MiniDesktop {
    public struct Tiles: Equatable, Sendable {
        /// One per window shown, frontmost first: the first `frames.count` of the card's windows.
        public var frames: [CGRect]
        /// The last tile, for the windows that didn't get one, and how many those are.
        public var overflow: (frame: CGRect, count: Int)?

        public static func == (a: Tiles, b: Tiles) -> Bool {
            a.frames == b.frames && a.overflow?.frame == b.overflow?.frame && a.overflow?.count == b.overflow?.count
        }
    }

    /// Tiles for `count` windows over a miniature `size`; at most `maxTiles`, the last of them
    /// "+N" when there are more windows than that.
    public static func tiles(count: Int, in size: CGSize, inset: CGFloat = 6, spacing: CGFloat = 6, maxTiles: Int = 7) -> Tiles {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return Tiles(frames: []) }
        if count == 1 { return Tiles(frames: [bounds]) }

        let tiles = min(count, max(2, maxTiles))
        let half = (bounds.width - spacing) / 2
        let main = CGRect(x: bounds.minX, y: bounds.minY, width: half, height: bounds.height)
        let stack = CGRect(x: main.maxX + spacing, y: bounds.minY, width: half, height: bounds.height)

        // The stack: one column up to three, else two; a last tile alone in its row spans both.
        let others = tiles - 1
        let columns = others <= 3 ? 1 : 2
        let rows = (others + columns - 1) / columns
        let height = (stack.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        let width = (stack.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        var frames = [main]
        for index in 0..<others {
            let row = index / columns, column = index % columns
            let alone = column == 0 && index == others - 1
            frames.append(CGRect(x: stack.minX + CGFloat(column) * (width + spacing), y: stack.minY + CGFloat(row) * (height + spacing),
                                 width: alone ? stack.width : width, height: height))
        }
        guard count > tiles else { return Tiles(frames: frames) }
        let last = frames.removeLast()
        return Tiles(frames: frames, overflow: (last, count - frames.count))
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
