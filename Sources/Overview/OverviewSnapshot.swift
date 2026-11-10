import AppKit
import Spaces
import SwiftUI
import WindowKit

/// Renders the overview offscreen with made-up spaces, for checking the layout without Screen
/// Recording permission: `hyprdesk --snapshot <dir>`.
@MainActor
public enum OverviewSnapshot {
    /// `empty`: also the overview with no workspaces (`overview-empty.png`).
    public static func write(to directory: URL, size: CGSize = CGSize(width: 1512, height: 945), empty: Bool = true) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var urls: [URL] = []
        let variants: [(String, [SpaceCard], Int)] = [("overview", sampleCards(now: now), 1)] + (empty ? [("overview-empty", [], 0)] : [])
        for (name, cards, selection) in variants {
            let model = OverviewModel(cards: cards, now: now)
            model.selection = selection
            model.columns = OverviewView.columns(forWidth: size.width, cards: cards.count)
            let content = OverviewView(model: model, scrolls: false)
                .frame(width: size.width, height: size.height)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.32), Color(red: 0.32, green: 0.18, blue: 0.24)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let url = directory.appending(path: "\(name).png")
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    static func sampleCards(now: Date) -> [SpaceCard] {
        // On a 1512 × 982 screen, below the menu bar.
        func window(_ id: UInt32, _ bundleID: String, _ app: String, _ title: String, _ x: CGFloat, _ y: CGFloat,
                    _ width: CGFloat, _ height: CGFloat, minimized: Bool = false) -> WindowInfo {
            WindowInfo(id: id, pid: 0, bundleID: bundleID, appName: app, title: title,
                       frame: CGRect(x: x, y: y, width: width, height: height), isMinimized: minimized)
        }
        // A developer's week, one app rarely twice: apps that ship with macOS or are common
        // (an app that isn't installed draws without its icon).
        let ghostty = ("com.mitchellh.ghostty", "Ghostty"), iterm = ("com.googlecode.iterm2", "iTerm")
        let zed = ("dev.zed.Zed", "Zed"), xcode = ("com.apple.dt.Xcode", "Xcode"), code = ("com.microsoft.VSCode", "Code")
        let chrome = ("com.google.Chrome", "Chrome"), firefox = ("org.mozilla.firefox", "Firefox")
        let safari = ("com.apple.Safari", "Safari")

        // Shown in every workspace: their apps sit beside each workspace's name.
        let shared = [
            window(12, "com.tinyspeck.slackmacgap", "Slack", "Slack — general", 900, 420, 590, 540),
            window(11, "com.apple.Music", "Music", "Music", 60, 120, 760, 520),
            window(17, "com.apple.MobileSMS", "Messages", "Messages", 1000, 60, 480, 600),
        ]

        let workspaces = [
            // Front to back, as cards hold them.
            SpaceCard(space: Space(name: "website"), windows: [
                window(1, iterm.0, iterm.1, "~/code/website — npm run dev", 24, 600, 620, 360),
                window(3, chrome.0, chrome.1, "localhost:3000", 700, 44, 790, 900),
                window(2, zed.0, zed.1, "index.tsx — website", 24, 44, 820, 640),
            ], isActive: false),
            SpaceCard(space: Space(name: "hyprdesk"), windows: [
                window(6, ghostty.0, ghostty.1, "~/code/hyprdesk — swift test", 960, 520, 530, 440),
                window(8, "md.obsidian", "Obsidian", "Roadmap", 960, 44, 530, 460),
                window(7, xcode.0, xcode.1, "OverviewView.swift — hyprdesk", 22, 44, 920, 916),
            ], isActive: true),
            SpaceCard(space: Space(name: "api"), windows: [
                window(10, "com.docker.docker", "Docker", "Containers", 900, 560, 590, 400),
                window(9, code.0, code.1, "routes.go — api", 40, 44, 1000, 820),
                // A busy one: more windows than tiles.
                window(20, "com.apple.Terminal", "Terminal", "go test ./...", 300, 300, 700, 420),
                window(21, "com.apple.Console", "Console", "api.log", 500, 200, 800, 600),
                window(22, "com.apple.ActivityMonitor", "Activity Monitor", "All Processes", 600, 100, 700, 500),
                window(23, "com.apple.Preview", "Preview", "schema.pdf", 200, 150, 600, 700),
                window(24, "com.apple.TextEdit", "TextEdit", "notes.txt", 100, 400, 500, 400),
                window(25, "com.apple.calculator", "Calculator", "Calculator", 1200, 600, 230, 400),
                window(26, "com.apple.finder", "Finder", "api", 800, 500, 600, 400),
            ], isActive: false),
            SpaceCard(space: Space(name: "design"), windows: [
                window(5, firefox.0, firefox.1, "Inspiration — Firefox", 880, 300, 610, 660),
                window(4, "com.bohemiancoding.sketch3", "Sketch", "Landing page", 30, 44, 1050, 800),
                window(16, "com.apple.finder", "Finder", "assets", 1040, 44, 450, 300),
            ], isActive: false),
            SpaceCard(space: Space(name: "blog"), windows: [
                window(13, safari.0, safari.1, "localhost:1313 — Blog", 760, 44, 730, 916),
                window(15, "abnerworks.Typora", "Typora", "hello-hyprdesk.md", 40, 44, 700, 916),
            ], isActive: false),
        ]
        // The scratchpad: centred over the workspace, in 80% of the screen.
        let scratchpad = SpaceCard(space: nil, windows: [
            window(19, ghostty.0, ghostty.1, "scratch — zsh", 190, 330, 680, 460),
            window(18, "com.apple.Notes", "Notes", "Today", 760, 150, 560, 560),
        ], isActive: false)
        return workspaces.map { card in
            var card = card
            card.shared = shared
            return card
        } + [scratchpad]
    }
}
