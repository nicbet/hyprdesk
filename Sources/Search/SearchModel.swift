import Foundation
import Observation

/// The window search (✦ Space): what's typed, what matches, which one is selected. Knows nothing
/// about panels or keys.
@MainActor
@Observable
public final class SearchModel {
    /// The field writes its text back on Return; only a real change re-ranks (and resets the
    /// selection), or Return would always pick the top result.
    public var query = "" { didSet { if query != oldValue { refresh() } } }
    public private(set) var results: [SearchCandidate] = []
    public private(set) var selection = 0
    /// Goes up every time the search opens: the view puts the cursor back in the field.
    public private(set) var openings = 0

    /// How many results show at once.
    public static let limit = 10

    @ObservationIgnored public var onPick: (SearchCandidate) -> Void = { _ in }
    @ObservationIgnored public var onDismiss: () -> Void = {}
    @ObservationIgnored private var candidates: [SearchCandidate] = []

    public init() {}

    /// Opens on `candidates`, most recently used first.
    public func begin(_ candidates: [SearchCandidate]) {
        self.candidates = candidates
        query = ""
        refresh()
        openings += 1
    }

    public func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    public func select(_ index: Int) {
        if results.indices.contains(index) { selection = index }
    }

    /// The selected result (or the one at `index`).
    public func pick(_ index: Int? = nil) {
        let index = index ?? selection
        guard results.indices.contains(index) else { return }
        onPick(results[index])
    }

    public func dismiss() { onDismiss() }

    private func refresh() {
        results = Array(WindowSearch.rank(candidates, query: query).prefix(Self.limit))
        selection = 0
    }
}
