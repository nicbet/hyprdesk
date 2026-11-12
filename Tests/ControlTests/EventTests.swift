import Foundation
import Testing
@testable import Control

@Suite struct EventTests {
    typealias W = EventState.Window
    let work = EventState.Workspace(id: "A", name: "Work")
    let mail = EventState.Workspace(id: "B", name: "Mail")

    func names(_ events: [JSON]) -> [String] {
        events.compactMap { if case .string(let name)? = $0["event"] { name } else { nil } }
    }

    @Test func nothingChangedNothingSent() {
        let state = EventState(workspaces: [work], active: "A", windows: [W(id: 1, app: "Code", title: "x", place: .workspace("A"))])
        #expect(EventState.events(from: state, to: state).isEmpty)
    }

    @Test func switchingSaysWhereFromAndTo() {
        let old = EventState(workspaces: [work, mail], active: "A")
        let new = EventState(workspaces: [work, mail], active: "B")
        let events = EventState.events(from: old, to: new)
        #expect(names(events) == ["workspace"])
        #expect(events[0]["workspace"]?["number"] == 2)
        #expect(events[0]["workspace"]?["name"] == "Mail")
        #expect(events[0]["previous"]?["number"] == 1)
    }

    @Test func windowsOpenCloseMoveAndRetitle() {
        let old = EventState(workspaces: [work, mail], active: "A", windows: [
            W(id: 1, app: "Code", title: "a.swift", place: .workspace("A")),
            W(id: 2, app: "Chrome", title: "Docs", place: .workspace("A")),
            W(id: 3, app: "Slack", title: "general", place: .workspace("A")),
        ])
        let new = EventState(workspaces: [work, mail], active: "A", windows: [
            W(id: 1, app: "Code", title: "b.swift", place: .workspace("A")),
            W(id: 3, app: "Slack", title: "general", place: .everywhere),
            W(id: 4, app: "Ghostty", title: "zsh", place: .workspace("A")),
        ])
        let events = EventState.events(from: old, to: new)
        #expect(names(events) == ["windowClosed", "windowTitle", "windowMoved", "windowOpened"])
        #expect(events[0]["window"]?["id"] == 2)
        #expect(events[1]["previousTitle"] == "a.swift")
        #expect(events[2]["from"] == 1)
        #expect(events[2]["window"]?["workspace"] == "everywhere")
        #expect(events[3]["window"]?["app"] == "Ghostty")
    }

    @Test func workspacesCreatedRenamedRemovedReordered() {
        let other = EventState.Workspace(id: "C", name: "Writing")
        var renamed = mail
        renamed.name = "Inbox"
        let old = EventState(workspaces: [work, mail, other], active: "A")
        let new = EventState(workspaces: [renamed, work, EventState.Workspace(id: "D", name: "New")], active: "A")
        let events = EventState.events(from: old, to: new)
        #expect(names(events) == ["workspaceRenamed", "workspaceCreated", "workspaceRemoved", "workspacesReordered"])
        #expect(events[0]["previousName"] == "Mail")
        #expect(events[1]["workspace"]?["number"] == 3)
        #expect(events[2]["workspace"]?["number"] == 3)  // where it was
        #expect(events[2]["workspace"]?["name"] == "Writing")
    }

    @Test func focusScratchpadAndSuspend() {
        let windows = [W(id: 1, app: "Code", title: "x", place: .workspace("A")), W(id: 2, app: "Notes", title: "n", place: .scratchpad)]
        let old = EventState(workspaces: [work], active: "A", windows: windows, focused: 1)
        let new = EventState(workspaces: [work], active: "A", windows: windows, focused: 2, scratchpadShown: true, suspended: true)
        let events = EventState.events(from: old, to: new)
        #expect(names(events) == ["scratchpad", "focus", "suspended"])
        #expect(events[1]["window"]?["workspace"] == "scratchpad")
    }

    @Test func filtersByNameOrStart() {
        let opened: JSON = ["event": "windowOpened"]
        let switched: JSON = ["event": "workspace"]
        #expect(EventState.matches(opened, filter: []))
        #expect(EventState.matches(opened, filter: ["window"]))
        #expect(EventState.matches(opened, filter: ["windowopened"]))
        #expect(!EventState.matches(switched, filter: ["window", "focus"]))
        #expect(EventState.matches(["event": "workspaceCreated"], filter: ["workspace"]))
    }

    @Test func parsesSubscribe() throws {
        #expect(try Command.parse(["subscribe"]) == .subscribe(events: []))
        #expect(try Command.parse(["events", "window", "focus"]) == .subscribe(events: ["window", "focus"]))
        #expect(Command.isCommand("subscribe"))
    }

    @Test func streamsToSubscribers() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "hd-\(UUID().uuidString.prefix(8)).sock").path
        let server = ControlServer(path: path) { args in
            args.first == "subscribe" ? ["ok": true, "event": "subscribed"] : ["ok": true]
        }
        try server.start()
        defer { server.stop() }

        let lines = LockedLines()
        let reader = Thread {
            try? ControlSocket.stream(["subscribe", "window"], path: path) { line in
                lines.append(String(decoding: line, as: UTF8.self))
                return lines.count < 2
            }
        }
        reader.start()
        for _ in 0..<200 where server.subscriberCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.subscriberCount == 1)
        server.broadcast([["event": "workspace"], ["event": "windowOpened"]])
        for _ in 0..<200 where lines.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let got = lines.all
        #expect(got.count == 2)
        #expect(got.first?.contains("subscribed") == true)
        #expect(got.last?.contains("windowOpened") == true)  // the workspace event was filtered out
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var count: Int { lock.withLock { lines.count } }
    var all: [String] { lock.withLock { lines } }
}
