import AppKit
import Search
import Spaces
import SwiftUI
import WindowKit
import Workspaces

/// ✦ Space: find any window in any workspace, Spotlight-style. A see-through panel over the
/// screen under the pointer with the search near the top; a click anywhere else, Escape or
/// another app coming forward puts it away. Return jumps to the window, switching workspace.
@MainActor
final class SearchPanel {
    let model = SearchModel()
    private let engine: WorkspaceEngine
    private var panel: KeyPanel?
    private var previous: NSRunningApplication?

    var isVisible: Bool { panel.map { $0.isVisible && !$0.isFadingOut } == true }

    init(engine: WorkspaceEngine) {
        self.engine = engine
        model.onPick = { [weak self] candidate in
            guard let self else { return }
            dismiss(restoringFocus: false)
            engine.focus(candidate.window)
        }
        model.onDismiss = { [weak self] in self?.dismiss(restoringFocus: true) }
    }

    func toggle() { isVisible ? dismiss(restoringFocus: true) : show() }

    /// Opens, with `query` already typed.
    func show(query: String? = nil) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? makePanel()
        let front = NSWorkspace.shared.frontmostApplication
        previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previous : front
        model.begin(candidates())
        if let query { model.query = query }
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }
    }

    func dismiss(restoringFocus: Bool) {
        guard let panel, panel.isVisible, !panel.isFadingOut else { return }
        panel.fadeOut(duration: 0.08, shieldingClicks: false)
        if restoringFocus, let previous, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
    }

    /// Every window, most recently focused first, then front to back.
    private func candidates() -> [SearchCandidate] {
        let spaces = engine.spaces
        let windows = engine.inventory.windows
        let recent = engine.recentWindows
        let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let order = WindowOrder.current()
        let sorted = WindowOrder.sorted(windows, by: order).enumerated().sorted { a, b in
            (rank[a.element.id] ?? Int.max, a.offset) < (rank[b.element.id] ?? Int.max, b.offset)
        }.map(\.element)
        return sorted.map { window in
            switch spaces.placement(of: window)?.placement {
            case .space(let id):
                let index = spaces.spaces.firstIndex { $0.id == id }
                return SearchCandidate(window: window, place: spaces.space(id)?.name, placeIndex: index)
            case .everywhere: return SearchCandidate(window: window, place: "Every Workspace", placeIndex: nil)
            case .scratchpad: return SearchCandidate(window: window, place: "Scratchpad", placeIndex: nil)
            case nil: return SearchCandidate(window: window, place: nil, placeIndex: nil)
            }
        }
    }

    /// Dev tool: the panel's content as a PNG (the search box, cropped).
    func snapshot(to url: URL) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: SearchView(model: model))
        panel.onResignKey = { [weak self] in self?.dismiss(restoringFocus: false) }
        self.panel = panel
        return panel
    }
}

/// The search field and its results, near the top of the screen.
struct SearchView: View {
    @Bindable var model: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // A click outside the search puts it away.
                Color.black.opacity(0.001).onTapGesture { model.dismiss() }
                box.frame(width: min(680, geometry.size.width - 40))
                    .padding(.top, geometry.size.height * 0.2)
            }
        }
        .ignoresSafeArea()
    }

    private var box: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary)
                TextField("Find a window", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.escape) { model.dismiss(); return .handled }
                    .onSubmit { model.pick() }
                KeyCombo(Keys.hyper, "Space").opacity(0.6)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            if !model.results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        row(result, selected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture { model.pick(index) }
                    }
                }
                .padding(6)
            } else if !model.query.isEmpty {
                Divider()
                Text("No windows match").foregroundStyle(.secondary).padding(14)
            }
        }
        // The window server's blur of what's behind the panel, as Spotlight's: a SwiftUI material
        // only blurs within its own (here see-through) window, and comes out flat grey.
        .background(BehindWindowBlur(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear { fieldFocused = true }
        .onChange(of: model.openings) { fieldFocused = true }
    }

    private func row(_ result: SearchCandidate, selected: Bool) -> some View {
        let window = result.window
        return HStack(spacing: 10) {
            Image(nsImage: AppIcons.icon(for: window)).resizable().frame(width: 24, height: 24)
                .opacity(window.isMinimized ? 0.5 : 1)
            Text(window.title.isEmpty ? window.appName : window.title).lineLimit(1).truncationMode(.middle)
            if !window.title.isEmpty {
                Text(window.appName).foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let place = result.place {
                Text(place).font(.callout).foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary).lineLimit(1)
            }
            if let index = result.placeIndex, index < 9 { KeyCombo(Keys.hyper, "\(index + 1)") }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A rounded patch of behind-window blur (`NSVisualEffectView`), following light and dark mode.
struct BehindWindowBlur: NSViewRepresentable {
    var cornerRadius: CGFloat
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.layer?.cornerRadius = cornerRadius
    }
}
