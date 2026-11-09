import CoreGraphics
import ScreenCaptureKit
import Synchronization

/// Pictures of single windows through ScreenCaptureKit: each window on its own, so windows
/// covered by others come out whole. Needs the Screen Recording permission.
public enum WindowCapture {
    /// Whether Screen Recording is allowed. Asking macOS costs several milliseconds, too much
    /// for every opening, so the answer is kept for a few seconds.
    public static var isAllowed: Bool {
        let now = ContinuousClock.now
        return allowed.withLock { cached in
            if let cached = cached, now - cached.at < .seconds(5) { return cached.value }
            let value = CGPreflightScreenCaptureAccess()
            cached = (value, now)
            return value
        }
    }

    private static let allowed = Mutex<(value: Bool, at: ContinuousClock.Instant)?>(nil)

    /// Asks macOS to show its Screen Recording prompt (once; later it's System Settings).
    public static func requestAccess() {
        CGRequestScreenCaptureAccess()
    }

    /// Images of the windows, each fitting its size in points (at `scale` pixels per point),
    /// all captured in parallel. Windows that are gone or can't be captured are left out.
    public static func capture(_ sizes: [CGWindowID: CGSize], scale: CGFloat = 2) async -> [CGWindowID: CGImage] {
        guard isAllowed, !sizes.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return [:] }
        let windows = content.windows.filter { sizes[$0.windowID] != nil }.map(WindowBox.init)
        return await withTaskGroup(of: ImageBox?.self) { group in
            for box in windows {
                let size = sizes[box.window.windowID]!
                group.addTask { await image(of: box.window, maxSize: size, scale: scale) }
            }
            var images: [CGWindowID: CGImage] = [:]
            for await result in group {
                if let result { images[result.id] = result.image }
            }
            return images
        }
    }

    /// Every display as it looks right now, without this app's own windows, keyed by display
    /// ID, at `scale` pixels per point. Empty without Screen Recording.
    public static func captureDisplays(scale: CGFloat = 1) async -> [CGDirectDisplayID: CGImage] {
        guard isAllowed, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [:] }
        let me = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == me }
        let displays = content.displays.map { DisplayBox(display: $0, own: own) }
        return await withTaskGroup(of: (CGDirectDisplayID, CGImage)?.self) { group in
            for box in displays {
                group.addTask {
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int(CGFloat(box.display.width) * scale))
                    config.height = max(1, Int(CGFloat(box.display.height) * scale))
                    config.showsCursor = false
                    let filter = SCContentFilter(display: box.display, excludingApplications: box.own, exceptingWindows: [])
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
                    return (box.display.displayID, flattened(image) ?? image)
                }
            }
            var images: [CGDirectDisplayID: CGImage] = [:]
            for await result in group {
                if let result { images[result.0] = result.1 }
            }
            return images
        }
    }

    private static func image(of window: SCWindow, maxSize: CGSize, scale pixels: CGFloat) async -> ImageBox? {
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return nil }
        let scale = min(1, maxSize.width / frame.width, maxSize.height / frame.height)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(frame.width * scale * pixels))
        config.height = max(1, Int(frame.height * scale * pixels))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let captured = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return ImageBox(id: window.windowID, image: flattened(captured) ?? captured)
    }

    /// A plain bitmap copy, made here on the capture task. Captures come backed by GPU surfaces,
    /// and drawing one the first time costs the main thread tens of milliseconds.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// ScreenCaptureKit's objects are immutable snapshots; they cross into capture tasks as is.
private struct WindowBox: @unchecked Sendable {
    let window: SCWindow
}

private struct DisplayBox: @unchecked Sendable {
    let display: SCDisplay
    let own: [SCRunningApplication]
}

private struct ImageBox: @unchecked Sendable {
    let id: CGWindowID
    let image: CGImage
}
