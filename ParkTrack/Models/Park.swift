import Foundation
import CoreLocation
import SwiftData

/// A park discovered from the map, cached locally so lists and stats work offline.
///
/// Nothing about this model is region-specific: every field is populated from
/// whatever the map and geocoder return for the coordinates involved.
@Model
final class Park {
    /// Stable identity derived from name + rounded coordinate. See `Park.identity(name:coordinate:)`.
    var identifier: String = ""
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0

    /// Raw point-of-interest category string from the map provider, when it offered one.
    var categoryRaw: String?

    // Resolved by `RegionResolver`. Nil until reverse geocoding has run for this park.
    var locality: String?
    var subAdministrativeArea: String?
    var administrativeArea: String?
    var country: String?
    var postalAddress: String?

    var isWishlisted: Bool = false
    var discoveredAt: Date = Date()
    /// Last time a reverse-geocode filled in the region fields, so we don't re-run it forever.
    var regionResolvedAt: Date?

    /// Set when the region came from nearby parks rather than from this park's own placemark.
    ///
    /// Inference is a shortcut around a geocoder that answers about once a second, and it is
    /// usually right — but it guesses, and a guess that lands on the wrong side of a river
    /// quietly adds a park to another city's total. Marking them means they can be checked
    /// later without re-geocoding the whole catalogue.
    var regionInferredAt: Date?

    /// Last time the geocoder was asked to confirm where this park actually is.
    ///
    /// Distinct from `regionResolvedAt`, which only says the fields were filled in — by a
    /// lookup, by a search result, or by a guess from the neighbours. This says the answer
    /// has been checked against the map itself, and it is what lets a recheck work through a
    /// catalogue a batch at a time instead of starting from the same parks every run.
    var regionVerifiedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Visit.park)
    var visits: [Visit]? = []

    init(
        identifier: String,
        name: String,
        latitude: Double,
        longitude: Double,
        categoryRaw: String? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.categoryRaw = categoryRaw
        self.discoveredAt = Date()
    }
}

extension Park {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var sortedVisits: [Visit] {
        (visits ?? []).sorted { $0.date > $1.date }
    }

    var visitCount: Int { visits?.count ?? 0 }
    var isVisited: Bool { visitCount > 0 }

    /// The visits that carry a real date, which are the only ones any time-shaped figure may
    /// count. A park marked visited without a date is still visited — it simply has no day
    /// to put on a timeline. See `Visit.isUndated`.
    var datedVisits: [Visit] { (visits ?? []).filter { !$0.isUndated } }

    /// True when the park is visited but nothing says when.
    var isVisitedWithoutADate: Bool { isVisited && datedVisits.isEmpty }

    var firstVisitDate: Date? { datedVisits.map(\.date).min() }
    var lastVisitDate: Date? { datedVisits.map(\.date).max() }

    /// Average of the ratings that were actually given, ignoring unrated visits.
    var averageRating: Double? {
        let ratings = (visits ?? []).compactMap { $0.rating > 0 ? Double($0.rating) : nil }
        guard !ratings.isEmpty else { return nil }
        return ratings.reduce(0, +) / Double(ratings.count)
    }

    /// Human-readable "City, ST" when known, falling back to whatever region detail exists.
    var regionLabel: String? {
        let parts = [locality, administrativeArea].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? country : parts.joined(separator: ", ")
    }

    /// Fills in the region fields a map result already knew, so the park is placeable in a
    /// city without a round trip to the geocoder. Only counts as resolved when the search
    /// result actually carried a locality — a bare country is not enough to group by.
    func apply(_ candidate: ParkCandidate) {
        // A search result carries the map's own placemark for that place, which outranks a
        // region guessed from the parks nearby. So re-finding a park — which is what indexing
        // a city does to everything already in it — is the chance to correct one that was
        // guessed wrongly, rather than leaving the old answer because a field was non-nil.
        let outranksWhatWeHave = candidate.locality != nil && regionVerifiedAt == nil

        if let value = candidate.locality, locality == nil || outranksWhatWeHave {
            locality = value
        }
        if let value = candidate.subAdministrativeArea, subAdministrativeArea == nil || outranksWhatWeHave {
            subAdministrativeArea = value
        }
        if let value = candidate.administrativeArea, administrativeArea == nil || outranksWhatWeHave {
            administrativeArea = value
        }
        if let value = candidate.country, country == nil || outranksWhatWeHave {
            country = value
        }

        guard locality != nil, administrativeArea != nil else { return }
        if regionResolvedAt == nil { regionResolvedAt = Date() }
        // Placed from the map's own answer, so it is settled: no longer a guess, and nothing
        // for a recheck to confirm later.
        if candidate.locality != nil {
            regionVerifiedAt = Date()
            regionInferredAt = nil
        }
    }

    func distance(from location: CLLocation) -> CLLocationDistance {
        self.location.distance(from: location)
    }

    /// Identity that survives re-discovery: the map provider's own IDs are not stable
    /// across searches, so we key on the name plus a ~11 m coordinate grid.
    static func identity(name: String, coordinate: CLLocationCoordinate2D) -> String {
        let normalized = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lat = (coordinate.latitude * 10_000).rounded() / 10_000
        let lon = (coordinate.longitude * 10_000).rounded() / 10_000
        return "\(normalized)|\(lat)|\(lon)"
    }
}
