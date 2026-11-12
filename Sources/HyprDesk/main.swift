import AppKit
import Control
import Expose
import Overview
import Switcher
import SwiftUI
import WindowKit

enum HyprDesk {
    static let name = "HyprDesk"
    static let version = "0.3.3"
}

// `hyprdesk <command>`: the command line, asking the running app (see `Commands`). Prints JSON;
// exits 1 when the app says no, 2 when it isn't running. Any first word that isn't a flag means
// the command line (a typo must never start a second copy of the app); the app's own flags
// (`--manage`, `--snapshot`, macOS's `-psn_…`) start with a dash.
if CommandLine.arguments.count > 1, Command.isCommand(CommandLine.arguments[1]) || !CommandLine.arguments[1].hasPrefix("-") {
    let args = Array(CommandLine.arguments.dropFirst())
    func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("hyprdesk: \(message)\n".utf8))
        FileHandle.standardOutput.write(JSON.failure(message).encoded(pretty: true) + Data("\n".utf8))
        exit(code)
    }
    do {
        if try Command.parse(args) == .help {
            print(Command.usage)
            exit(0)
        }
    } catch {
        fail(error.description, code: 1)
    }
    do {
        let answer = try ControlSocket.send(args)
        FileHandle.standardOutput.write(answer.encoded(pretty: true) + Data("\n".utf8))
        exit(answer["ok"] == true ? 0 : 1)
    } catch {
        fail(error.description, code: 2)
    }
}

// Dev tool: `hyprdesk --readme-images <dir>` renders the README's picture from sample data: the
// overview, cropped to its cards.
if let flag = CommandLine.arguments.firstIndex(of: "--readme-images") {
    let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst(flag + 1).first ?? "docs")
    MainActor.assumeIsolated {
        do {
            for url in try OverviewSnapshot.write(to: dir, size: CGSize(width: 1512, height: 690), empty: false) { print(url.path) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("readme images failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

// Dev tool: `hyprdesk --snapshot <dir>` renders the overview with sample spaces to PNGs.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst(flag + 1).first ?? "build/snapshots")
    MainActor.assumeIsolated {
        do {
            for url in try OverviewSnapshot.write(to: dir) { print(url.path) }
            print(try switcherSnapshot(to: dir).path)
            print(try exposeSnapshot(to: dir).path)
            print(try nameTagSnapshot(to: dir).path)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

/// The switcher with sample windows, the third one selected.
@MainActor
func switcherSnapshot(to dir: URL) throws -> URL {
    let model = SwitcherModel()
    let samples: [(String, String, String)] = [
        ("com.mitchellh.ghostty", "Ghostty", "~/code/hyprdesk — zsh"),
        ("com.microsoft.VSCode", "Code", "OverviewView.swift — hyprdesk"),
        ("com.google.Chrome", "Chrome", "localhost:3000 — HyprDesk"),
        ("com.apple.finder", "Finder", "hyprdesk"),
        ("com.mitchellh.ghostty", "Ghostty", "~/code/hyprdesk — make dev"),
        ("com.apple.Safari", "Safari", "AeroSpace — GitHub"),
    ]
    model.begin(samples.enumerated().map { index, sample in
        WindowInfo(id: CGWindowID(index + 1), pid: 0, bundleID: sample.0, appName: sample.1, title: sample.2)
    }, title: "hyprdesk", pointer: .zero)
    model.next()
    let renderer = ImageRenderer(content: SwitcherView(model: model) { _ in }.padding(40)
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.35, blue: 0.5), Color(red: 0.45, green: 0.3, blue: 0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)))
    renderer.scale = 2
    let url = dir.appending(path: "switcher.png")
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return url }
    try data.write(to: url)
    return url
}

/// The name tag, third of five spaces.
@MainActor
func nameTagSnapshot(to dir: URL) throws -> URL {
    let model = SpaceNameTagModel()
    model.name = "hyprdesk"
    model.index = 2
    model.count = 5
    let content = SpaceNameTag(model: model)
        .background(Color(white: 0.12).opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(40)
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.35, blue: 0.5), Color(red: 0.45, green: 0.3, blue: 0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    let url = dir.appending(path: "nametag.png")
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return url }
    try data.write(to: url)
    return url
}

/// The space's Mission Control with sample windows, painted as plain placeholder pictures.
@MainActor
func exposeSnapshot(to dir: URL) throws -> URL {
    let size = CGSize(width: 1512, height: 945)
    let samples: [(String, String, String, CGRect, (Double, Double, Double))] = [
        ("com.mitchellh.ghostty", "Ghostty", "~/code/hyprdesk — zsh", CGRect(x: 0, y: 30, width: 760, height: 900), (0.1, 0.12, 0.2)),
        ("com.microsoft.VSCode", "Code", "ExposeView.swift — hyprdesk", CGRect(x: 380, y: 60, width: 1100, height: 860), (0.13, 0.14, 0.16)),
        ("com.google.Chrome", "Chrome", "localhost:3000 — HyprDesk", CGRect(x: 600, y: 120, width: 900, height: 700), (0.95, 0.95, 0.97)),
        ("com.apple.finder", "Finder", "hyprdesk", CGRect(x: 200, y: 500, width: 700, height: 420), (0.92, 0.93, 0.95)),
        ("com.mitchellh.ghostty", "Ghostty", "~/code/hyprdesk — make dev", CGRect(x: 900, y: 520, width: 600, height: 400), (0.1, 0.12, 0.2)),
    ]
    let model = ExposeModel()
    let windows = samples.enumerated().map { index, sample in
        WindowInfo(id: CGWindowID(index + 1), pid: 0, bundleID: sample.0, appName: sample.1, title: sample.2, frame: sample.3)
    }
    model.begin(windows, title: "hyprdesk", screen: CGRect(origin: .zero, size: size))
    for (index, sample) in samples.enumerated() { model.images[CGWindowID(index + 1)] = placeholder(sample.3.size, color: sample.4) }
    model.setExpanded(true)
    model.isSettled = true
    model.selection = 1
    let content = ExposeView(model: model).frame(width: size.width, height: size.height)
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.35, blue: 0.5), Color(red: 0.45, green: 0.3, blue: 0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    let url = dir.appending(path: "expose.png")
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return url }
    try data.write(to: url)
    return url
}

/// A window-ish picture: a title bar and a few lines of "content".
func placeholder(_ size: CGSize, color: (Double, Double, Double)) -> CGImage? {
    let width = Int(size.width), height = Int(size.height)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let dark = color.0 < 0.5
    context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: dark ? 0.22 : 0.85, alpha: 1))
    context.fill(CGRect(x: 0, y: height - 52, width: width, height: 52))
    context.setFillColor(CGColor(gray: dark ? 0.45 : 0.7, alpha: 1))
    for line in 0..<12 {
        let y = height - 100 - line * 44
        guard y > 20 else { break }
        context.fill(CGRect(x: 40, y: y, width: Int(Double(width - 80) * (0.4 + 0.5 * Double((line * 7) % 5) / 4)), height: 16))
    }
    return context.makeImage()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
