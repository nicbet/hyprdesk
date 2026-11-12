import AppKit
import Control
import Spaces
import WindowKit
import Workspaces

/// Carries out commands from `hyprdesk <command>` and `hyprdesk://` links, and answers in JSON:
/// `{"ok": true, …}` or `{"ok": false, "error": "…"}`. Workspaces are numbered from 1, as in the
/// sidebar and on ✦ 1–9.
@MainActor
final class Commands {
    private let engine: WorkspaceEngine
    private let search: SearchPanel
    /// Suspended, or on another macOS desktop: reading works, changing doesn't.
    private let handsOff: () -> Bool
    /// Before anything that changes the screen: overlays out of the way.
    private let dismissOverlays: () -> Void

    private var spaces: SpaceStore { engine.spaces }
    private var inventory: WindowInventory { engine.inventory }

    init(engine: WorkspaceEngine, search: SearchPanel, isHandsOff: @escaping () -> Bool, dismissOverlays: @escaping () -> Void) {
        self.engine = engine
        self.search = search
        self.handsOff = isHandsOff
        self.dismissOverlays = dismissOverlays
    }

    func run(_ args: [String]) -> JSON {
        do {
            return run(try Command.parse(args))
        } catch {
            return .failure(error.description)
        }
    }

    func run(_ command: Command) -> JSON {
        switch command {
        case .help:
            return ["ok": true, "usage": .string(Command.usage)]
        case .list:
            return list()
        case .current:
            return current()
        case .subscribe:
            // The socket keeps the connection for events; this is its first line.
            guard case .object(var object) = current() else { return current() }
            object["event"] = "subscribed"
            return .object(object)
        default:
            break
        }
        guard !handsOff() else { return .failure("HyprDesk is suspended or on another macOS desktop") }
        switch command {
        case .switchTo(let ref):
            guard let index = ref.index(in: names) else { return .failure(notFound(ref)) }
            dismissOverlays()
            engine.switchTo(spaces.spaces[index].id)
            return ["ok": true, "workspace": workspace(index)]
        case .previous:
            guard engine.previousID != nil else { return .failure("no previous workspace yet") }
            dismissOverlays()
            engine.switchToPrevious()
            return current()
        case .move(let ref, let windowID, let follow):
            return move(to: ref, windowID: windowID, follow: follow)
        case .focus(let id):
            guard let window = window(id) else { return .failure("no window \(id); see `hyprdesk list`") }
            dismissOverlays()
            engine.focus(window)
            return ["ok": true, "window": describe(window)]
        case .scratchpad(let action):
            let shown = switch action {
            case .toggle: !spaces.isScratchpadShown
            case .show: true
            case .hide: false
            }
            if shown, engine.scratchpadWindows.isEmpty { return .failure("the scratchpad is empty") }
            dismissOverlays()
            engine.setScratchpad(shown: shown)
            return ["ok": true, "shown": .bool(spaces.isScratchpadShown)]
        case .find(let query):
            search.show(query: query)
            return ["ok": true]
        case .create(let name):
            spaces.addSpace(name: name)
            return ["ok": true, "workspace": workspace(spaces.spaces.count - 1)]
        case .rename(let ref, let name):
            guard let index = ref.index(in: names) else { return .failure(notFound(ref)) }
            var space = spaces.spaces[index]
            space.name = name
            spaces.update(space)
            return ["ok": true, "workspace": workspace(index)]
        case .help, .list, .current, .subscribe:
            return .failure("unreachable")
        }
    }

    // MARK: Moving

    private func move(to ref: WorkspaceRef, windowID: UInt32?, follow: Bool) -> JSON {
        let focusedID = inventory.focusedWindowID()
        guard let id = windowID ?? focusedID else { return .failure("no focused window; pass --window <id>") }
        guard let window = window(id) else { return .failure("no window \(id); see `hyprdesk list`") }
        let placement: Placement
        switch ref {
        case .everywhere: placement = .everywhere
        case .scratchpad: placement = .scratchpad
        default:
            guard let index = ref.index(in: names) else { return .failure(notFound(ref)) }
            placement = .space(spaces.spaces[index].id)
        }
        dismissOverlays()
        if case .space(let spaceID) = placement, follow, id == focusedID {
            engine.moveFocusedWindow(to: spaceID)
        } else if placement == .scratchpad, id == focusedID, spaces.placement(of: window)?.placement != .scratchpad {
            engine.toggleFocusedWindowInScratchpad()
        } else {
            engine.move(window, to: placement)
            if case .space(let spaceID) = placement, follow { engine.switchTo(spaceID, focusing: window) }
        }
        return ["ok": true, "window": describe(window)]
    }

    // MARK: Answers

    private func list() -> JSON {
        let windows = inventory.windows
        let byPlace = Dictionary(grouping: windows) { spaces.placement(of: $0)?.placement }
        let workspaces: [JSON] = spaces.spaces.indices.map { index in
            var entry = workspace(index)
            if case .object(var object) = entry {
                object["windows"] = .array((byPlace[.space(spaces.spaces[index].id)] ?? []).map(describe))
                entry = .object(object)
            }
            return entry
        }
        return [
            "ok": true,
            "workspaces": .array(workspaces),
            "everywhere": .array((byPlace[.everywhere] ?? []).map(describe)),
            "scratchpad": ["shown": .bool(spaces.isScratchpadShown), "windows": .array((byPlace[.scratchpad] ?? []).map(describe))],
            "focused": JSON(inventory.focusedWindowID().map(Int.init)),
        ]
    }

    private func current() -> JSON {
        let index = spaces.spaces.firstIndex { $0.id == spaces.activeSpaceID }
        let focused = inventory.focusedWindowID().flatMap(window)
        return [
            "ok": true,
            "workspace": index.map(workspace) ?? .null,
            "focused": focused.map(describe) ?? .null,
            "scratchpadShown": .bool(spaces.isScratchpadShown),
            "suspended": .bool(handsOff()),
        ]
    }

    private func workspace(_ index: Int) -> JSON {
        let space = spaces.spaces[index]
        return ["number": .int(index + 1), "name": .string(space.name), "id": .string(space.id.uuidString),
                "active": .bool(space.id == spaces.activeSpaceID)]
    }

    private func describe(_ window: WindowInfo) -> JSON {
        var place: JSON = .null
        switch spaces.placement(of: window)?.placement {
        case .space(let id): place = JSON(spaces.spaces.firstIndex { $0.id == id }.map { $0 + 1 })
        case .everywhere: place = "everywhere"
        case .scratchpad: place = "scratchpad"
        case nil: break
        }
        return [
            "id": .int(Int(window.id)),
            "app": .string(window.appName),
            "bundleID": JSON(window.bundleID),
            "title": .string(window.title),
            "document": JSON(window.document?.path),
            "minimized": .bool(window.isMinimized),
            "workspace": place,
            // Where it is right now (Accessibility coordinates: top left of the main screen, y
            // down). Parked windows sit just off screen.
            "frame": inventory.frame(of: window).map { frame -> JSON in
                ["x": .int(Int(frame.minX)), "y": .int(Int(frame.minY)), "width": .int(Int(frame.width)), "height": .int(Int(frame.height))]
            } ?? .null,
        ]
    }

    private var names: [String] { spaces.spaces.map(\.name) }

    private func window(_ id: UInt32) -> WindowInfo? {
        inventory.windows.first { $0.id == id }
    }

    private func notFound(_ ref: WorkspaceRef) -> String {
        switch ref {
        case .number(let n): "no workspace \(n) (there are \(spaces.spaces.count))"
        case .name(let name): "no single workspace called “\(name)”"
        case .everywhere, .scratchpad: "that's not a workspace you can switch to"
        }
    }
}
