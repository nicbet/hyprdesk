import AppKit
import SwiftUI
import WindowKit

/// The switcher HUD, styled after macOS's own ⌘Tab: one row of large icons on a dark translucent
/// panel, a soft highlight behind the selected one, and only its label below it. One icon per
/// window (not per app), so the label carries the window's title. Icons shrink to fit
/// the model's `maxWidth`, as the system's do. Clicking an icon picks it.
public struct SwitcherView: View {
    let model: SwitcherModel
    let onPick: (Int) -> Void
    private var maxWidth: CGFloat { model.maxWidth }
    /// Measured, to keep the label under the selected icon without running off the panel.
    @State private var labelWidth: CGFloat = 0

    nonisolated static let largestIcon: CGFloat = 112
    nonisolated static let smallestIcon: CGFloat = 40
    /// Around each icon, inside its highlight.
    nonisolated static let inset: CGFloat = 10
    nonisolated static let padding: CGFloat = 18

    public init(model: SwitcherModel, onPick: @escaping (Int) -> Void) {
        self.model = model
        self.onPick = onPick
    }

    /// The icon size that fits `count` icons in `maxWidth`.
    nonisolated static func iconSize(count: Int, maxWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return largestIcon }
        let perItem = (maxWidth - 2 * padding) / CGFloat(count) - 2 * inset
        return max(smallestIcon, min(largestIcon, perItem.rounded(.down)))
    }

    public var body: some View {
        let windows = model.windows
        let icon = Self.iconSize(count: windows.count, maxWidth: maxWidth)
        let cell = icon + 2 * Self.inset
        VStack(spacing: 8) {
            if windows.isEmpty {
                Text("No windows in this workspace")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    .frame(height: Self.largestIcon)
                    .padding(.horizontal, 24)
            } else {
                HStack(spacing: 0) {
                    ForEach(windows.indices, id: \.self) { index in
                        Image(nsImage: Self.icon(for: windows[index]))
                            .resizable().interpolation(.high)
                            .frame(width: icon, height: icon)
                            .opacity(windows[index].isMinimized ? 0.5 : 1)
                            .frame(width: cell, height: cell)
                            .background(model.selection == index ? Color.white.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: icon * 0.2, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(index) }
                            .onContinuousHover { phase in
                                if case .active = phase { model.hover(index, at: NSEvent.mouseLocation) }
                            }
                    }
                }
                let row = cell * CGFloat(windows.count)
                let selected = min(model.selection, windows.count - 1)
                // Centered under the selected icon, as macOS does, but kept inside the panel.
                let x = min(max(0, (CGFloat(selected) + 0.5) * cell - labelWidth / 2), max(0, row - labelWidth))
                label(for: windows[selected])
                    .frame(maxWidth: row)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labelWidth = $0 }
                    .offset(x: x)
                    .frame(width: row, alignment: .leading)
            }
        }
        .padding(Self.padding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    /// "Title  App", or just one of them when the title says nothing more.
    private func label(for window: WindowInfo) -> some View {
        let title = window.title.trimmingCharacters(in: .whitespaces)
        let showsApp = !title.isEmpty && !title.localizedCaseInsensitiveContains(window.appName)
        return HStack(spacing: 6) {
            Text(title.isEmpty ? window.appName : title)
                .foregroundStyle(.primary)
            if showsApp {
                Text(window.appName).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14, weight: .medium))
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: 520)
    }

    static func icon(for window: WindowInfo) -> NSImage {
        if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon { return icon }
        if let id = window.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
    }
}
