import Foundation

/// What `hyprdesk subscribe` reports on: the workspaces, which one is on screen, every window and
/// where it lives, the focused window, the scratchpad, and whether HyprDesk is hands off. The app
/// takes one after every change; `events(from:to:)` says what happened in between.
public struct EventState: Equatable, Sendable {
    public struct Workspace: Equatable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public enum Place: Equatable, Sendable {
        /// A workspace, by its ID.
        case workspace(String)
        case everywhere
        case scratchpad
        /// No workspaces at all: the window stays where it is.
        case none
    }

    public struct Window: Equatable, Sendable {
        public var id: UInt32
        public var app: String
        public var title: String
        public var place: Place

        public init(id: UInt32, app: String, title: String, place: Place) {
            self.id = id
            self.app = app
            self.title = title
            self.place = place
        }
    }

    public var workspaces: [Workspace]
    /// The workspace on screen, by ID.
    public var active: String?
    public var windows: [Window]
    public var focused: UInt32?
    public var scratchpadShown: Bool
    /// Suspended, or on another macOS desktop.
    public var suspended: Bool

    public init(workspaces: [Workspace] = [], active: String? = nil, windows: [Window] = [], focused: UInt32? = nil,
                scratchpadShown: Bool = false, suspended: Bool = false) {
        self.workspaces = workspaces
        self.active = active
        self.windows = windows
        self.focused = focused
        self.scratchpadShown = scratchpadShown
        self.suspended = suspended
    }

    /// What changed from `old` to `new`, as events: `{"event": name, …}`. Workspaces are
    /// described as in `hyprdesk list` (numbered from 1); a window's `workspace` is a number,
    /// "everywhere", "scratchpad" or null.
    ///
    /// In this order: workspaces created, renamed, removed or reordered; windows closed, opened,
    /// moved or retitled; then the switch, the scratchpad, the focus, and suspending.
    public static func events(from old: EventState, to new: EventState) -> [JSON] {
        var events: [JSON] = []
        func event(_ name: String, _ fields: [String: JSON]) {
            var object = fields
            object["event"] = .string(name)
            events.append(.object(object))
        }

        // Workspaces.
        let oldSpaces = Dictionary(old.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newSpaces = Dictionary(new.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for space in new.workspaces {
            if let before = oldSpaces[space.id] {
                if before.name != space.name {
                    event("workspaceRenamed", ["workspace": new.describe(space.id), "previousName": .string(before.name)])
                }
            } else {
                event("workspaceCreated", ["workspace": new.describe(space.id)])
            }
        }
        for space in old.workspaces where newSpaces[space.id] == nil {
            event("workspaceRemoved", ["workspace": old.describe(space.id)])
        }
        let kept = Set(oldSpaces.keys).intersection(newSpaces.keys)
        if old.workspaces.map(\.id).filter(kept.contains) != new.workspaces.map(\.id).filter(kept.contains) {
            event("workspacesReordered", ["workspaces": .array(new.workspaces.map { new.describe($0.id) })])
        }

        // Windows.
        let oldWindows = Dictionary(old.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newWindows = Dictionary(new.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for window in old.windows where newWindows[window.id] == nil {
            event("windowClosed", ["window": old.describe(window)])
        }
        for window in new.windows {
            guard let before = oldWindows[window.id] else {
                event("windowOpened", ["window": new.describe(window)])
                continue
            }
            if before.place != window.place {
                event("windowMoved", ["window": new.describe(window), "from": old.describe(before.place)])
            }
            if before.title != window.title {
                event("windowTitle", ["window": new.describe(window), "previousTitle": .string(before.title)])
            }
        }

        // Where you are.
        if old.active != new.active {
            event("workspace", ["workspace": new.active.map(new.describe) ?? .null,
                                "previous": old.active.flatMap { oldSpaces[$0] == nil ? nil : old.describe($0) } ?? .null])
        }
        if old.scratchpadShown != new.scratchpadShown {
            event("scratchpad", ["shown": .bool(new.scratchpadShown)])
        }
        if old.focused != new.focused, let id = new.focused, let window = newWindows[id] {
            event("focus", ["window": new.describe(window)])
        }
        if old.suspended != new.suspended {
            event("suspended", ["suspended": .bool(new.suspended)])
        }
        return events
    }

    /// Whether `event` is one a subscriber asked for: every event when `filter` is empty, else
    /// those named in it or starting with a name in it (`window` is every window event).
    public static func matches(_ event: JSON, filter: [String]) -> Bool {
        guard !filter.isEmpty else { return true }
        guard case .string(let name)? = event["event"] else { return false }
        return filter.contains { name.lowercased().hasPrefix($0.lowercased()) }
    }

    // MARK: Describing

    private func describe(_ spaceID: String) -> JSON {
        guard let index = workspaces.firstIndex(where: { $0.id == spaceID }) else { return .null }
        return ["number": .int(index + 1), "name": .string(workspaces[index].name), "id": .string(spaceID),
                "active": .bool(spaceID == active)]
    }

    private func describe(_ place: Place) -> JSON {
        switch place {
        case .workspace(let id): JSON(workspaces.firstIndex { $0.id == id }.map { $0 + 1 })
        case .everywhere: "everywhere"
        case .scratchpad: "scratchpad"
        case .none: .null
        }
    }

    private func describe(_ window: Window) -> JSON {
        ["id": .int(Int(window.id)), "app": .string(window.app), "title": .string(window.title), "workspace": describe(window.place)]
    }
}
