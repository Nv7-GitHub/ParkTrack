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
    /// Which generation of the indexer produced this record.
    ///
    /// Totals written by an older, weaker sweep are not comparable with today's, and they are
    /// the denominator behind every percentage and every friend race — so a record from a
    /// previous generation is retired and swept again rather than trusted. Defaults to 0,
    /// which is exactly what records written before this existed decode as.
    var indexerVersion: Int = 0

    /// True when the count is a floor rather than a total.
    ///
    /// Two things cause it and the record cannot tell them apart. The sweep may have run out
    /// of its search budget with ground still to cover, which indexing again gets further
    /// through. Or individual searches may have come back at the map's per-request cap,
    /// which indexing again does nothing about — the same searches return the same results.
    /// So the wording has to be true of both, and must not promise that another pass helps.
    var isApproximate: Bool = false

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
    var isIndexed: Bool { indexedAt != nil && indexerVersion >= RegionIndex.currentIndexerVersion }

    /// Bump when a change makes previously recorded totals untrustworthy. Generation 1 is the
    /// first that always sweeps at region resolution instead of reusing whatever ground a
    /// coarse startup pass had covered, and that refuses to record an empty result.
    ///
    /// Generation 2 asks the map both ways for every cell — the category filter and a plain
    /// text search — rather than the filter alone. Measured over Bellevue, the two together
    /// find about a tenth more parks than either does by itself, so every total recorded
    /// before this is short by roughly that much. Those places show up under "Needs
    /// re-indexing" and read as partial until they have been swept again, because a number
    /// that cannot be defended should not be presented as though it can.
    static let currentIndexerVersion = 2

    /// True for a record written by an older generation, which still names a place worth
    /// indexing but whose count can no longer be believed.
    var needsReindexing: Bool { indexedAt != nil && indexerVersion < RegionIndex.currentIndexerVersion }

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

    /// Whether a park is in a place of this name, judging by name alone.
    ///
    /// The strict key pairs a place with its container — "Sammamish" in "WA" — and that only
    /// works if both sides spell the container the same way. They come from different calls:
    /// the region's from geocoding a name, the park's from a search result's placemark, and
    /// MapKit does not promise those agree. One saying "WA" and the other "Washington" makes
    /// every park in the city fail to belong to it, which reads exactly like a city that is
    /// not there: the sweep hunts for a seed it can never find and floods its whole budget.
    ///
    /// So the container is treated as a tie-breaker rather than a requirement. Two places of
    /// the same name in different states is a real possibility, but a sweep is bounded by
    /// one circle a few tens of miles across, so both being inside it is not.
    static func place(kind: RegionKind, park: Park, isNamed name: String) -> Bool {
        let own: String?
        switch kind {
        case .city: own = park.locality
        case .county: own = park.subAdministrativeArea
        case .state: own = park.administrativeArea
        }
        guard let own, !own.isEmpty else { return false }
        return normalised(own) == normalised(name)
    }

    private static func normalised(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
