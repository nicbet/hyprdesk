import Control
import Foundation
import Observation
import Spaces
import WindowKit
import Workspaces

/// Turns what happens in HyprDesk into `hyprdesk subscribe` events: after every change to the
/// workspaces, the windows or where they live, it takes an `EventState` and sends what's
/// different from the last one. Focus isn't observable, so the engine's focus callback calls
/// `update()` too.
@MainActor
final class EventFeed {
    private let engine: WorkspaceEngine
    private let isHandsOff: () -> Bool
    private var last: EventState?
    private var started = false
    /// Where events go: the control socket's subscribers.
    var send: (([JSON]) -> Void)?

    init(engine: WorkspaceEngine, isHandsOff: @escaping () -> Bool) {
        self.engine = engine
        self.isHandsOff = isHandsOff
    }

    func start() {
        guard !started else { return }
        started = true
        last = state()
        observe()
    }

    /// Sends whatever changed since the last look.
    func update() {
        guard started else { return }
        let now = state()
        if let last, last != now { send?(EventState.events(from: last, to: now)) }
        last = now
    }

    /// One look per change: the observation fires once, before the change lands, so the look
    /// waits for the next turn of the run loop (several changes in one turn make one look).
    private func observe() {
        withObservationTracking { _ = state() } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.update()
                    self?.observe()
                }
            }
        }
    }

    private func state() -> EventState {
        let spaces = engine.spaces
        let windows = engine.inventory.windows
        let listed = Set(windows.map(\.id))
        return EventState(
            workspaces: spaces.spaces.map { EventState.Workspace(id: $0.id.uuidString, name: $0.name) },
            active: spaces.activeSpaceID?.uuidString,
            windows: windows.map { window in
                let place: EventState.Place = switch spaces.placement(of: window)?.placement {
                case .space(let id): .workspace(id.uuidString)
                case .everywhere: .everywhere
                case .scratchpad: .scratchpad
                case nil: .none
                }
                return EventState.Window(id: window.id, app: window.appName, title: window.title, place: place)
            },
            focused: engine.recentWindows.first(where: listed.contains),
            scratchpadShown: spaces.isScratchpadShown,
            suspended: isHandsOff())
    }
}
