import Foundation
import Spaces
import Testing
import WindowKit
@testable import Overview

@MainActor
@Suite struct SpaceCardTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func window(_ id: UInt32, _ title: String, app: String = "Terminal") -> WindowInfo {
        WindowInfo(id: id, pid: 1, bundleID: "com.example.\(app)", appName: app, title: title)
    }

    @Test func oneCardPerSpaceWithTheSharedApps() {
        let store = SpaceStore(fileURL: nil)
        store.addSpace(name: "a")
        let b = store.addSpace(name: "b")
        store.setSticky("com.example.Mail", true, windows: [])
        // Opened while "a" is active; Mail shows everywhere.
        let windows = [window(1, "~/p/a — zsh"), window(2, "Inbox", app: "Mail"), window(3, "/p/a/README")]
        store.place(windows, restoring: { _ in false })
        store.activeSpaceID = b.id
        let cards = SpaceCard.make(spaces: store, windows: windows, order: [3: 0, 2: 1, 1: 2])
        // Mail shows everywhere: no card of its own, its app on every workspace's.
        #expect(cards.map(\.name) == ["a", "b"])
        #expect(cards[0].windows.map(\.id) == [3, 1])
        #expect(cards[1].isActive && cards[1].windows.isEmpty)
        #expect(cards.allSatisfy { $0.sharedApps.map(\.id) == [2] })
    }

    @Test func theScratchpadComesLastWhenItHoldsWindows() {
        let store = SpaceStore(fileURL: nil)
        store.addSpace(name: "a")
        let notes = window(1, "Notes"), slack = window(2, "general", app: "Slack")
        store.place([notes, slack], restoring: { _ in false })
        store.move(notes, to: .scratchpad)
        store.move(slack, to: .everywhere)
        let cards = SpaceCard.make(spaces: store, windows: [notes, slack])
        #expect(cards.map(\.name) == ["a", "Scratchpad"])
        #expect(cards[1].isScratchpad && cards[1].windows.map(\.id) == [1] && cards[1].shared.isEmpty)
        #expect(cards[0].windows.isEmpty && cards[0].sharedApps.map(\.id) == [2])
        // Emptied: no card.
        store.move(notes, to: .space(store.spaces[0].id))
        #expect(SpaceCard.make(spaces: store, windows: [notes, slack]).map(\.name) == ["a"])
    }

    @Test func onlyWorkspacesWhenNothingIsShared() {
        let store = SpaceStore(fileURL: nil)
        store.addSpace(name: "a")
        store.place([window(1, "/p/a")], restoring: { _ in false })
        let cards = SpaceCard.make(spaces: store, windows: [window(1, "/p/a")])
        #expect(cards.map(\.name) == ["a"])
    }

    @Test func miniaturesPlaceWindowsOnTheirOwnScreen() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 500), right = CGRect(x: 1000, y: 0, width: 800, height: 400)
        let size = CGSize(width: 200, height: 100)
        // Left half of the main screen.
        #expect(MiniDesktop.frame(of: CGRect(x: 0, y: 0, width: 500, height: 500), screens: [main, right], in: size)
                == CGRect(x: 0, y: 0, width: 100, height: 100))
        // The right half of the other screen lands on the right half of the miniature.
        #expect(MiniDesktop.frame(of: CGRect(x: 1400, y: 0, width: 400, height: 400), screens: [main, right], in: size)
                == CGRect(x: 100, y: 0, width: 100, height: 100))
        // Hanging off the edge: clipped.
        #expect(MiniDesktop.frame(of: CGRect(x: 900, y: 0, width: 200, height: 100), screens: [main], in: size)?.maxX == 200)
    }

    @Test func appsByWindowCountThenName() {
        let windows = [window(1, "", app: "Zed"), window(2, "", app: "Arc"), window(3, "", app: "Zed"), window(4, "", app: "Code")]
        let card = SpaceCard(space: nil, windows: windows, isActive: false)
        #expect(card.apps.map { $0.windows[0].appName } == ["Zed", "Arc", "Code"])
    }

    @Test func gridNavigation() {
        // 5 cards in 3 columns:  0 1 2
        //                        3 4
        #expect(GridNavigation.move(from: 0, .left, count: 5, columns: 3) == 4)
        #expect(GridNavigation.move(from: 4, .right, count: 5, columns: 3) == 0)
        #expect(GridNavigation.move(from: 1, .down, count: 5, columns: 3) == 4)
        #expect(GridNavigation.move(from: 2, .down, count: 5, columns: 3) == 2)
        #expect(GridNavigation.move(from: 4, .up, count: 5, columns: 3) == 1)
        #expect(GridNavigation.move(from: 0, .up, count: 5, columns: 3) == 0)
        #expect(GridNavigation.move(from: 9, .left, count: 5, columns: 3) == 3)
        #expect(GridNavigation.move(from: 0, .right, count: 0, columns: 3) == 0)
    }

    @Test func frontToBack() {
        let windows = [window(1, ""), window(2, ""), window(3, "")]
        #expect(WindowOrder.sorted(windows, by: [3: 0, 1: 5]).map(\.id) == [3, 1, 2])
    }

}
