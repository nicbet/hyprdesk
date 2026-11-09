// Draws HyprDesk's app icon and writes Resources/AppIcon.icns (and a 1024 px preview PNG).
// Usage: swift scripts/make-icon.swift   (from the repository root)
//
// A dark squircle holding a small deck of workspaces; the front one wears Hyprland's default
// active-window border (cyan to green), and carries ✦, the hyper key.
import AppKit
import SwiftUI

struct Icon: View {
    static let cyan = Color(red: 0x33 / 255, green: 0xcc / 255, blue: 0xff / 255)
    static let green = Color(red: 0x00 / 255, green: 0xff / 255, blue: 0x99 / 255)

    var body: some View {
        ZStack {
            // Apple's grid: an 824 pt body on the 1024 canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.15, blue: 0.29), Color(red: 0.04, green: 0.05, blue: 0.11)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            deck
        }
        .frame(width: 1024, height: 1024)
    }

    private var deck: some View {
        ZStack {
            // The workspaces behind.
            pane(opacity: 0.07).offset(x: 92, y: -118)
            pane(opacity: 0.12).offset(x: 46, y: -59)
            // The one on screen.
            RoundedRectangle(cornerRadius: 46, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.24), Color(red: 0.06, green: 0.07, blue: 0.15)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 46, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Self.cyan, Self.green], startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 20)
                )
                .overlay(
                    Text("✦")
                        .font(.system(size: 230, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: Self.cyan.opacity(0.55), radius: 26)
                )
                .frame(width: 470, height: 360)
                .shadow(color: Self.cyan.opacity(0.35), radius: 34)
        }
        .offset(x: -46, y: 59)  // centered as a whole
    }

    private func pane(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 46, style: .continuous)
            .fill(.white.opacity(opacity))
            .overlay(RoundedRectangle(cornerRadius: 46, style: .continuous).strokeBorder(.white.opacity(opacity + 0.08), lineWidth: 4))
            .frame(width: 470, height: 360)
    }
}

@MainActor
func render(size: Int) -> Data? {
    let renderer = ImageRenderer(content: Icon().scaleEffect(CGFloat(size) / 1024).frame(width: CGFloat(size), height: CGFloat(size)))
    renderer.scale = 1
    guard let image = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try! render(size: base * scale)!.write(to: iconset.appending(path: name))
        }
    }
    try! FileManager.default.createDirectory(at: root.appending(path: "Resources"), withIntermediateDirectories: true)
    try! render(size: 1024)!.write(to: root.appending(path: "Resources/AppIcon.png"))
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
    try! iconutil.run()
    iconutil.waitUntilExit()
    print(iconutil.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil failed")
}
