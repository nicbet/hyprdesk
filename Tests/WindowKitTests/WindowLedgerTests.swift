import Foundation
import Testing
@testable import WindowKit

@Suite struct WindowLedgerTests {
    func window(_ id: UInt32, pid: pid_t = 1, app: String = "App", title: String = "") -> WindowInfo {
        WindowInfo(id: id, pid: pid, appName: app, title: title)
    }

    @Test func windowsOpenAtTheStartDidNotAppear() {
        var ledger = WindowLedger()
        #expect(ledger.update(1, windows: [window(1)], launchedSinceStart: false).isEmpty)
    }

    @Test func aLaunchedAppsWindowsAppear() {
        var ledger = WindowLedger()
        #expect(ledger.update(1, windows: [window(1)], launchedSinceStart: true).map(\.id) == [1])
    }

    @Test func onlyNewWindowsAppear() {
        var ledger = WindowLedger()
        _ = ledger.update(1, windows: [window(1)], launchedSinceStart: false)
        #expect(ledger.update(1, windows: [window(1), window(2)], launchedSinceStart: false).map(\.id) == [2])
        #expect(ledger.update(1, windows: [window(2)], launchedSinceStart: false).isEmpty)
    }

    @Test func sortedByAppThenTitle() {
        var ledger = WindowLedger()
        _ = ledger.update(1, windows: [window(1, app: "Zed", title: "a")], launchedSinceStart: false)
        _ = ledger.update(2, windows: [window(2, pid: 2, app: "arc", title: "b"), window(3, pid: 2, app: "arc", title: "A")],
                          launchedSinceStart: false)
        #expect(ledger.all.map(\.id) == [3, 2, 1])
        ledger.remove(2)
        #expect(ledger.all.map(\.id) == [1])
    }
}
