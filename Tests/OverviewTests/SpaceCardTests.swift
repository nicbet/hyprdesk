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

    @Test func theFrontmostWindowTakesTheLeftHalf() {
        let size = CGSize(width: 212, height: 112), bounds = CGRect(x: 6, y: 6, width: 200, height: 100)
        #expect(MiniDesktop.tiles(count: 0, in: size).frames.isEmpty)
        #expect(MiniDesktop.tiles(count: 1, in: size).frames == [bounds])
        // Three: the rest stacked on the right.
        #expect(MiniDesktop.tiles(count: 3, in: size).frames == [
            CGRect(x: 6, y: 6, width: 97, height: 100),
            CGRect(x: 109, y: 6, width: 97, height: 47), CGRect(x: 109, y: 59, width: 97, height: 47),
        ])
        // Five: two columns on the right, two rows.
        let five = MiniDesktop.tiles(count: 5, in: size).frames
        #expect(five.count == 5 && five[1...].allSatisfy { $0.width == 45.5 && $0.height == 47 })
        // Six: the last of the stack alone in its row, across both columns.
        #expect(MiniDesktop.tiles(count: 6, in: size).frames.last?.width == 97)
    }

    @Test func windowsBeyondTheTilesShareTheLastOne() {
        let size = CGSize(width: 212, height: 112)
        let seven = MiniDesktop.tiles(count: 7, in: size)
        #expect(seven.frames.count == 7 && seven.overflow == nil)
        // Ten: six windows, and "+4" where the seventh would be.
        let ten = MiniDesktop.tiles(count: 10, in: size)
        #expect(ten.frames == Array(seven.frames.prefix(6)))
        #expect(ten.overflow?.frame == seven.frames[6] && ten.overflow?.count == 4)
        // No tile overlaps another, and all stay on the miniature.
        let all = seven.frames
        for (i, tile) in all.enumerated() {
            #expect(CGRect(origin: .zero, size: size).contains(tile))
            for other in all[(i + 1)...] { #expect(!tile.intersects(other)) }
        }
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
