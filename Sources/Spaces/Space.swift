import Foundation
import WindowKit

/// A workspace: a name, and (in `SpaceStore`) the windows of any app that belong to it.
public struct Space: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Why a window is in its workspace.
public enum MatchReason: String, Codable, Sendable {
    /// Put there by hand.
    case manual
    /// Its app shows in every workspace.
    case stickyApp
    /// Opened while that workspace was active.
    case openedHere
}

/// What a window is remembered by, to find it again after its app relaunches (window IDs don't
/// survive that): the app plus the document, else the exact title.
public struct WindowFingerprint: Codable, Hashable, Sendable {
    public var app: String
    public var document: String?
    public var title: String?

    public init(_ window: WindowInfo) {
        app = window.appKey
        document = window.document?.path
        title = window.document == nil ? window.title : nil
    }

    public func matches(_ window: WindowInfo) -> Bool {
        guard window.appKey == app else { return false }
        if let document { return window.document?.path == document }
        return window.document == nil && window.title == title
    }
}
