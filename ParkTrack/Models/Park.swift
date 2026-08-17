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
        if locality == nil { locality = candidate.locality }
        if subAdministrativeArea == nil { subAdministrativeArea = candidate.subAdministrativeArea }
        if administrativeArea == nil { administrativeArea = candidate.administrativeArea }
        if country == nil { country = candidate.country }
        if locality != nil, administrativeArea != nil, regionResolvedAt == nil {
            regionResolvedAt = Date()
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
