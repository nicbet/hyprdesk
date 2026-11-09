import AppKit
import SwiftUI
import WindowKit

/// The overview: every space as a card, over a dimmed screen. Keys are handled by the panel
/// hosting it; the pointer selects by hovering.
public struct OverviewView: View {
    let model: OverviewModel
    /// Off for snapshots: `ImageRenderer` doesn't draw scroll views.
    let scrolls: Bool

    nonisolated static let cardWidth: CGFloat = 340
    nonisolated static let maxCardWidth: CGFloat = 440
    nonisolated static let spacing: CGFloat = 20
    nonisolated static let margin: CGFloat = 56
    /// Room around the grid for the selected card's lift and glow: a scroll view clips at its edges.
    nonisolated static let bleed: CGFloat = 24

    public init(model: OverviewModel, scrolls: Bool = true) {
        self.model = model
        self.scrolls = scrolls
    }

    public var body: some View {
        let cards = model.cards
        let now = model.now
        ZStack {
            // The blur is the panel's (the window server's); this only dims and takes clicks.
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { model.onDismiss() }
            VStack(spacing: 24 - Self.bleed) {
                header.padding(.horizontal, Self.bleed)
                if cards.isEmpty {
                    emptyState
                } else if scrolls {
                    ScrollView { grid(cards, now: now).padding(Self.bleed).padding(.bottom, Self.margin - Self.bleed) }
                        .scrollIndicators(.never)
                } else {
                    grid(cards, now: now).padding(Self.bleed)
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, Self.margin)
            .padding(.horizontal, Self.margin - Self.bleed)
        }
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            model.columns = Self.columns(forWidth: width, cards: cards.count)
        }
    }

    /// As many columns of at least `cardWidth` as fit, at most 4, never more than cards.
    nonisolated static func columns(forWidth width: CGFloat, cards: Int) -> Int {
        let fit = Int((width - 2 * margin + spacing) / (cardWidth + spacing))
        return min(max(1, fit), 4, max(1, cards))
    }

    /// Row by row rather than a lazy grid: there are only ever a handful of cards.
    private func grid(_ cards: [SpaceCard], now: Date) -> some View {
        let columns = max(1, model.columns)
        let rows = stride(from: 0, to: cards.count, by: columns).map { Array(cards.indices[$0..<min($0 + columns, cards.count)]) }
        return VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(rows, id: \.first) { row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(row, id: \.self) { index in
                        CardView(card: cards[index], number: index < 9 ? index + 1 : nil,
                                 isSelected: model.selection == index, now: now, model: model)
                            .onContinuousHover { phase in
                                if case .active = phase, model.pointer.allows(at: NSEvent.mouseLocation) { model.selection = index }
                            }
                            .onTapGesture { model.activate(index) }
                    }
                    // Keep the last row's cards as wide as the others.
                    ForEach(row.count..<columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
        .frame(maxWidth: CGFloat(columns) * (Self.maxCardWidth + Self.spacing))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Workspaces").font(.system(size: 28, weight: .bold))
            Spacer()
            Text("←→↑↓ choose   1–9 jump   ⏎ open   esc close")
                .font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: CGFloat(model.columns) * (Self.maxCardWidth + Self.spacing) - Self.spacing)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No workspaces yet").font(.title2.weight(.semibold))
            Text("Make one from the menu-bar item: Manage Workspaces…").foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A workspace (or the scratchpad) as a miniature of its screen: its windows where they really
/// sit, back to front, each with its app's icon; below, one row with its number and name. Every
/// card is the same height.
private struct CardView: View {
    let card: SpaceCard
    let number: Int?
    let isSelected: Bool
    let now: Date
    let model: OverviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            desktop
            caption.padding(.horizontal, 4)
        }
        .padding(10)
        .background(.white.opacity(isSelected ? 0.1 : 0.05), in: shape)
        .overlay(shape.strokeBorder(border, lineWidth: isSelected ? 2 : 1))
        // A glow around the edge only: a shadow would show through the translucent card.
        .background {
            if isSelected { shape.stroke(Self.accent.opacity(0.85), lineWidth: 6).blur(radius: 14) }
        }
        .scaleEffect(isSelected ? 1.02 : 1)
        .animation(.spring(duration: 0.18), value: isSelected)
        .contentShape(shape)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
    private static let accent = Color(nsColor: .controlAccentColor)
    private var border: Color { isSelected ? Self.accent : .white.opacity(0.1) }

    private var desktop: some View {
        let screen = RoundedRectangle(cornerRadius: 9, style: .continuous)
        // The screen's shape across the card's full width; the windows drawn over it.
        return Color.clear
            .aspectRatio(model.aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(card.windows.filter { !$0.isMinimized }.reversed()) { window in
                    if let mini = MiniDesktop.frame(of: model.frame(of: window), screens: model.screens, in: geometry.size) {
                        MiniWindow(window: window, size: mini.size)
                            .frame(width: mini.width, height: mini.height)
                            .offset(x: mini.minX, y: mini.minY)
                            .onTapGesture { model.onRaise(window) }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        } }
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.19, blue: 0.3), Color(red: 0.24, green: 0.17, blue: 0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(card.isScratchpad ? 0.55 : 1),
            in: screen
        )
        .overlay(screen.strokeBorder(.white.opacity(0.08)))
        .clipShape(screen)
    }

    /// One row: number, name, the dot when it's on screen; on the right, the apps shown in every
    /// workspace, which come along wherever you go.
    private var caption: some View {
        HStack(spacing: 7) {
            if card.isScratchpad {
                chip("✦ S")
            } else if let number {
                chip("\(number)")
            }
            Text(card.name).font(.headline).lineLimit(1)
            if card.isActive { Circle().fill(Self.accent).frame(width: 7, height: 7) }
            Spacer(minLength: 6)
            sharedApps
        }
        .frame(height: 20)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    static let maxSharedApps = 5

    @ViewBuilder
    private var sharedApps: some View {
        let apps = card.sharedApps
        if !apps.isEmpty {
            HStack(spacing: 4) {
                ForEach(apps.prefix(Self.maxSharedApps)) { window in
                    AppIcon(window: window).frame(width: 16, height: 16).help("\(window.appName): in every workspace")
                }
                if apps.count > Self.maxSharedApps {
                    Text("+\(apps.count - Self.maxSharedApps) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(0.85)
        }
    }
}

/// One window on a miniature desktop: a rounded pane with its app's icon in the middle.
private struct MiniWindow: View {
    let window: WindowInfo
    let size: CGSize

    var body: some View {
        let pane = RoundedRectangle(cornerRadius: min(5, size.width / 8), style: .continuous)
        pane.fill(Color(white: 0.19))
            // A title bar, so it reads as a window.
            .overlay(alignment: .top) { Color(white: 0.27).frame(height: min(9, size.height * 0.12)) }
            .clipShape(pane)
            .overlay(pane.strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .overlay {
                VStack(spacing: 4) {
                    AppIcon(window: window)
                        .frame(width: icon, height: icon)
                    // What it is, beyond the app: its title, muted, when the pane has room.
                    if showsTitle {
                        Text(window.title)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: size.width)
                    }
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .help(window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)")
    }

    private var icon: CGFloat { min(34, min(size.width, size.height) * 0.5) }
    /// Room for a line under the icon, and a title that says more than the app's name.
    private var showsTitle: Bool {
        size.width >= 64 && size.height >= icon + 30 && !window.title.isEmpty && window.title != window.appName
    }
}

struct AppIcon: View {
    let window: WindowInfo

    var body: some View {
        Image(nsImage: Self.icon(for: window))
            .resizable()
            .interpolation(.high)
    }

    /// The running app's icon, else the installed app's (snapshots use made-up windows).
    static func icon(for window: WindowInfo) -> NSImage {
        if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon { return icon }
        if let id = window.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
    }
}
