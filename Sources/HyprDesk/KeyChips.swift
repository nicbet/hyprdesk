import SwiftUI

/// Keyboard shortcuts drawn as keys: one chip per key, the way macOS's own settings show them.
/// Hyper (⌃⌥⌘ held together) is its own key, ✦.
enum Keys {
    static let hyper = "✦"
}

/// One key.
struct KeyChip: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            // Its own colors, whatever it sits on (a selected row's white text would vanish on it).
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            .fixedSize()
    }
}

/// Keys pressed together, e.g. `KeyCombo(Keys.hyper, "⇧", "1–9")`.
struct KeyCombo: View {
    let keys: [String]

    init(_ keys: String...) { self.keys = keys }
    init(_ keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { KeyChip(key: $0.element) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// Alternatives, e.g. ⌃← and ⌃→: combos side by side, a little apart.
struct KeyCombos: View {
    let combos: [[String]]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(combos.enumerated()), id: \.offset) { KeyCombo($0.element) }
        }
    }
}
