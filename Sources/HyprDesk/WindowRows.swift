import AppKit
import Spaces
import SwiftUI
import WindowKit

/// What's dragged in the Manage window, as plain text so it needs no declared type:
/// a window ("hyprdesk-window:1234") or a workspace being reordered
/// ("hyprdesk-workspace:<uuid>").
enum ManageDrag {
    private static let windowPrefix = "hyprdesk-window:"
    private static let workspacePrefix = "hyprdesk-workspace:"

    static func payload(_ window: WindowInfo) -> String { windowPrefix + String(window.id) }
    static func payload(_ space: Space) -> String { workspacePrefix + space.id.uuidString }

    static func windowID(_ payload: String) -> CGWindowID? {
        guard payload.hasPrefix(windowPrefix) else { return nil }
        return CGWindowID(payload.dropFirst(windowPrefix.count))
    }

    static func workspaceID(_ payload: String) -> UUID? {
        guard payload.hasPrefix(workspacePrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(workspacePrefix.count)))
    }
}

/// One window: app icon, app and title, its document. Why it's in its workspace is the row's
/// tooltip. A focus button shows on hover (a button, not a double click: a tap gesture can keep
/// a drag from starting).
struct WindowRow<Trailing: View>: View {
    let window: WindowInfo
    var reason: MatchReason?
    let focus: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(for: window)).resizable().frame(width: 20, height: 20)
                .opacity(window.isMinimized ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(window.appName).fontWeight(.medium)
                    Text(window.title.isEmpty ? "(untitled)" : window.title).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                if let document = window.document {
                    Text(document.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            trailing
            Button(action: focus) { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless).help("Focus (switches to its workspace)")
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(reason.map(Self.whyHere) ?? "")
    }

    /// Why a window is in its workspace, in words.
    static func whyHere(_ reason: MatchReason) -> String {
        switch reason {
        case .manual: "You moved it here."
        case .stickyApp: "Its app shows in every workspace."
        case .openedHere: "Opened while this workspace was active."
        }
    }
}

extension WindowRow where Trailing == EmptyView {
    init(window: WindowInfo, reason: MatchReason? = nil, focus: @escaping () -> Void) {
        self.init(window: window, reason: reason, focus: focus) { EmptyView() }
    }
}

enum AppIcons {
    static func icon(for window: WindowInfo) -> NSImage {
        if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon { return icon }
        if let id = window.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
    }

    static func icon(forApp key: String) -> NSImage {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: key).first, let icon = app.icon { return icon }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    /// The app's name for a bundle ID, else the ID.
    static func name(forApp key: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: key).first, let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return key
    }
}
