import AppKit
import SwiftUI
import WindowKit

/// The space's Mission Control: its windows as thumbnails over a dimmed screen. They zoom out
/// of the windows into a grid when it opens. Hover or arrows select, click or Return picks.
public struct ExposeView: View {
    let model: ExposeModel

    nonisolated static let margin = EdgeInsets(top: 84, leading: 64, bottom: 72, trailing: 64)

    public init(model: ExposeModel) {
        self.model = model
    }

    /// The area thumbnails are laid out in, for a panel of `size`.
    public nonisolated static func bounds(for size: CGSize) -> CGRect {
        CGRect(x: margin.leading, y: margin.top,
               width: size.width - margin.leading - margin.trailing,
               height: size.height - margin.top - margin.bottom)
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let layout = model.layout(in: Self.bounds(for: size))
            ZStack(alignment: .topLeading) {
                // The blur is the panel's (the window server's); this only dims and takes clicks.
                Color.black.opacity(0.3)
                    .contentShape(Rectangle())
                    .onTapGesture { model.onDismiss() }
                header
                    .padding(.top, 28).padding(.horizontal, Self.margin.leading)
                if model.windows.isEmpty {
                    Text("No windows in this workspace").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: size.width, height: size.height)
                }
                ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                    let target = layout.frames.indices.contains(index) ? layout.frames[index] : model.startFrame(of: window)
                    let start = model.startFrame(of: window)
                    let expanded = model.isExpanded
                    // Laid out once at its grid size; the zoom only scales and moves it (transforms
                    // the GPU composites), never re-lays it out frame by frame.
                    Thumbnail(window: window, image: model.images[window.id], isSelected: model.selection == index,
                              isSettled: model.isSettled, size: target.size)
                        .onContinuousHover { phase in
                            if case .active = phase, model.pointer.allows(at: NSEvent.mouseLocation) { model.selection = index }
                        }
                        .onTapGesture { model.pick(index) }
                        .zIndex(model.selection == index ? 1 : 0)
                        .scaleEffect(x: expanded ? 1 : start.width / max(1, target.width),
                                     y: expanded ? 1 : start.height / max(1, target.height))
                        .offset(x: expanded ? 0 : start.midX - target.midX, y: expanded ? 0 : start.midY - target.midY)
                        // Hover and taps before `position`: a positioned view fills its whole parent.
                        .position(x: target.midX, y: target.midY)
                }
                if !model.canCapture { captureBanner.frame(width: size.width, height: size.height - 24, alignment: .bottom) }
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.title).font(.system(size: 24, weight: .bold))
            Text(model.windows.count == 1 ? "1 window" : "\(model.windows.count) windows").foregroundStyle(.secondary)
            Spacer()
            Text("←→↑↓ choose   ⏎ open   esc close").font(.callout.monospaced()).foregroundStyle(.secondary)
        }
        .opacity(model.isExpanded ? 1 : 0)
    }

    private var captureBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed.badge.record")
            Text("Allow Screen Recording to see live window previews here.")
            Button("Allow…") { model.onAllowCapture() }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct Thumbnail: View {
    let window: WindowInfo
    let image: CGImage?
    let isSelected: Bool
    /// The zoom is over: shadow, icon and label may appear (none of them move with it).
    let isSettled: Bool
    let size: CGSize

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        content
            .frame(width: max(1, size.width), height: max(1, size.height))
            .clipShape(shape)
            .overlay(shape.strokeBorder(isSelected ? Color(nsColor: .controlAccentColor) : .white.opacity(0.15),
                                        lineWidth: isSelected ? 3 : 1))
            .background {
                // On a plain shape, behind the picture: cheap to draw, and only once settled.
                shape.fill(.black).shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                    .opacity(isSettled ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                Image(nsImage: Self.icon(for: window)).resizable().frame(width: 40, height: 40)
                    .offset(y: 18)
                    .opacity(isSettled ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                // Every window is labelled; the selected one stands out and may run wider than its
                // thumbnail (it's drawn above its neighbours), the rest stay within their own.
                if isSettled {
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(white: isSelected ? 0.22 : 0.12).opacity(0.92), in: Capsule())
                        .frame(width: isSelected ? max(160, size.width + 80) : max(60, size.width))
                        .offset(y: 54)
                }
            }
            .scaleEffect(isSelected && isSettled ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: isSelected)
            .animation(.easeOut(duration: 0.15), value: isSettled)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(decorative: image, scale: 2).resizable().interpolation(.medium)
        } else {
            ZStack {
                Color(white: 0.18)
                VStack(spacing: 10) {
                    Image(nsImage: Self.icon(for: window)).resizable().frame(width: 72, height: 72)
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    static func icon(for window: WindowInfo) -> NSImage {
        if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon { return icon }
        if let id = window.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
    }
}
