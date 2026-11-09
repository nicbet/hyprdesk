import CoreGraphics
import Foundation

/// One app window, as Accessibility reports it.
public struct WindowInfo: Equatable, Identifiable, Sendable {
    /// The window server's ID. Stable while the window lives; a relaunched app gets new ones.
    public var id: CGWindowID
    public var pid: pid_t
    public var bundleID: String?
    public var appName: String
    public var title: String
    /// The file a document window shows (`AXDocument`): Sketch, Preview, Xcode, TextEdit…
    public var document: URL?
    public var frame: CGRect
    public var isMinimized: Bool

    public init(
        id: CGWindowID, pid: pid_t, bundleID: String? = nil, appName: String, title: String,
        document: URL? = nil, frame: CGRect = .zero, isMinimized: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.document = document
        self.frame = frame
        self.isMinimized = isMinimized
    }

    /// Who made the window: the bundle ID, else the app name.
    public var appKey: String { bundleID ?? appName }
}
