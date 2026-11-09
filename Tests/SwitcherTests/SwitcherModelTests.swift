import Foundation
import Testing
import WindowKit
@testable import Switcher
import Workspaces

@MainActor
@Suite struct SwitcherModelTests {
    func window(_ id: UInt32, minimized: Bool = false) -> WindowInfo {
        WindowInfo(id: id, pid: 1, appName: "App", title: "\(id)", isMinimized: minimized)
    }

    @Test func startsOnThePreviousWindowAndWraps() {
        let model = SwitcherModel()
        model.begin([window(1), window(2), window(3)], title: "a", pointer: .zero)
        #expect(model.selection == 1)
        model.next()
        model.next()
        #expect(model.selection == 0)
        model.previous()
        #expect(model.selection == 2)
        #expect(model.commit()?.id == 3)
        #expect(!model.isActive)
    }

    @Test func aRestingPointerDoesNotTakeTheSelection() {
        let model = SwitcherModel()
        model.begin([window(1), window(2), window(3)], title: "a", pointer: CGPoint(x: 100, y: 100))
        model.hover(2, at: CGPoint(x: 101, y: 100))
        #expect(model.selection == 1)
        model.hover(2, at: CGPoint(x: 120, y: 100))
        #expect(model.selection == 2)
        // A new round starts gated again.
        model.begin([window(1), window(2), window(3)], title: "a", pointer: CGPoint(x: 120, y: 100))
        model.hover(0, at: CGPoint(x: 120, y: 100))
        #expect(model.selection == 1)
    }

    @Test func aSingleWindowIsSelected() {
        let model = SwitcherModel()
        model.begin([window(1)], title: "a", pointer: .zero)
        #expect(model.selection == 0)
        #expect(model.commit()?.id == 1)
    }

    @Test func emptyCommitsNothing() {
        let model = SwitcherModel()
        model.begin([], title: "a", pointer: .zero)
        model.next()
        #expect(model.commit() == nil)
    }

    @Test func recentFirstThenStackingOrderMinimizedLast() {
        let windows = [window(1), window(2, minimized: true), window(3), window(4), window(5)]
        let ordered = SwitcherOrder.ordered(windows, recent: [4, 2, 1], fallback: [5: 0, 3: 1])
        #expect(ordered.map(\.id) == [4, 1, 5, 3, 2])
    }

    @Test func iconsShrinkToFitLikeTheSystemSwitcher() {
        #expect(SwitcherView.iconSize(count: 6, maxWidth: 1600) == 112)
        #expect(SwitcherView.iconSize(count: 20, maxWidth: 1600) == 58)
        #expect(SwitcherView.iconSize(count: 100, maxWidth: 1600) == 40)
    }
}
