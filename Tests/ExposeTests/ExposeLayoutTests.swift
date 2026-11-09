import CoreGraphics
import Testing
@testable import Expose

@Suite struct ExposeLayoutTests {
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    @Test func oneWindowStaysItsSizeCentered() {
        let result = ExposeLayout.layout([CGRect(x: 0, y: 0, width: 800, height: 600)], in: screen, labelHeight: 0)
        #expect(result.rows == 1 && result.columns == 1)
        #expect(result.frames == [CGRect(x: 400, y: 200, width: 800, height: 600)])
    }

    @Test func wideScreenTwoWindowsSideBySide() {
        let windows = [CGRect(x: 0, y: 0, width: 1400, height: 900), CGRect(x: 200, y: 50, width: 1400, height: 900)]
        let result = ExposeLayout.layout(windows, in: screen)
        #expect(result.rows == 1 && result.columns == 2)
        #expect(result.frames[0].maxX <= result.frames[1].minX)
        #expect(result.frames.allSatisfy { screen.contains($0) })
    }

    @Test func manyWindowsWrapIntoRowsTopRowFirst() {
        let windows = (0..<7).map { CGRect(x: CGFloat($0 % 4) * 300, y: CGFloat($0 / 4) * 500, width: 600, height: 400) }
        let result = ExposeLayout.layout(windows, in: screen)
        #expect(result.rows * result.columns >= 7)
        #expect(result.rows > 1)
        // The window at the top left of the screen lands in the top row, leftmost.
        #expect(result.frames[0].minY == result.frames.map(\.minY).min())
        #expect(result.frames[0].minX <= result.frames[1].minX)
        #expect(result.frames.allSatisfy { screen.contains($0) })
        // No overlaps.
        for i in result.frames.indices {
            for j in result.frames.indices where i < j { #expect(!result.frames[i].intersects(result.frames[j])) }
        }
    }

    @Test func neighborsByDirection() {
        //  0 1 2
        //  3   4
        let frames = [(0, 0), (1, 0), (2, 0), (0, 1), (2, 1)].map { CGRect(x: $0.0 * 100, y: $0.1 * 100, width: 80, height: 80) }
        #expect(ExposeLayout.neighbor(of: 0, .right, in: frames) == 1)
        #expect(ExposeLayout.neighbor(of: 1, .down, in: frames) == 3 || ExposeLayout.neighbor(of: 1, .down, in: frames) == 4)
        #expect(ExposeLayout.neighbor(of: 2, .down, in: frames) == 4)
        #expect(ExposeLayout.neighbor(of: 4, .left, in: frames) == 3)
        #expect(ExposeLayout.neighbor(of: 3, .up, in: frames) == 0)
        #expect(ExposeLayout.neighbor(of: 0, .left, in: frames) == 0)
    }

    @Test func identicalFramesKeepTheirCellsWhateverTheInputOrder() {
        let maximized = CGRect(x: 0, y: 25, width: 1600, height: 975)
        let ids: [UInt32] = [30, 10, 20, 40]
        let a = ExposeLayout.layout([maximized, maximized, maximized, maximized], ids: ids, in: screen)
        let shuffled: [UInt32] = [20, 40, 10, 30]
        let b = ExposeLayout.layout([maximized, maximized, maximized, maximized], ids: shuffled, in: screen)
        for (index, id) in ids.enumerated() {
            #expect(a.frames[index] == b.frames[shuffled.firstIndex(of: id)!])
        }
    }

    @Test func theWindowYouCameFromTakesTheMiddleCell() {
        let window = CGRect(x: 0, y: 0, width: 600, height: 400)
        let five = ExposeLayout.layout(Array(repeating: window, count: 5), ids: [1, 2, 3, 4, 5], centering: 4, in: screen)
        let middle = five.frames[4]
        // Nearest the screen's center of all cells.
        let distance = { (r: CGRect) in hypot(r.midX - 800, r.midY - 500) }
        #expect(five.frames.allSatisfy { distance(middle) <= distance($0) + 0.5 })
        #expect(ExposeLayout.middleCell(count: 3, rows: 1, columns: 3) == 1)
        #expect(ExposeLayout.middleCell(count: 9, rows: 3, columns: 3) == 4)
        #expect(ExposeLayout.middleCell(count: 4, rows: 1, columns: 4) == 1)
    }
}
