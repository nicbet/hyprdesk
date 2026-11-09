import CoreGraphics
import Observation
import WindowKit

/// What the space's Mission Control shows: the windows, their latest pictures, the selection,
/// and whether the thumbnails have zoomed out of the windows yet. The app supplies the actions.
@MainActor
@Observable
public final class ExposeModel {
    public private(set) var windows: [WindowInfo] = []
    public private(set) var title = ""
    public var images: [CGWindowID: CGImage] = [:]
    public var selection = 0
    /// False while thumbnails still sit on their windows; true once they've moved into the grid.
    public private(set) var isExpanded = false
    /// True once the zoom-out has finished: shadows, icons and labels only appear then, so the
    /// animation moves plain pictures.
    public var isSettled = false
    /// Without Screen Recording, thumbnails are icons and titles.
    public var canCapture = true
    /// The screen it's shown on, Accessibility coordinates: where the windows start from.
    public private(set) var screen: CGRect = .zero
    /// The window you came from: it takes the middle cell, whatever the selection does after.
    public private(set) var centered: CGWindowID?

    @ObservationIgnored public var onPick: (WindowInfo) -> Void = { _ in }
    @ObservationIgnored public var onDismiss: () -> Void = {}
    @ObservationIgnored public var onAllowCapture: () -> Void = {}

    /// Hover selects only after the pointer has moved (see `PointerGate`).
    @ObservationIgnored public var pointer = PointerGate()

    /// The last layout, for the arrow keys.
    @ObservationIgnored var placed: [CGRect] = []

    public init() {}

    /// `selecting`: the window to start on, the one you came from; else the first.
    public func begin(_ windows: [WindowInfo], title: String, screen: CGRect, selecting focused: CGWindowID? = nil,
                      keepImages: Bool = false) {
        self.windows = windows
        self.title = title
        self.screen = screen
        if !keepImages { images = [:] }
        isSettled = false
        cachedLayout = nil
        selection = focused.flatMap { id in windows.firstIndex { $0.id == id } } ?? 0
        centered = focused.flatMap { id in windows.contains { $0.id == id } ? id : nil }
        isExpanded = false
    }

    public func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }

    public func pick(_ index: Int? = nil) {
        let index = index ?? selection
        guard windows.indices.contains(index) else { return }
        onPick(windows[index])
    }

    public func move(_ direction: ExposeLayout.Direction) {
        guard !placed.isEmpty else { return }
        selection = ExposeLayout.neighbor(of: selection, direction, in: placed)
    }

    /// The grid for `bounds`: stable cells, the window you came from in the middle. Worked out
    /// once per opening (hovering re-renders the view; the grid doesn't change).
    public func layout(in bounds: CGRect) -> ExposeLayout.Result {
        if let cachedLayout, cachedLayout.bounds == bounds { return cachedLayout.result }
        let result = ExposeLayout.layout(windows.map(\.frame), ids: windows.map(\.id),
                                         centering: centered.flatMap { id in windows.firstIndex { $0.id == id } }, in: bounds)
        cachedLayout = (bounds, result)
        placed = result.frames
        return result
    }

    @ObservationIgnored private var cachedLayout: (bounds: CGRect, result: ExposeLayout.Result)?

    /// Where a window starts, in the panel's coordinates: right on top of the window itself.
    func startFrame(of window: WindowInfo) -> CGRect {
        window.frame.offsetBy(dx: -screen.minX, dy: -screen.minY)
    }
}
