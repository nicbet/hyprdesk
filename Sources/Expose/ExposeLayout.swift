import CoreGraphics

/// Where each window's thumbnail goes, Mission Control style: a grid of rows, as many rows as
/// make the windows largest, each window scaled to fit its cell (never enlarged), windows kept
/// roughly where they are on screen (top rows first, left to right). Ties (maximized windows
/// share one frame) go by `ids`, so the same windows land in the same cells every time; the
/// `centering` window takes the middle cell.
public enum ExposeLayout {
    public struct Result: Equatable, Sendable {
        /// One per window, in the order given.
        public var frames: [CGRect]
        public var rows: Int
        public var columns: Int
    }

    /// `frames`: the windows' real frames (for their sizes and their order). `ids`: stable
    /// tie-breakers, one per frame. `centering`: the index of the window for the middle cell.
    /// `bounds`: the area to fill. `labelHeight`: room kept under each thumbnail, besides `spacing`:
    /// the app icon hangs 18 pt below a thumbnail and its title ends 54 pt below, and the
    /// selected thumbnail grows a little, so the default keeps a title clear of the row under it.
    public static func layout(_ frames: [CGRect], ids: [UInt32]? = nil, centering center: Int? = nil, in bounds: CGRect,
                              spacing: CGFloat = 28, labelHeight: CGFloat = 48) -> Result {
        let count = frames.count
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return Result(frames: [], rows: 0, columns: 0) }

        // The row count that gives the windows the most area.
        var best: (rows: Int, columns: Int, area: CGFloat) = (1, count, -1)
        for rows in 1...count {
            let columns = Int((Double(count) / Double(rows)).rounded(.up))
            guard (rows - 1) * columns < count else { continue }
            let cell = cellSize(rows: rows, columns: columns, in: bounds, spacing: spacing, labelHeight: labelHeight)
            guard cell.width > 0, cell.height > 0 else { continue }
            let area = frames.reduce(CGFloat(0)) { sum, frame in
                let scale = fit(frame.size, in: cell)
                return sum + frame.width * frame.height * scale * scale
            }
            if area > best.area { best = (rows, columns, area) }
        }

        // Top to bottom, then each row left to right; ties by id.
        let key = { (i: Int) in ids.map { CGFloat($0[i]) } ?? CGFloat(i) }
        let byTop = frames.indices.sorted { (frames[$0].midY, frames[$0].midX, key($0)) < (frames[$1].midY, frames[$1].midX, key($1)) }
        var order: [Int] = []
        for start in stride(from: 0, to: count, by: best.columns) {
            order += byTop[start..<min(start + best.columns, count)].sorted { (frames[$0].midX, key($0)) < (frames[$1].midX, key($1)) }
        }
        if let center, frames.indices.contains(center) {
            order.removeAll { $0 == center }
            order.insert(center, at: middleCell(count: count, rows: best.rows, columns: best.columns))
        }

        let cell = cellSize(rows: best.rows, columns: best.columns, in: bounds, spacing: spacing, labelHeight: labelHeight)
        var placed = [CGRect](repeating: .zero, count: count)
        let rowHeight = cell.height + labelHeight
        let totalHeight = CGFloat(best.rows) * rowHeight + CGFloat(best.rows - 1) * spacing
        var top = bounds.minY + (bounds.height - totalHeight) / 2
        for start in stride(from: 0, to: count, by: best.columns) {
            let row = order[start..<min(start + best.columns, count)]
            let width = CGFloat(row.count) * cell.width + CGFloat(row.count - 1) * spacing
            var left = bounds.minX + (bounds.width - width) / 2
            for index in row {
                let scale = fit(frames[index].size, in: cell)
                let size = CGSize(width: frames[index].width * scale, height: frames[index].height * scale)
                placed[index] = CGRect(x: left + (cell.width - size.width) / 2, y: top + (cell.height - size.height) / 2,
                                       width: size.width, height: size.height)
                left += cell.width + spacing
            }
            top += rowHeight + spacing
        }
        return Result(frames: placed, rows: best.rows, columns: best.columns)
    }

    /// From thumbnail `index`, the nearest one in `direction`, or `index` when there's none.
    /// Nearest by distance between centers, with sideways distance counting double so ↓ goes
    /// to the window below rather than one far off to the side.
    public static func neighbor(of index: Int, _ direction: Direction, in frames: [CGRect]) -> Int {
        guard frames.indices.contains(index) else { return frames.isEmpty ? 0 : 0 }
        let from = CGPoint(x: frames[index].midX, y: frames[index].midY)
        var best: (index: Int, cost: CGFloat)?
        for (candidate, frame) in frames.enumerated() where candidate != index {
            let dx = frame.midX - from.x, dy = frame.midY - from.y
            let (along, across): (CGFloat, CGFloat) = switch direction {
            case .left: (-dx, dy)
            case .right: (dx, dy)
            case .up: (-dy, dx)
            case .down: (dy, dx)
            }
            guard along > 1 else { continue }
            let cost = along + 2 * abs(across)
            if best == nil || cost < best!.cost { best = (candidate, cost) }
        }
        return best?.index ?? index
    }

    public enum Direction: Sendable {
        case left, right, up, down
    }

    /// The cell nearest the middle: the middle row, the middle of that row (left of center when
    /// it has an even count).
    static func middleCell(count: Int, rows: Int, columns: Int) -> Int {
        let row = (rows - 1) / 2
        let inRow = min(columns, count - row * columns)
        return row * columns + (inRow - 1) / 2
    }

    private static func cellSize(rows: Int, columns: Int, in bounds: CGRect, spacing: CGFloat, labelHeight: CGFloat) -> CGSize {
        CGSize(width: (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns),
               height: (bounds.height - CGFloat(rows - 1) * spacing) / CGFloat(rows) - labelHeight)
    }

    private static func fit(_ size: CGSize, in cell: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        return min(1, cell.width / size.width, cell.height / size.height)
    }
}
