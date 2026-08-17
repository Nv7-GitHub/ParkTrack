import Foundation
import CoreLocation
import MapKit
import SwiftData

/// Which administrative level a region index covers.
enum RegionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case city, county, state

    var id: String { rawValue }

    var title: String {
        switch self {
        case .city: return "City"
        case .county: return "County"
        case .state: return "State"
        }
    }
}

/// A place the app has searched exhaustively, and the number of parks it found there.
///
/// This is what makes a completion percentage mean something. Without it the denominator is
/// however much ground the user happened to pan across, so "1 park left in Redmond" changed
/// the moment they widened their search radius. An index is swept once against the region
/// the geocoder defines for that place, then kept forever — the point is never to re-index.
///
/// It is also the shared denominator that makes competing with a friend fair: both people
/// are counting against the same total for the same place.
@Model
final class RegionIndex {
    /// Stable key: kind, name and container, normalised. Nothing here is region-specific —
    /// it is built from whatever the geocoder returned for wherever the user is.
    var identifier: String = ""
    var kindRaw: String = RegionKind.city.rawValue
    var name: String = ""
    /// The larger place this sits in — a state for a city or county — used to tell apart the
    /// many places in the world that share a name.
    var container: String?
    var country: String?

    var centerLatitude: Double = 0
    var centerLongitude: Double = 0
    /// Radius of the area actually swept, from the geocoder's own region for the place.
    var radiusMeters: Double = 0

    /// Nil until a sweep has finished. A half-swept region must not present a percentage.
    var indexedAt: Date?
    /// Parks found inside this region by the completed sweep.
    var parkCount: Int = 0
    /// Set while a sweep is running so the UI can show progress and refuse to start twice.
    var isIndexing: Bool = false
    var lastError: String?

    init(
        identifier: String,
        kind: RegionKind,
        name: String,
        container: String?,
        country: String?,
        center: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) {
        self.identifier = identifier
        self.kindRaw = kind.rawValue
        self.name = name
        self.container = container
        self.country = country
        self.centerLatitude = center.latitude
        self.centerLongitude = center.longitude
        self.radiusMeters = radiusMeters
    }
}

extension RegionIndex {
    var kind: RegionKind { RegionKind(rawValue: kindRaw) ?? .city }
    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }
    var radiusMiles: Double { radiusMeters / Format.metersPerMile }
    var isIndexed: Bool { indexedAt != nil }

    /// "Redmond, WA" style label, falling back to whatever detail exists.
    var displayName: String {
        guard let container, !container.isEmpty else { return name }
        return "\(name), \(container)"
    }

    static func identity(kind: RegionKind, name: String, container: String?) -> String {
        let normalise = { (value: String) -> String in
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(kind.rawValue)|\(normalise(name))|\(normalise(container ?? ""))"
    }

    /// The key a park would have for this kind of region, so parks can be matched to an
    /// index without another geocode.
    static func identity(kind: RegionKind, park: Park) -> String? {
        let name: String?
        switch kind {
        case .city: name = park.locality
        case .county: name = park.subAdministrativeArea
        case .state: name = park.administrativeArea
        }
        guard let name, !name.isEmpty else { return nil }
        let container = kind == .state ? park.country : park.administrativeArea
        return identity(kind: kind, name: name, container: container)
    }
}
