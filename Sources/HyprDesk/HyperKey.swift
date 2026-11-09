import Foundation
import OSLog

/// HyprDesk's own hyper key, so nobody needs another app for one: the chosen key (Caps Lock, Right
/// ⌘, Right ⌥ or Right ⌃) is remapped to F18 for this login session with macOS's `hidutil`, and `KeyTap`
/// turns F18 held down into ⌃⌥⌘ for every other key, in every app.
///
/// The remapping merges with any `hidutil` mappings already set (only ours, the ones onto F18,
/// are replaced) and is taken back out on quit. It lasts until logout either way, so a crash
/// leaves the key as F18 until HyprDesk runs again.
enum HyperKey: String, CaseIterable, Identifiable, Sendable {
    case off
    case capsLock
    case rightCommand
    case rightOption
    case rightControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .capsLock: "Caps Lock"
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        }
    }

    /// The virtual key code F18 arrives with, once remapped.
    static let f18KeyCode: Int64 = 79

    /// HID usages (keyboard page 0x07), as `hidutil` wants them.
    private static let f18Usage: UInt64 = 0x7_0000_006D
    private var usage: UInt64? {
        switch self {
        case .off: nil
        case .capsLock: 0x7_0000_0039
        case .rightCommand: 0x7_0000_00E7
        case .rightOption: 0x7_0000_00E6
        case .rightControl: 0x7_0000_00E4
        }
    }

    private static let log = Logger(subsystem: "com.github.nicbet.hyprdesk", category: "hyper")

    /// Makes `self` the key that turns into F18 (or none, for `.off`).
    func apply() {
        var mappings = Self.currentMappings().filter { $0.destination != Self.f18Usage }
        if let usage { mappings.append((usage, Self.f18Usage)) }
        Self.set(mappings)
        Self.log.info("hyper key: \(self.title, privacy: .public)")
    }

    /// The key back to itself: our mappings out, everyone else's kept.
    static func remove() {
        set(currentMappings().filter { $0.destination != f18Usage })
    }

    // MARK: hidutil

    private typealias Mapping = (source: UInt64, destination: UInt64)

    /// `hidutil property --get UserKeyMapping` prints a property list in the old style, or
    /// "(null)": the numbers after Src and Dst are all that's needed.
    private static func currentMappings() -> [Mapping] {
        guard let output = run(["property", "--get", "UserKeyMapping"]) else { return [] }
        var sources: [UInt64] = [], destinations: [UInt64] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ";"))) }
            guard parts.count == 2, let value = UInt64(parts[1]) else { continue }
            if parts[0] == "HIDKeyboardModifierMappingSrc" { sources.append(value) }
            if parts[0] == "HIDKeyboardModifierMappingDst" { destinations.append(value) }
        }
        return Array(zip(sources, destinations)).map { (source: $0.0, destination: $0.1) }
    }

    private static func set(_ mappings: [Mapping]) {
        let entries = mappings.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}" }
        _ = run(["property", "--set", "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"])
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            log.error("hidutil: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
