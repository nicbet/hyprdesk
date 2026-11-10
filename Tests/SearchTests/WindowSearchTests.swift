import CoreGraphics
import Foundation
import Testing
import WindowKit
@testable import Search

@MainActor
@Suite struct WindowSearchTests {
    func candidate(_ id: UInt32, _ app: String, _ title: String, place: String? = "Work") -> SearchCandidate {
        SearchCandidate(window: WindowInfo(id: id, pid: 1, appName: app, title: title), place: place, placeIndex: 0)
    }

    @Test func everyWordMustMatchSomewhere() {
        let ghostty = candidate(1, "Ghostty", "~/code/hyprdesk — make dev")
        #expect(WindowSearch.score(ghostty, query: "ghost make") != nil)
        #expect(WindowSearch.score(ghostty, query: "work hyprdesk") != nil)  // the workspace's name counts
        #expect(WindowSearch.score(ghostty, query: "ghost safari") == nil)
    }

    @Test func wordStartsBeatInsideAndAppNamesWinTies() {
        let results = WindowSearch.rank([
            candidate(1, "Safari", "Pasta recipes"),     // "sta" inside a word
            candidate(2, "Notes", "Standup notes"),      // a word starting "sta"
            candidate(3, "Stash", "main"),               // an app starting "sta"
        ], query: "sta")
        #expect(results.map(\.id) == [3, 2, 1])
    }

    @Test func caseAndAccentsDontMatter() {
        #expect(WindowSearch.score(candidate(1, "Notes", "Café plans"), query: "CAFE") != nil)
    }

    @Test func anEmptyQueryKeepsTheRecentOrder() {
        let list = [candidate(5, "A", "x"), candidate(2, "B", "y"), candidate(9, "C", "z")]
        #expect(WindowSearch.rank(list, query: "  ").map(\.id) == [5, 2, 9])
    }

    @Test func theModelSelectsWrapsAndPicks() {
        let model = SearchModel()
        var picked: CGWindowID?
        model.onPick = { picked = $0.id }
        model.begin([candidate(1, "Ghostty", "zsh"), candidate(2, "Safari", "Docs"), candidate(3, "Slack", "general")])
        model.query = "s"
        #expect(model.results.count == 3)
        model.move(-1)
        #expect(model.selection == 2)
        model.query = "saf"
        #expect(model.selection == 0 && model.results.map(\.id) == [2])
        model.pick()
        #expect(picked == 2)
    }

    @Test func writingTheSameQueryBackKeepsTheSelection() {
        let model = SearchModel()
        var picked: CGWindowID?
        model.onPick = { picked = $0.id }
        model.begin([candidate(1, "Ghostty", "zsh"), candidate(2, "Safari", "Docs"), candidate(3, "Slack", "general")])
        model.query = "s"
        model.move(1)
        model.query = "s"  // what the text field does on Return
        model.pick()
        #expect(picked == model.results[1].id)
    }
}
