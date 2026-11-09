import AppKit
import ServiceManagement
import Spaces
import SwiftUI
import WindowKit
import Workspaces

/// The Manage Workspaces window: workspaces in a sidebar (create, rename, reorder, delete, drop
/// windows on them) with "Every Workspace" (windows shown in all of them) last, a workspace's
/// details and windows on the right, then the settings.
///
/// Plain views rather than Lists throughout: on macOS a List's table view handles drags itself,
/// and drop targets on its rows never fire.
struct ManageView: View {
    let engine: WorkspaceEngine
    let preferences: Preferences

    enum Item: Hashable {
        case workspace(UUID)
        case everywhere
        case scratchpad
        case general
        case shortcuts
    }

    @State private var selection: Item?
    @State private var dropTarget: Item?
    /// A workspace just created: its name field takes focus.
    @State private var naming: UUID?

    private var spaces: SpaceStore { engine.spaces }
    private var inventory: WindowInventory { engine.inventory }

    var body: some View {
        VStack(spacing: 0) {
            if !inventory.isTrusted { accessBanner }
            HStack(spacing: 0) {
                sidebar.frame(width: 250)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 500)
        .onAppear(perform: selectDefault)
        .onChange(of: spaces.spaces.map(\.id)) { selectDefault() }
    }

    private func selectDefault() {
        if case .workspace(let id) = selection, spaces.space(id) != nil { return }
        if [.everywhere, .scratchpad, .general, .shortcuts].contains(selection) { return }
        selection = (spaces.activeSpaceID ?? spaces.spaces.first?.id).map(Item.workspace) ?? .shortcuts
    }

    private var accessBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("HyprDesk needs Accessibility access to see and move windows.")
            Spacer()
            Button("Allow…") { inventory.requestAccess() }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("Workspaces")
                    ForEach(Array(spaces.spaces.enumerated()), id: \.element.id) { index, space in
                        workspaceRow(space, index: index)
                    }
                    // Always last, after the numbered workspaces. A workspace dropped on it moves
                    // to the end, just above it.
                    sidebarRow(.everywhere, title: "Every Workspace", systemImage: "square.on.square",
                               count: windows(where: { $0?.placement == .everywhere }).count)
                    sidebarRow(.scratchpad, title: "Scratchpad", systemImage: "rectangle.on.rectangle.angled",
                               count: windows(where: { $0?.placement == .scratchpad }).count)
                    sectionLabel("Settings").padding(.top, 8)
                    sidebarRow(.general, title: "General", systemImage: "gearshape", count: nil)
                    sidebarRow(.shortcuts, title: "Shortcuts", systemImage: "keyboard", count: nil)
                }
                .padding(8)
            }
            Divider()
            HStack(spacing: 2) {
                Menu {
                    Button("New Workspace") { createWorkspace() }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    createWorkspace()
                }
                .menuStyle(.borderlessButton).fixedSize().help("New workspace")
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
    }

    private func workspaceRow(_ space: Space, index: Int) -> some View {
        let item = Item.workspace(space.id)
        return SidebarRow(isSelected: selection == item, isDropTarget: dropTarget == item) {
            HStack(spacing: 7) {
                // hyper + this number switches here.
                Text(index < 9 ? "\(index + 1)" : "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(index < 9 ? Color.secondary.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .help(index < 9 ? "\(Keys.hyper) \(index + 1)" : "")
                Text(space.name.isEmpty ? "Untitled" : space.name).lineLimit(1).truncationMode(.middle)
                if spaces.activeSpaceID == space.id { ActiveBadge(onAccent: selection == item) }
                Spacer(minLength: 4)
                Text("\(windows(in: space.id).count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 16, alignment: .trailing)
            }
        }
        .onTapGesture { selection = item }
        .draggable(ManageDrag.payload(space)) {
            Text(space.name).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { payloads, _ in
            dropTarget = nil
            payloads.compactMap(ManageDrag.workspaceID).forEach { spaces.moveSpace($0, before: space.id) }
            return dropWindows(payloads, to: .space(space.id)) || payloads.contains { ManageDrag.workspaceID($0) != nil }
        } isTargeted: { targeted in
            if targeted { dropTarget = item } else if dropTarget == item { dropTarget = nil }
        }
        .contextMenu {
            if spaces.activeSpaceID != space.id { Button("Switch To") { engine.switchTo(space.id) } }
            Button("Rename") { selection = item; naming = space.id }
            Divider()
            Button("Delete Workspace", role: .destructive) { engine.removeSpace(space.id) }
        }
    }

    private func sidebarRow(_ item: Item, title: String, systemImage: String, count: Int?) -> some View {
        SidebarRow(isSelected: selection == item, isDropTarget: dropTarget == item) {
            HStack(spacing: 7) {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer()
                if let count {
                    Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .frame(minWidth: 16, alignment: .trailing)
                }
            }
        }
        .onTapGesture { selection = item }
        .dropDestination(for: String.self) { payloads, _ in
            dropTarget = nil
            if item == .scratchpad { return dropWindows(payloads, to: .scratchpad) }
            guard item == .everywhere else { return false }
            let workspaces = payloads.compactMap(ManageDrag.workspaceID)
            workspaces.forEach { spaces.moveSpace($0, before: nil) }
            return dropWindows(payloads, to: .everywhere) || !workspaces.isEmpty
        } isTargeted: { targeted in
            guard item == .everywhere || item == .scratchpad else { return }
            if targeted { dropTarget = item } else if dropTarget == item { dropTarget = nil }
        }
    }

    private func createWorkspace() {
        let space = spaces.addSpace(name: "Workspace \(spaces.spaces.count + 1)")
        selection = .workspace(space.id)
        naming = space.id
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .workspace(let id):
            if let space = spaces.space(id) {
                WorkspaceDetail(engine: engine, space: space, index: spaces.spaces.firstIndex { $0.id == id } ?? 0,
                                focusName: naming == id, windowMenu: windowMenu, dropWindows: dropWindows) {
                    naming = nil
                }
                .id(id)
            }
        case .everywhere:
            PlaceDetail(engine: engine, placement: .everywhere, windowMenu: windowMenu, dropWindows: dropWindows)
                .id(Item.everywhere)
        case .scratchpad:
            PlaceDetail(engine: engine, placement: .scratchpad, windowMenu: windowMenu, dropWindows: dropWindows)
                .id(Item.scratchpad)
        case .general:
            GeneralDetail(inventory: inventory)
        case .shortcuts:
            ShortcutsDetail(preferences: preferences)
        case nil:
            Text("Select a workspace").foregroundStyle(.secondary)
        }
    }

    // MARK: Windows

    private func windows(in spaceID: UUID) -> [WindowInfo] {
        inventory.windows.filter { spaces.placement(of: $0)?.spaceID == spaceID }
    }

    private func windows(where test: (WindowAssignment?) -> Bool) -> [WindowInfo] {
        inventory.windows.filter { test(spaces.placement(of: $0)) }
    }


    /// Moves dropped windows to `placement`; false when nothing in the drop was a window.
    private func dropWindows(_ payloads: [String], to placement: Placement) -> Bool {
        let ids = Set(payloads.compactMap(ManageDrag.windowID))
        let dropped = inventory.windows.filter { ids.contains($0.id) }
        for window in dropped where spaces.placement(of: window)?.placement != placement {
            engine.move(window, to: placement)
        }
        return !dropped.isEmpty
    }

    /// A window's right-click menu, wherever it's listed.
    private func windowMenu(_ window: WindowInfo) -> AnyView {
        let placement = spaces.placement(of: window)
        let sticky = spaces.stickyApps.contains(window.appKey)
        return AnyView(Group {
            Button("Focus") { engine.focus(window) }
            Divider()
            ForEach(spaces.spaces) { space in
                Button("Move to \(space.name)") { engine.move(window, to: .space(space.id)) }
                    .disabled(placement?.spaceID == space.id)
            }
            Button("Show in Every Workspace") { engine.move(window, to: .everywhere) }
                .disabled(placement?.placement == .everywhere)
            Button("Move to Scratchpad") { engine.move(window, to: .scratchpad) }
                .disabled(placement?.placement == .scratchpad)
            Divider()
            Button(sticky ? "Stop Showing \(window.appName) Everywhere" : "Show \(window.appName) in Every Workspace") {
                engine.setSticky(window.appKey, !sticky)
            }
        })
    }
}

/// Marks the workspace on screen.
private struct ActiveBadge: View {
    /// On a selected (accent-filled) row: white on translucent white.
    var onAccent = false
    /// The detail header's size.
    var large = false

    var body: some View {
        Text("Active")
            .font(large ? .callout.weight(.semibold) : .caption2.weight(.semibold))
            .padding(.horizontal, large ? 9 : 6).padding(.vertical, large ? 3 : 1)
            .foregroundStyle(onAccent ? Color.white : Color(nsColor: .systemBlue))
            .background(onAccent ? Color.white.opacity(0.25) : Color(nsColor: .systemBlue).opacity(0.15), in: Capsule())
    }
}

/// A sidebar row: selected rows filled with the accent color, drop targets outlined.
private struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let isDropTarget: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
    }
}

// MARK: - Workspace

private struct WorkspaceDetail: View {
    let engine: WorkspaceEngine
    let space: Space
    let index: Int
    let focusName: Bool
    let windowMenu: (WindowInfo) -> AnyView
    let dropWindows: ([String], Placement) -> Bool
    let onNamed: () -> Void

    @State private var name = ""
    @State private var confirmDelete = false
    @State private var isDropTarget = false
    @State private var showsOthers = false
    @FocusState private var nameFocused: Bool

    private var spaces: SpaceStore { engine.spaces }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    // The workspace's own shortcut; the ninth and beyond have none.
                    if index < 9 { KeyCombo(Keys.hyper, "\(index + 1)") }
                }
                windowsSection
                othersSection
                Divider()
                Button("Delete Workspace…", role: .destructive) { confirmDelete = true }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(isDropTarget ? Color.accentColor.opacity(0.06) : .clear)
        .dropDestination(for: String.self) { payloads, _ in
            isDropTarget = false
            return dropWindows(payloads, .space(space.id))
        } isTargeted: { isDropTarget = $0 }
        .confirmationDialog("Delete “\(space.name)”?", isPresented: $confirmDelete) {
            Button("Delete Workspace", role: .destructive) { engine.removeSpace(space.id) }
        } message: {
            Text("Its windows move to the workspace on screen. Nothing is closed.")
        }
        .onAppear {
            name = space.name
            if focusName { nameFocused = true; onNamed() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold))
                .focused($nameFocused)
                .onChange(of: name) { rename(name) }
                .onSubmit { if name.trimmingCharacters(in: .whitespaces).isEmpty { name = "Untitled" } }
            Spacer()
            if spaces.activeSpaceID == space.id {
                ActiveBadge(large: true)
            } else {
                Button("Switch To") { engine.switchTo(space.id) }
            }
        }
    }


    private var windowsSection: some View {
        let windows = engine.inventory.windows.filter { spaces.placement(of: $0)?.spaceID == space.id }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Windows").font(.headline)
            if windows.isEmpty {
                Text("No windows yet. Open one while this workspace is on screen, drag one here, or move one from below.")
                    .foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(windows) { window in
                WindowRow(window: window, reason: spaces.placement(of: window)?.reason) {
                    engine.focus(window)
                }
                .contextMenu { windowMenu(window) }
                .draggable(ManageDrag.payload(window)) { dragPreview(window) }
            }
        }
    }

    @ViewBuilder
    private var othersSection: some View {
        let others = engine.inventory.windows.filter {
            let id = spaces.placement(of: $0)?.spaceID
            return id != nil && id != space.id
        }
        if !others.isEmpty {
            DisclosureGroup(isExpanded: $showsOthers) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(others) { window in
                        WindowRow(window: window, focus: { engine.focus(window) }) {
                            Text(spaces.placement(of: window)?.spaceID.flatMap(spaces.space)?.name ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Button("Move Here") { engine.move(window, to: .space(space.id)) }.controlSize(.small)
                        }
                        .contextMenu { windowMenu(window) }
                        .draggable(ManageDrag.payload(window)) { dragPreview(window) }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Windows in other workspaces (\(others.count))").font(.headline)
            }
        }
    }

    private func dragPreview(_ window: WindowInfo) -> some View {
        Label(window.title.isEmpty ? window.appName : window.title, systemImage: "macwindow")
            .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func rename(_ newName: String) {
        guard var current = spaces.space(space.id), current.name != newName else { return }
        current.name = newName
        spaces.update(current)
    }

}

// MARK: - Every workspace

/// Every Workspace or the Scratchpad: windows that don't belong to one workspace.
private struct PlaceDetail: View {
    let engine: WorkspaceEngine
    let placement: Placement
    let windowMenu: (WindowInfo) -> AnyView
    let dropWindows: ([String], Placement) -> Bool
    @State private var isDropTarget = false
    @State private var showsOthers = false

    private var spaces: SpaceStore { engine.spaces }

    var body: some View {
        let windows = engine.inventory.windows.filter { spaces.placement(of: $0)?.placement == placement }
        let apps = spaces.stickyApps.sorted { AppIcons.name(forApp: $0).localizedCaseInsensitiveCompare(AppIcons.name(forApp: $1)) == .orderedAscending }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if placement == .scratchpad {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Scratchpad").font(.system(size: 22, weight: .bold))
                        Spacer()
                        Button(spaces.isScratchpadShown ? "Hide" : "Show") { engine.toggleScratchpad() }
                            .disabled(windows.isEmpty)
                    }
                    HStack(spacing: 14) {
                        KeyCombo(Keys.hyper, "S")
                        KeyCombo(Keys.hyper, "⇧", "S")
                    }
                    Text("Out of sight until you call it up over whichever workspace you're in: a terminal, notes, a chat.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Every Workspace").font(.system(size: 22, weight: .bold))
                    Text("These windows stay on screen whichever workspace you're in: chat, music, mail.")
                        .foregroundStyle(.secondary)
                }
                if placement == .everywhere { VStack(alignment: .leading, spacing: 8) {
                    Text("Apps").font(.headline)
                    if apps.isEmpty {
                        Text("None. Right-click a window ▸ Show <App> in Every Workspace.").foregroundStyle(.secondary)
                    }
                    ForEach(apps, id: \.self) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: AppIcons.icon(forApp: app)).resizable().frame(width: 20, height: 20)
                            Text(AppIcons.name(forApp: app))
                            Spacer()
                            Button("Remove") { engine.setSticky(app, false) }.controlSize(.small)
                        }
                        .padding(.horizontal, 8)
                    }
                } }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Windows").font(.headline)
                    if windows.isEmpty {
                        Text("None. Assign one from below, or drag one here or onto “\(placement == .scratchpad ? "Scratchpad" : "Every Workspace")” in the sidebar.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(windows) { window in
                        WindowRow(window: window, reason: spaces.placement(of: window)?.reason) { engine.focus(window) }
                            .contextMenu { windowMenu(window) }
                            .draggable(ManageDrag.payload(window)) {
                                Label(window.title.isEmpty ? window.appName : window.title, systemImage: "macwindow")
                                    .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                    }
                }
                othersSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(isDropTarget ? Color.accentColor.opacity(0.06) : .clear)
        .dropDestination(for: String.self) { payloads, _ in
            isDropTarget = false
            return dropWindows(payloads, placement)
        } isTargeted: { isDropTarget = $0 }
    }
}

extension PlaceDetail {
    /// Windows that live in one workspace, to show in all of them instead (as in a workspace's
    /// "Windows in other workspaces").
    @ViewBuilder
    private var othersSection: some View {
        let others = engine.inventory.windows.filter { spaces.placement(of: $0)?.spaceID != nil }
        if !others.isEmpty {
            DisclosureGroup(isExpanded: $showsOthers) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(others) { window in
                        WindowRow(window: window, focus: { engine.focus(window) }) {
                            Text(spaces.placement(of: window)?.spaceID.flatMap(spaces.space)?.name ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Button("Assign") { engine.move(window, to: placement) }.controlSize(.small)
                        }
                        .contextMenu { windowMenu(window) }
                        .draggable(ManageDrag.payload(window)) {
                            Label(window.title.isEmpty ? window.appName : window.title, systemImage: "macwindow")
                                .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Windows in workspaces (\(others.count))").font(.headline)
            }
        }
    }
}

// MARK: - General

private struct GeneralDetail: View {
    let inventory: WindowInventory
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var canCapture = WindowCapture.isAllowed

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("General").font(.system(size: 22, weight: .bold))
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Launch HyprDesk at login", isOn: $launchesAtLogin)
                        .onChange(of: launchesAtLogin) { setLaunchAtLogin(launchesAtLogin) }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Permissions").font(.headline)
                    permission("Accessibility", granted: inventory.isTrusted,
                               why: "To see, move and focus windows, and for the ⌘Tab and ⌃-arrow shortcuts.") {
                        inventory.requestAccess()
                    }
                    permission("Screen Recording", granted: canCapture,
                               why: "For window pictures in the workspace's Mission Control. Without it, icons stand in.") {
                        WindowCapture.requestAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { canCapture = WindowCapture.isAllowed }
    }

    private func permission(_ name: String, granted: Bool, why: String, fix: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted { Button("Allow…", action: fix) }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change it: \(error.localizedDescription)"
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsDetail: View {
    @Bindable var preferences: Preferences

    private let shortcuts: [(keys: [[String]], action: String)] = [
        ([[Keys.hyper, "1–9"]], "Switch to that workspace"),
        ([[Keys.hyper, "⇧", "1–9"]], "Move the focused window to that workspace and follow it"),
        ([[Keys.hyper, "`"]], "Back to the previous workspace"),
        ([[Keys.hyper, "Space"]], "Find any window, in any workspace"),
        ([[Keys.hyper, "S"]], "Show or hide the scratchpad"),
        ([[Keys.hyper, "⇧", "S"]], "Move the focused window into the scratchpad, or back out"),
        ([["⌃", "←"], ["⌃", "→"]], "Previous / next workspace"),
        ([["⌃", "↑"]], "Overview of all workspaces"),
        ([["⌃", "↓"]], "The workspace's Mission Control"),
        ([["⌘", "Tab"]], "The workspace's windows, most recent first"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Shortcuts").font(.system(size: 22, weight: .bold))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Override macOS defaults").font(.headline)
                    Toggle("Use \(HyprDesk.name) app switcher", isOn: $preferences.replacesCommandTab)
                    Toggle("Use \(HyprDesk.name) Mission Control", isOn: $preferences.replacesMissionControl)
                    Toggle("Use \(HyprDesk.name) workspace switcher", isOn: $preferences.replacesSpaceArrows)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hyper key").font(.headline)
                    HStack(spacing: 10) {
                        Picker("Use as", selection: $preferences.hyperKey) {
                            ForEach(HyperKey.allCases) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                        KeyCombo("⌃", "⌥", "⌘")
                    }
                    Text(preferences.hyperKey == .off
                         ? "Off: bring your own (Raycast's Hyper Key, Karabiner-Elements). \(Keys.hyper) is ⌃⌥⌘ held together."
                         : "\(preferences.hyperKey.title) now presses ⌃⌥⌘, in every app. Back to normal when \(HyprDesk.name) quits.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("All shortcuts").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow {
                            KeyCombo(Keys.hyper)
                            HStack(spacing: 6) {
                                Text("Hyper:").foregroundStyle(.secondary)
                                KeyCombo("⌃", "⌥", "⌘")
                            }
                        }
                        ForEach(shortcuts, id: \.action) { shortcut in
                            GridRow {
                                KeyCombos(combos: shortcut.keys)
                                Text(shortcut.action).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
