// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hyprdesk",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "hyprdesk", targets: ["HyprDesk"]),
    ],
    targets: [
        // App shell: lifecycle, menu-bar item, Manage Workspaces window, overlays.
        .executableTarget(
            name: "HyprDesk",
            dependencies: ["WindowKit", "Spaces", "Workspaces", "Overview", "Switcher", "Expose", "Search", "Control"]
        ),
        // Every window of every app through Accessibility: listing, watching, raising.
        // Knows nothing about spaces.
        .target(name: "WindowKit"),
        // Spaces, which windows belong to them, and saving that. No AppKit.
        .target(name: "Spaces", dependencies: ["WindowKit"]),
        // Parking: shows exactly the current space's windows, switches, follows focus.
        .target(name: "Workspaces", dependencies: ["Spaces", "WindowKit"]),
        // The space switcher on ⌘Tab: the current space's windows, most recent first.
        .target(name: "Switcher", dependencies: ["WindowKit"]),
        // Finding any window in any workspace (✦ Space): ranking and the panel's state.
        .target(name: "Search", dependencies: ["WindowKit"]),
        // The command line and URL scheme: parsing commands, and the socket between the
        // `hyprdesk` command and the running app. Foundation only.
        .target(name: "Control"),
        // The space's Mission Control: pictures of its windows.
        .target(name: "Expose", dependencies: ["WindowKit"]),
        // The overview: every space as a miniature of its screen, with its windows.
        .target(name: "Overview", dependencies: ["Spaces", "WindowKit"]),

        .testTarget(name: "SpacesTests", dependencies: ["Spaces", "WindowKit"]),
        .testTarget(name: "WindowKitTests", dependencies: ["WindowKit"]),
        .testTarget(name: "SwitcherTests", dependencies: ["Switcher", "Workspaces", "WindowKit"]),
        .testTarget(name: "ExposeTests", dependencies: ["Expose"]),
        .testTarget(name: "SearchTests", dependencies: ["Search", "WindowKit"]),
        .testTarget(name: "ControlTests", dependencies: ["Control"]),
        .testTarget(name: "OverviewTests", dependencies: ["Overview", "Spaces", "WindowKit"]),
    ]
)
