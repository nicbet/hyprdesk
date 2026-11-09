import CoreGraphics
import Foundation
import Observation
import WindowKit

/// Where a window lives.
public enum Placement: Hashable, Sendable {
    case space(UUID)
    /// Shown in every workspace (Slack, Music, a window put there by hand).
    case everywhere
    /// Out of sight until the scratchpad is shown (✦ S), then over whichever workspace is on
    /// screen: Hyprland's special workspace.
    case scratchpad
}

public struct WindowAssignment: Equatable, Sendable {
    public var placement: Placement
    public var reason: MatchReason

    public init(_ placement: Placement, _ reason: MatchReason) {
        self.placement = placement
        self.reason = reason
    }

    public var spaceID: UUID? {
        if case .space(let id) = placement { id } else { nil }
    }
}

/// The workspaces, which one is on screen, and which workspace every window belongs to.
///
/// The Hyprland model: a window lives in the workspace it opened in until you move it, and that
/// is remembered across restarts. A window's workspace, first that applies:
/// 1. its own record, by window ID (exact: HyprDesk restarted, the app kept running),
/// 2. when the window is being restored (open at our launch, or its app just launched): an
///    unclaimed record with the same app and document or title (best effort),
/// 3. an app shown in every workspace: there,
/// 4. the current workspace.
/// A brand-new window never inherits an old record by coincidence: it joins where you are.
/// With no workspaces at all, windows have no placement and stay where they are.
@MainActor
@Observable
public final class SpaceStore {
    public private(set) var spaces: [Space] = []
    /// The workspace on screen. Saved.
    public var activeSpaceID: UUID? {
        didSet { save() }
    }
    /// Apps whose windows show in every workspace, by bundle ID. Saved.
    public private(set) var stickyApps: Set<String> = []
    /// The scratchpad's windows are on screen, over the current workspace. This run only.
    public var isScratchpadShown = false

    /// This run: each known window's placement.
    private var placements: [CGWindowID: WindowAssignment] = [:]
    /// Saved: where every window lives, to find it again after a restart.
    @ObservationIgnored private var records: [Record] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// A closed window's record goes once its app has been running this long without it (an
    /// app quitting closes its windows first; those records must stay for its relaunch).
    public static let closedGrace: TimeInterval = 15
    /// Records no window has claimed for this long are forgotten.
    public static let forgetAfter: TimeInterval = 3 * 24 * 3600
    /// Title changes are frequent; they're saved in batches.
    static let saveDelay: Duration = .seconds(2)

    struct Record: Codable, Equatable {
        /// The window it was last seen as; window IDs don't survive the app quitting.
        var windowID: CGWindowID?
        var fingerprint: WindowFingerprint
        /// nil: every workspace (or the scratchpad).
        var spaceID: UUID?
        /// In the scratchpad (then `spaceID` is nil). Left out of the file unless true.
        var scratchpad: Bool?
        var reason: MatchReason
        var lastSeen: Date
        /// When its window disappeared, while waiting to tell "closed" from "app quit".
        var goneAt: Date?
    }

    private struct Saved: Codable {
        var spaces: [Space]
        var windows: [Record]?
        var activeSpaceID: UUID?
        var stickyApps: Set<String>?
    }

    /// `~/Library/Application Support/HyprDesk/spaces.json`.
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "HyprDesk/spaces.json")
    }

    /// Loads from `fileURL` and saves every change there; nil keeps everything in memory.
    public init(fileURL: URL? = SpaceStore.defaultFileURL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? decoder.decode(Saved.self, from: data) else { return }
        spaces = saved.spaces
        records = saved.windows ?? []
        stickyApps = saved.stickyApps ?? []
        activeSpaceID = saved.activeSpaceID.flatMap { id in saved.spaces.contains { $0.id == id } ? id : nil }
            ?? saved.spaces.first?.id
    }

    public var activeSpace: Space? { spaces.first { $0.id == activeSpaceID } }

    public func space(_ id: UUID?) -> Space? { spaces.first { $0.id == id } }

    // MARK: Placement

    public func placement(of window: WindowInfo) -> WindowAssignment? {
        placements[window.id]
    }

    /// Whether `window` belongs on screen in the current workspace.
    public func isShown(_ window: WindowInfo) -> Bool {
        switch placements[window.id]?.placement {
        case nil, .everywhere: true
        case .space(let id): id == activeSpaceID
        case .scratchpad: isScratchpadShown
        }
    }

    /// Places windows seen for the first time. `restoring`: the window is coming back (open at
    /// our launch, or its app just launched), so an old record may be its own.
    public func place(_ windows: [WindowInfo], restoring: (WindowInfo) -> Bool, now: Date = .now) {
        var changed = false
        for window in windows where placements[window.id] == nil {
            let fingerprint = WindowFingerprint(window)
            // 1. Its own record.
            var index = records.firstIndex { $0.windowID == window.id && $0.fingerprint.app == fingerprint.app }
            // 2. Restoring: an unclaimed record that looks the same.
            if index == nil, restoring(window) {
                index = records.firstIndex { record in
                    (record.windowID.map { placements[$0] == nil } ?? true) && record.fingerprint.matches(window)
                }
            }
            if let index, let assignment = assignment(from: records[index], app: fingerprint.app) {
                placements[window.id] = assignment
                records[index].windowID = window.id
                records[index].fingerprint = fingerprint
                records[index].lastSeen = now
                records[index].goneAt = nil
                changed = true
                continue
            }
            // 3. and 4.
            if stickyApps.contains(fingerprint.app) {
                placements[window.id] = WindowAssignment(.everywhere, .stickyApp)
            } else if let current = activeSpaceID {
                placements[window.id] = WindowAssignment(.space(current), .openedHere)
                remember(window, placement: .space(current), reason: .openedHere, now: now)
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    /// A record's placement, if its workspace still exists. Sticky apps win over everything but
    /// a hand-made placement.
    private func assignment(from record: Record, app: String) -> WindowAssignment? {
        if record.scratchpad == true { return WindowAssignment(.scratchpad, record.reason) }
        if record.reason != .manual, stickyApps.contains(app) { return WindowAssignment(.everywhere, .stickyApp) }
        guard let id = record.spaceID else { return WindowAssignment(.everywhere, record.reason) }
        return space(id) == nil ? nil : WindowAssignment(.space(id), record.reason)
    }

    /// Keeps up with the windows: drops placements of windows that are gone, notes title
    /// changes, and forgets records of windows that were closed (their app still running a
    /// while later) or that nothing claimed for days. `runningApps`: bundle IDs (or names).
    public func windowsChanged(_ live: [WindowInfo], runningApps: Set<String>, now: Date = .now) {
        let liveIDs = Set(live.map(\.id))
        var changed = false
        if placements.keys.contains(where: { !liveIDs.contains($0) }) {
            placements = placements.filter { liveIDs.contains($0.key) }
        }
        for index in records.indices {
            guard let id = records[index].windowID else { continue }
            if liveIDs.contains(id) {
                if records[index].goneAt != nil { records[index].goneAt = nil; changed = true }
            } else if records[index].goneAt == nil {
                records[index].goneAt = now
                changed = true
            }
        }
        let before = records.count
        records.removeAll { record in
            if let gone = record.goneAt, now.timeIntervalSince(gone) > Self.closedGrace, runningApps.contains(record.fingerprint.app) {
                return true  // closed while its app kept running
            }
            let unclaimed = record.windowID.map { !liveIDs.contains($0) } ?? true
            return unclaimed && now.timeIntervalSince(record.lastSeen) > Self.forgetAfter
        }
        changed = changed || records.count != before
        // Titles change all the time (terminals especially): keep the latest, for restoring.
        for window in live {
            guard let index = records.firstIndex(where: { $0.windowID == window.id }) else { continue }
            let fingerprint = WindowFingerprint(window)
            if records[index].fingerprint != fingerprint || now.timeIntervalSince(records[index].lastSeen) > 3600 {
                records[index].fingerprint = fingerprint
                records[index].lastSeen = now
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    // MARK: Editing

    /// Puts `window` somewhere by hand.
    public func move(_ window: WindowInfo, to placement: Placement, now: Date = .now) {
        placements[window.id] = WindowAssignment(placement, .manual)
        remember(window, placement: placement, reason: .manual, now: now)
        save()
    }

    /// Makes `app`'s windows show in every workspace, or not (they then join the current one).
    /// Windows put somewhere by hand stay there.
    public func setSticky(_ app: String, _ sticky: Bool, windows: [WindowInfo]) {
        if sticky { stickyApps.insert(app) } else { stickyApps.remove(app) }
        for window in windows where window.appKey == app && placements[window.id]?.reason != .manual {
            placements[window.id] = nil
            records.removeAll { $0.windowID == window.id }
            place([window], restoring: { _ in false })
        }
        save()
    }

    @discardableResult
    public func addSpace(name: String) -> Space {
        let space = Space(name: name)
        spaces.append(space)
        if activeSpaceID == nil { activeSpaceID = space.id }
        save()
        return space
    }

    /// Reorders workspaces, as `Array.move(fromOffsets:toOffset:)` does. The order is what
    /// hyper + 1–9 and ⌃← ⌃→ follow.
    public func moveSpaces(fromOffsets source: IndexSet, toOffset destination: Int) {
        spaces.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Moves `id` to sit just before `target` (to the end when `target` is nil).
    public func moveSpace(_ id: UUID, before target: UUID?) {
        guard id != target, let from = spaces.firstIndex(where: { $0.id == id }) else { return }
        let to = target.flatMap { target in spaces.firstIndex { $0.id == target } } ?? spaces.count
        moveSpaces(fromOffsets: IndexSet(integer: from), toOffset: to)
    }

    public func update(_ space: Space) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        spaces[index] = space
        save()
    }

    /// Removes a workspace. Its windows move to the current one (the first one left if it was
    /// the current one).
    public func removeSpace(_ id: UUID) {
        spaces.removeAll { $0.id == id }
        if activeSpaceID == id { activeSpaceID = spaces.first?.id }
        for (window, placement) in placements where placement.spaceID == id {
            placements[window] = activeSpaceID.map { WindowAssignment(.space($0), .openedHere) }
        }
        for index in records.indices where records[index].spaceID == id {
            records[index].spaceID = activeSpaceID
            records[index].reason = .openedHere
        }
        records.removeAll { $0.spaceID == nil && $0.scratchpad != true && $0.reason == .openedHere }
        save()
    }

    // MARK: Saving

    private func remember(_ window: WindowInfo, placement: Placement, reason: MatchReason, now: Date) {
        let spaceID: UUID? = if case .space(let id) = placement { id } else { nil }
        var record = Record(windowID: window.id, fingerprint: WindowFingerprint(window), spaceID: spaceID, reason: reason, lastSeen: now)
        if placement == .scratchpad { record.scratchpad = true }
        if let index = records.firstIndex(where: { $0.windowID == window.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    /// Saves any batched changes now (before quitting).
    public func flush() {
        guard pendingSave != nil else { return }
        save()
    }

    private func scheduleSave() {
        guard fileURL != nil, pendingSave == nil else { return }
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let fileURL else { return }
        let saved = Saved(spaces: spaces, windows: records, activeSpaceID: activeSpaceID, stickyApps: stickyApps)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(saved).write(to: fileURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("hyprdesk: couldn't save \(fileURL.path): \(error)\n".utf8))
        }
    }
}
