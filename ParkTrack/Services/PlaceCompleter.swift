import Foundation
import MapKit
import Observation

/// Live place suggestions for the region indexer's search field.
///
/// Wraps `MKLocalSearchCompleter`, which is what powers the suggestion list in Maps: it
/// answers as the user types rather than only on submit, which is what a search field is
/// expected to do. Results are addresses — cities, counties, neighbourhoods — never
/// businesses, so the list stays a list of places you could plausibly index.
@Observable
@MainActor
final class PlaceCompleter: NSObject {
    private let completer = MKLocalSearchCompleter()

    private(set) var suggestions: [PlaceSuggestion] = []
    private(set) var isSearching = false

    override init() {
        super.init()
        completer.resultTypes = .address
        completer.delegate = self
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            suggestions = []
            isSearching = false
            completer.cancel()
            return
        }
        isSearching = true
        completer.queryFragment = trimmed
    }

    func clear() {
        completer.cancel()
        suggestions = []
        isSearching = false
    }
}

extension PlaceCompleter: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results.map {
            PlaceSuggestion(title: $0.title, subtitle: $0.subtitle)
        }
        Task { @MainActor in
            // A completion whose title is a street address is a building, not a place worth
            // indexing; the ones that matter read as "Redmond" / "King County".
            self.suggestions = results.filter { !$0.title.contains(where: \.isNumber) }
            self.isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.suggestions = []
            self.isSearching = false
        }
    }
}

struct PlaceSuggestion: Identifiable, Hashable {
    let title: String
    let subtitle: String

    var id: String { title + "|" + subtitle }

    /// What to hand the geocoder: the full "Redmond, WA, United States" string, since the
    /// title alone is ambiguous across the many places that share a name.
    var query: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }
}
