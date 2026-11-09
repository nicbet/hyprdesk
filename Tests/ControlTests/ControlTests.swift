import Foundation
import Testing
@testable import Control

@Suite struct ControlTests {
    @Test func parsesCommands() throws {
        #expect(try Command.parse(["switch", "2"]) == .switchTo(.number(2)))
        #expect(try Command.parse(["switch", "Client", "X"]) == .switchTo(.name("Client X")))
        #expect(try Command.parse(["move", "3"]) == .move(to: .number(3), window: nil, follow: true))
        #expect(try Command.parse(["move", "3", "--stay"]) == .move(to: .number(3), window: nil, follow: false))
        #expect(try Command.parse(["move", "Work", "--window", "42"]) == .move(to: .name("Work"), window: 42, follow: false))
        #expect(try Command.parse(["move", "scratchpad"]) == .move(to: .scratchpad, window: nil, follow: false))
        #expect(try Command.parse(["scratchpad"]) == .scratchpad(.toggle))
        #expect(try Command.parse(["scratchpad", "hide"]) == .scratchpad(.hide))
        #expect(try Command.parse(["find", "slack", "general"]) == .find(query: "slack general"))
        #expect(try Command.parse(["rename", "2", "Client", "X"]) == .rename(.number(2), to: "Client X"))
        #expect(try Command.parse([]) == .help)
        #expect(throws: Command.ParseError.self) { try Command.parse(["dance"]) }
        #expect(throws: Command.ParseError.self) { try Command.parse(["move", "--window", "abc", "2"]) }
    }

    @Test func parsesLinks() throws {
        #expect(try Command.parse(url: URL(string: "hyprdesk://switch/2")!) == .switchTo(.number(2)))
        #expect(try Command.parse(url: URL(string: "hyprdesk://move/Work?window=7")!) == .move(to: .name("Work"), window: 7, follow: false))
        #expect(try Command.parse(url: URL(string: "hyprdesk://find?q=slack")!) == .find(query: "slack"))
        #expect(try Command.parse(url: URL(string: "hyprdesk://scratchpad")!) == .scratchpad(.toggle))
    }

    @Test func findsWorkspacesByNumberNameOrStart() {
        let names = ["Work", "Client X", "Writing"]
        #expect(WorkspaceRef("2").index(in: names) == 1)
        #expect(WorkspaceRef("4").index(in: names) == nil)
        #expect(WorkspaceRef("client x").index(in: names) == 1)
        #expect(WorkspaceRef("Cli").index(in: names) == 1)
        #expect(WorkspaceRef("W").index(in: names) == nil)  // Work or Writing: ambiguous
        #expect(WorkspaceRef("everywhere") == .everywhere)
    }

    @Test func askAndAnswerOverTheSocket() async throws {
        let path = NSTemporaryDirectory() + "hd-\(UInt32.random(in: 0...UInt32.max)).sock"
        let server = ControlServer(path: path) { args in ["ok": true, "echo": .array(args.map(JSON.string))] }
        try server.start()
        defer { server.stop() }
        let answer = try await Task.detached { try ControlSocket.send(["switch", "2"], path: path) }.value
        #expect(answer == ["ok": true, "echo": ["switch", "2"]])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func nothingListeningIsReported() {
        #expect(throws: ControlSocket.Failure.self) { try ControlSocket.send(["list"], path: NSTemporaryDirectory() + "hd-none.sock") }
    }
}
