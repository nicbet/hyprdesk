import Foundation

/// Every app's current windows, and which ones are new since the app was last listed.
struct WindowLedger {
    private(set) var byApp: [pid_t: [WindowInfo]] = [:]

    /// Replaces `pid`'s windows and returns the ones it didn't have before. An app's first
    /// listing reports nothing unless `launchedSinceStart`: windows that were already open when
    /// we started (or were allowed Accessibility) didn't just appear.
    mutating func update(_ pid: pid_t, windows: [WindowInfo], launchedSinceStart: Bool) -> [WindowInfo] {
        let known = byApp[pid]
        byApp[pid] = windows
        guard let known else { return launchedSinceStart ? windows : [] }
        let ids = Set(known.map(\.id))
        return windows.filter { !ids.contains($0.id) }
    }

    mutating func remove(_ pid: pid_t) {
        byApp[pid] = nil
    }

    /// By app name, then title.
    var all: [WindowInfo] {
        byApp.values.joined().sorted {
            ($0.appName.localizedLowercase, $0.title.localizedLowercase, $0.id)
                < ($1.appName.localizedLowercase, $1.title.localizedLowercase, $1.id)
        }
    }
}
