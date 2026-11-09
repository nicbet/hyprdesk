import AppKit
import OSLog
import QuartzCore

/// Dev benchmark (`hyprdesk --bench`): opens and closes each overlay a few times on the real
/// windows and logs how long showing it blocked the main thread, and how many display frames
/// came late while it animated. Read with
/// `log show --last 1m --predicate 'subsystem == "com.github.nicbet.hyprdesk" AND category == "bench"'`.
@MainActor
final class FrameMeter: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var started: CFTimeInterval = 0

    func start(on screen: NSScreen) {
        stamps = []
        started = CACurrentMediaTime()
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
    }

    /// Frames, the longest gap between two, when it ended (ms after start), and how many gaps
    /// were over 1.5 frames.
    func stop(frameInterval: CFTimeInterval) -> (frames: Int, longest: Double, at: Double, late: Int) {
        link?.invalidate()
        link = nil
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1, $0) }
        let worst = gaps.max { $0.0 < $1.0 }
        return (stamps.count, (worst?.0 ?? 0) * 1000, ((worst?.1 ?? started) - started) * 1000,
                gaps.filter { $0.0 > frameInterval * 1.5 }.count)
    }
}

@MainActor
enum Bench {
    static let log = Logger(subsystem: "com.github.nicbet.hyprdesk", category: "bench")

    /// `cases`: name, show, hide. Each runs `rounds` times.
    static func run(_ cases: [(String, () -> Void, () -> Void)], rounds: Int = 3) async {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let interval = 1 / Double(screen.maximumFramesPerSecond)
        let meter = FrameMeter()
        for (name, show, hide) in cases {
            for round in 1...rounds {
                meter.start(on: screen)
                let start = ContinuousClock.now
                show()
                let blocked = start.duration(to: .now)
                try? await Task.sleep(for: .milliseconds(700))
                let open = meter.stop(frameInterval: interval)
                meter.start(on: screen)
                hide()
                try? await Task.sleep(for: .milliseconds(500))
                let close = meter.stop(frameInterval: interval)
                log.info("""
                    \(name, privacy: .public) #\(round): show() \(blocked.formatted(.units(allowed: [.milliseconds], width: .narrow)), privacy: .public) · \
                    open \(open.frames) frames, longest \(String(format: "%.1f", open.longest), privacy: .public) ms at \(Int(open.at)) ms, \(open.late) late · \
                    close \(close.frames) frames, longest \(String(format: "%.1f", close.longest), privacy: .public) ms, \(close.late) late
                    """)
            }
        }
        log.info("bench done (\(screen.maximumFramesPerSecond) Hz)")
    }
}
