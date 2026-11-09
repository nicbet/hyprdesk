import CoreGraphics
import Foundation
import WindowKit

/// A window on offer in the search, with where it lives.
public struct SearchCandidate: Identifiable, Equatable, Sendable {
    public let window: WindowInfo
    /// Its workspace's name, or "Every Workspace", "Scratchpad".
    public let place: String?
    /// Its workspace's position (0-based), for the ✦ number.
    public let placeIndex: Int?

    public var id: CGWindowID { window.id }

    public init(window: WindowInfo, place: String?, placeIndex: Int?) {
        self.window = window
        self.place = place
        self.placeIndex = placeIndex
    }
}

/// Finds windows by title, app and workspace name. Every word typed must match somewhere: at
/// the start of a word scores best (in the app's name a little more), anywhere inside a word
/// less. Ties keep the order given (most recently used first).
public enum WindowSearch {
    public static func rank(_ candidates: [SearchCandidate], query: String) -> [SearchCandidate] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !words.isEmpty else { return candidates }
        return candidates.enumerated()
            .compactMap { offset, candidate in score(candidate, words: words).map { (offset, $0, candidate) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
    }

    /// nil when some word matches nowhere.
    public static func score(_ candidate: SearchCandidate, query: String) -> Int? {
        score(candidate, words: query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) })
    }

    static func score(_ candidate: SearchCandidate, words: [String]) -> Int? {
        let fields: [(text: String, bonus: Int)] = [
            (fold(candidate.window.appName), 1),
            (fold(candidate.window.title), 0),
            (fold(candidate.place ?? ""), 0),
            (fold(candidate.window.document?.lastPathComponent ?? ""), 0),
        ]
        var total = 0
        for word in words {
            var best: Int?
            for field in fields where !field.text.isEmpty {
                let tokens = field.text.split { !$0.isLetter && !$0.isNumber }
                let points: Int? = if tokens.contains(where: { $0.hasPrefix(word) }) { 3 + field.bonus }
                    else if field.text.contains(word) { 1 } else { nil }
                if let points { best = max(best ?? 0, points) }
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
