import Foundation
import Testing
import WindowKit
@testable import Spaces

@MainActor
@Suite struct SpaceStoreTests {
    let now = Date.now

    func window(_ id: UInt32, _ title: String, app: String = "Figma", document: String? = nil) -> WindowInfo {
        WindowInfo(id: id, pid: 1, bundleID: "com.example.\(app)", appName: app, title: title,
                   document: document.map { URL(fileURLWithPath: $0) })
    }

    func twoSpaces(file: URL? = nil) -> (SpaceStore, Space, Space) {
        let store = SpaceStore(fileURL: file)
        let a = store.addSpace(name: "a")
        let b = store.addSpace(name: "b")
        return (store, a, b)
    }

    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hyprdesk-\(UUID()).json")
    }

    let never: (WindowInfo) -> Bool = { _ in false }
    let always: (WindowInfo) -> Bool = { _ in true }

    @Test func theFirstWorkspaceIsCurrent() {
        let (store, a, _) = twoSpaces()
        #expect(store.activeSpaceID == a.id)
    }

    @Test func windowsJoinTheCurrentWorkspace() {
        let (store, a, b) = twoSpaces()
        let one = window(1, "x")
        store.place([one], restoring: never)
        store.activeSpaceID = b.id
        let two = window(2, "y")
        store.place([two], restoring: never)
        #expect(store.placement(of: one) == WindowAssignment(.space(a.id), .openedHere))
        #expect(store.placement(of: two) == WindowAssignment(.space(b.id), .openedHere))
    }

    @Test func aPlacementIsKeptWhenTheTitleChanges() {
        let (store, a, b) = twoSpaces()
        store.place([window(1, "~/p/a — zsh", app: "Ghostty")], restoring: never)
        store.activeSpaceID = b.id
        store.place([window(1, "~/p/b — zsh", app: "Ghostty")], restoring: always)
        #expect(store.placement(of: window(1, "~/p/b — zsh", app: "Ghostty"))?.spaceID == a.id)
    }

    @Test func onlyTheCurrentWorkspaceAndStickyWindowsShow() {
        let (store, a, b) = twoSpaces()
        store.setSticky("com.example.Slack", true, windows: [])
        let inA = window(1, "x")
        store.place([inA], restoring: never)
        store.activeSpaceID = b.id
        let inB = window(2, "y"), slack = window(3, "general", app: "Slack")
        store.place([inB, slack], restoring: never)
        #expect(!store.isShown(inA) && store.isShown(inB) && store.isShown(slack))
        store.activeSpaceID = a.id
        #expect(store.isShown(inA) && !store.isShown(inB) && store.isShown(slack))
    }

    @Test func everyWindowIsRememberedAcrossAHyprDeskRestart() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let (store, _, b) = twoSpaces(file: file)
        store.activeSpaceID = b.id
        store.place([window(7, "~ — zsh", app: "Ghostty")], restoring: never)
        store.flush()

        let restarted = SpaceStore(fileURL: file)
        restarted.activeSpaceID = restarted.spaces[0].id
        // Same window ID, and by now another title: still found, exactly.
        let sameWindow = window(7, "~/code — vim", app: "Ghostty")
        restarted.place([sameWindow], restoring: always)
        #expect(restarted.placement(of: sameWindow)?.spaceID == b.id)
    }

    @Test func aRelaunchedAppsWindowsFindTheirWorkspacesBack() {
        let (store, _, b) = twoSpaces()
        store.activeSpaceID = b.id
        store.place([window(1, "x", app: "Sketch", document: "/d/onboarding.sketch")], restoring: never)
        store.windowsChanged([], runningApps: [], now: now)  // Sketch quit
        store.activeSpaceID = store.spaces[0].id

        let reopened = window(50, "onboarding", app: "Sketch", document: "/d/onboarding.sketch")
        store.place([reopened], restoring: always)
        #expect(store.placement(of: reopened)?.spaceID == b.id)
    }

    @Test func aBrandNewWindowNeverInheritsAnOldRecord() {
        let (store, a, b) = twoSpaces()
        store.activeSpaceID = b.id
        store.place([window(1, "~ — zsh", app: "Ghostty")], restoring: never)
        store.windowsChanged([], runningApps: [], now: now)
        store.activeSpaceID = a.id
        let fresh = window(2, "~ — zsh", app: "Ghostty")
        store.place([fresh], restoring: never)
        #expect(store.placement(of: fresh)?.spaceID == a.id)
    }

    @Test func aClosedWindowIsForgottenButAQuitAppsAreKept() {
        let (store, _, b) = twoSpaces()
        store.activeSpaceID = b.id
        store.place([window(1, "closed", app: "Ghostty"), window(2, "quit", app: "Sketch")], restoring: never)
        // Both windows go; Ghostty keeps running, Sketch quits.
        store.windowsChanged([], runningApps: ["com.example.Ghostty"], now: now)
        store.windowsChanged([], runningApps: ["com.example.Ghostty"], now: now + SpaceStore.closedGrace + 1)
        store.activeSpaceID = store.spaces[0].id
        let ghostty = window(10, "closed", app: "Ghostty"), sketch = window(11, "quit", app: "Sketch")
        store.place([ghostty, sketch], restoring: always)
        #expect(store.placement(of: ghostty)?.spaceID == store.spaces[0].id)
        #expect(store.placement(of: sketch)?.spaceID == b.id)
    }

    @Test func aQuittingAppsClosingWindowsAreNotForgottenRightAway() {
        let (store, _, b) = twoSpaces()
        store.activeSpaceID = b.id
        store.place([window(1, "doc", app: "Sketch")], restoring: never)
        // Its windows close a moment before the app is gone.
        store.windowsChanged([], runningApps: ["com.example.Sketch"], now: now)
        store.windowsChanged([], runningApps: [], now: now + 2)
        store.activeSpaceID = store.spaces[0].id
        let back = window(9, "doc", app: "Sketch")
        store.place([back], restoring: always)
        #expect(store.placement(of: back)?.spaceID == b.id)
    }

    @Test func unclaimedRecordsAreForgottenAfterDays() {
        let (store, _, b) = twoSpaces()
        store.activeSpaceID = b.id
        store.place([window(1, "doc", app: "Sketch")], restoring: never, now: now)
        store.windowsChanged([], runningApps: [], now: now + SpaceStore.forgetAfter + 1)
        store.activeSpaceID = store.spaces[0].id
        let back = window(9, "doc", app: "Sketch")
        store.place([back], restoring: always)
        #expect(store.placement(of: back)?.spaceID == store.spaces[0].id)
    }

    @Test func titlesAreKeptUpToDateForRestoring() {
        let (store, _, b) = twoSpaces()
        store.activeSpaceID = b.id
        store.place([window(1, "first", app: "Ghostty")], restoring: never)
        store.windowsChanged([window(1, "latest", app: "Ghostty")], runningApps: ["com.example.Ghostty"], now: now)
        store.windowsChanged([], runningApps: [], now: now)
        store.activeSpaceID = store.spaces[0].id
        let back = window(5, "latest", app: "Ghostty")
        store.place([back], restoring: always)
        #expect(store.placement(of: back)?.spaceID == b.id)
    }

    @Test func movingByHand() {
        let (store, _, b) = twoSpaces()
        let figma = window(1, "Onboarding flow")
        store.place([figma], restoring: never)
        store.move(figma, to: .space(b.id))
        #expect(store.placement(of: figma) == WindowAssignment(.space(b.id), .manual))
        store.move(figma, to: .everywhere)
        #expect(store.placement(of: figma) == WindowAssignment(.everywhere, .manual) && store.isShown(figma))
    }

    @Test func theScratchpadShowsOnlyWhenToggledAndIsRemembered() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let (store, _, b) = twoSpaces(file: file)
        let notes = window(3, "Notes", app: "Notes")
        store.place([notes], restoring: never)
        store.move(notes, to: .scratchpad)
        #expect(!store.isShown(notes))
        store.isScratchpadShown = true
        #expect(store.isShown(notes))
        store.activeSpaceID = b.id
        #expect(store.isShown(notes))  // over whichever workspace is on screen

        let restarted = SpaceStore(fileURL: file)
        restarted.place([notes], restoring: always)
        #expect(restarted.placement(of: notes) == WindowAssignment(.scratchpad, .manual))
        #expect(!restarted.isShown(notes))
    }

    @Test func stickyAppsGoEverywhereAndBack() {
        let (store, a, _) = twoSpaces()
        let slack = window(1, "general", app: "Slack")
        store.place([slack], restoring: never)
        store.setSticky(slack.appKey, true, windows: [slack])
        #expect(store.placement(of: slack) == WindowAssignment(.everywhere, .stickyApp))
        store.setSticky(slack.appKey, false, windows: [slack])
        #expect(store.placement(of: slack)?.spaceID == a.id)
    }

    @Test func removingAWorkspaceMovesItsWindowsToTheCurrentOne() {
        let (store, a, b) = twoSpaces()
        store.activeSpaceID = b.id
        let inB = window(1, "x")
        store.place([inB], restoring: never)
        store.activeSpaceID = a.id
        store.removeSpace(b.id)
        #expect(store.placement(of: inB)?.spaceID == a.id)
        store.removeSpace(a.id)
        #expect(store.activeSpaceID == nil && store.placement(of: inB) == nil && store.isShown(inB))
    }

    @Test func withoutWorkspacesEverythingShows() {
        let store = SpaceStore(fileURL: nil)
        let figma = window(1, "Onboarding flow")
        store.place([figma], restoring: always)
        #expect(store.placement(of: figma) == nil && store.isShown(figma))
    }

    @Test func savesAndLoads() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let (store, a, b) = twoSpaces(file: file)
        store.activeSpaceID = b.id
        store.move(window(1, "Onboarding flow"), to: .space(a.id))
        store.setSticky("com.example.Slack", true, windows: [])

        let loaded = SpaceStore(fileURL: file)
        #expect(loaded.spaces == [a, b])
        #expect(loaded.activeSpaceID == b.id)
        #expect(loaded.stickyApps == ["com.example.Slack"])
        let relaunched = window(7, "Onboarding flow")
        loaded.place([relaunched], restoring: always)
        #expect(loaded.placement(of: relaunched) == WindowAssignment(.space(a.id), .manual))
    }

    @Test func reordering() {
        let store = SpaceStore(fileURL: nil)
        let a = store.addSpace(name: "a"), b = store.addSpace(name: "b"), c = store.addSpace(name: "c")
        store.moveSpace(c.id, before: a.id)
        #expect(store.spaces.map(\.name) == ["c", "a", "b"])
        store.moveSpace(c.id, before: nil)
        #expect(store.spaces.map(\.name) == ["a", "b", "c"])
        store.moveSpace(a.id, before: c.id)
        #expect(store.spaces.map(\.name) == ["b", "a", "c"])
        store.moveSpace(b.id, before: b.id)
        #expect(store.spaces.map(\.name) == ["b", "a", "c"])
    }
}
