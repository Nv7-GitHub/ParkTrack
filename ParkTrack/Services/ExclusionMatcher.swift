import Foundation
import CoreLocation

/// What a friend's rejection corresponds to in the local catalogue.
enum ExclusionMatch: Equatable {
    /// The identifiers agree. Almost always the case, since two people looking at the same
    /// place get the same coordinates from the same map data.
    case exact
    /// No identifier match, but exactly one local park of that name is close enough that it
    /// can only be the same place.
    case nearby(metres: CLLocationDistance)
    /// More than one local park of that name is close enough to be meant. Refusing to guess
    /// is the whole point: see `ExclusionMatcher`.
    case ambiguous(count: Int)
    /// Nothing local corresponds. Still worth adopting — an exclusion also stops the next
    /// sweep filing the place in the first place.
    case undiscovered
}

/// Works out which local park, if any, a friend's rejection is about.
///
/// This cannot simply compare identifiers, and the reason is measured in
/// `ParkIdentityProbe`. `Park.identity` keys on the name plus a coordinate rounded to four
/// decimal places, which is a hard-edged grid roughly 11 m across. Two people who found the
/// same park a metre apart — or one person who added it by hand from a GPS fix — straddle a
/// cell boundary and get different identifiers about 9% of the time. Matching on the
/// identifier alone would therefore silently fail to find the local park for roughly one
/// rejection in eleven.
///
/// So a miss falls back to name plus proximity. The radius is the interesting number:
///
/// - It must comfortably exceed the ~11 m grid drift the identifier suffers from.
/// - It must stay well under the distance that separates two genuinely different parks
///   sharing a name. Boston Common and the other Boston Common are about 150 m apart.
///
/// 60 m sits in that gap. And when more than one candidate falls inside it, this refuses to
/// choose: striking off a park is destructive and irreversible in the same breath, so an
/// ambiguous case is handed to the person who can actually look at the map.
enum ExclusionMatcher {
    /// Chosen to clear coordinate drift by a wide margin while staying far below the
    /// separation of distinct same-name parks. See the type's documentation.
    static let proximityMetres: CLLocationDistance = 60

    static func normalizedName(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The local parks a rejection could plausibly be about, nearest first.
    static func candidates(
        name: String,
        coordinate: CLLocationCoordinate2D,
        among parks: [Park]
    ) -> [(park: Park, metres: CLLocationDistance)] {
        let wanted = normalizedName(name)
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return parks
            .filter { normalizedName($0.name) == wanted }
            .map { (park: $0, metres: $0.location.distance(from: origin)) }
            .filter { $0.metres <= proximityMetres }
            .sorted { $0.metres < $1.metres }
    }

    /// Classifies one rejection against the local catalogue.
    static func match(
        identifier: String,
        name: String,
        coordinate: CLLocationCoordinate2D,
        among parks: [Park]
    ) -> (match: ExclusionMatch, park: Park?) {
        if let exact = parks.first(where: { $0.identifier == identifier }) {
            return (.exact, exact)
        }

        let nearby = candidates(name: name, coordinate: coordinate, among: parks)
        switch nearby.count {
        case 0: return (.undiscovered, nil)
        case 1: return (.nearby(metres: nearby[0].metres), nearby[0].park)
        default: return (.ambiguous(count: nearby.count), nil)
        }
    }

    /// Whether the user has already rejected this place themselves.
    ///
    /// Checked by proximity as well as by identifier, and for the same reason the match is:
    /// an exclusion the user made from their own copy of a park can carry a different
    /// identifier for the same ground. Without this the adoption list would keep offering
    /// back work the user had already done.
    static func isAlreadyExcluded(
        identifier: String,
        name: String,
        coordinate: CLLocationCoordinate2D,
        by excluded: [ExcludedPlace]
    ) -> Bool {
        if excluded.contains(where: { $0.identifier == identifier }) { return true }

        let wanted = normalizedName(name)
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return excluded.contains { place in
            guard normalizedName(place.name) == wanted else { return false }
            let there = CLLocation(latitude: place.latitude, longitude: place.longitude)
            return there.distance(from: origin) <= proximityMetres
        }
    }
}

// MARK: - Building the adoption list

/// One row on the adoption screen.
struct AdoptableExclusion: Identifiable {
    var id: String { identifier }

    let identifier: String
    let name: String
    let latitude: Double
    let longitude: Double
    let match: ExclusionMatch
    /// The local park this would strike off, when there is exactly one.
    let park: Park?
    let visitCount: Int
    let mediaCount: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// True when adopting this would destroy something the user cannot get back.
    var wouldDeleteVisits: Bool { visitCount > 0 }

    /// Ambiguous rows cannot be adopted at all until the person says which park they mean.
    var canBeSelected: Bool {
        if case .ambiguous = match { return false }
        return true
    }

    /// Ticked by default unless adopting it would throw away visits or photos, or unless
    /// it is ambiguous. Everything destructive starts off and has to be chosen deliberately.
    var isSelectedByDefault: Bool { canBeSelected && !wouldDeleteVisits }

    /// What the row says it would cost, or nil when it costs nothing.
    var costDescription: String? {
        guard wouldDeleteVisits else { return nil }
        var parts = ["\(visitCount) \(visitCount == 1 ? "visit" : "visits")"]
        if mediaCount > 0 {
            parts.append("\(mediaCount) \(mediaCount == 1 ? "photo or video" : "photos and videos")")
        }
        return parts.formatted(.list(type: .and)) + " would be deleted"
    }

    var matchDescription: String {
        switch match {
        case .exact: "In your parks"
        case .nearby(let metres): "In your parks, \(Int(metres.rounded())) m away"
        case .ambiguous(let count): "\(count) of your parks share this name — open it to choose"
        case .undiscovered: "Not in your parks yet — stops it being added"
        }
    }
}

extension AdoptableExclusion {
    /// Builds the list a friend's profile shows.
    ///
    /// Anything the user has already struck off is dropped rather than shown as done: the
    /// screen exists to save work, and a list mostly full of rows that do nothing is worse
    /// than a short one.
    static func list(
        from exclusions: [FriendExclusion],
        parks: [Park],
        alreadyExcluded: [ExcludedPlace]
    ) -> [AdoptableExclusion] {
        exclusions.compactMap { exclusion -> AdoptableExclusion? in
            guard !ExclusionMatcher.isAlreadyExcluded(
                identifier: exclusion.identifier,
                name: exclusion.name,
                coordinate: exclusion.coordinate,
                by: alreadyExcluded
            ) else { return nil }

            let (match, park) = ExclusionMatcher.match(
                identifier: exclusion.identifier,
                name: exclusion.name,
                coordinate: exclusion.coordinate,
                among: parks
            )

            return AdoptableExclusion(
                identifier: exclusion.identifier,
                name: exclusion.name,
                latitude: exclusion.latitude,
                longitude: exclusion.longitude,
                match: match,
                park: park,
                visitCount: park?.visitCount ?? 0,
                mediaCount: (park?.visits ?? []).reduce(0) { $0 + ($1.media?.count ?? 0) }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Fair denominators

/// One rejected place, stripped of whose it is.
struct ExclusionPoint {
    let identifier: String
    let name: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(identifier: String, name: String, latitude: Double, longitude: Double) {
        self.identifier = identifier
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ place: ExcludedPlace) {
        self.init(identifier: place.identifier, name: place.name, latitude: place.latitude, longitude: place.longitude)
    }

    init(_ exclusion: FriendExclusion) {
        self.init(identifier: exclusion.identifier, name: exclusion.name, latitude: exclusion.latitude, longitude: exclusion.longitude)
    }
}

/// Makes two people's completion percentages describe the same thing.
///
/// A region's total is the number of parks an exhaustive sweep found there. Striking a
/// place off removes it from the local catalogue, so two people who have rejected different
/// places are counting against different totals — and neither of them is told. The fix is
/// to agree on the denominator rather than on the catalogue: both sides count against the
/// raw total minus every place *either* of them rejects.
///
/// The union is deliberate rather than the intersection. If either person has looked at a
/// place and decided it is a car park, counting it would make the race turn on who had
/// bothered to clean their data.
enum RegionFairness {
    /// Combines two rejection lists, treating near-identical entries as one.
    ///
    /// Deduplicated by the same identifier-or-proximity rule the adoption screen matches
    /// on: two people rejecting the same place can hold different identifiers for it, and
    /// counting that twice would shrink the denominator below the truth.
    static func union(_ mine: [ExclusionPoint], _ theirs: [ExclusionPoint]) -> [ExclusionPoint] {
        var combined = mine
        for point in theirs {
            let isDuplicate = combined.contains { existing in
                if existing.identifier == point.identifier { return true }
                guard ExclusionMatcher.normalizedName(existing.name)
                        == ExclusionMatcher.normalizedName(point.name) else { return false }
                let a = CLLocation(latitude: existing.latitude, longitude: existing.longitude)
                let b = CLLocation(latitude: point.latitude, longitude: point.longitude)
                return a.distance(from: b) <= ExclusionMatcher.proximityMetres
            }
            if !isDuplicate { combined.append(point) }
        }
        return combined
    }

    /// How many of these fall inside a region.
    ///
    /// Attributed by distance from the region's centre, because a rejection carries a
    /// coordinate but no locality — the park it referred to was deleted, taking its region
    /// fields with it.
    static func count(_ points: [ExclusionPoint], inside region: RegionIndex) -> Int {
        let centre = CLLocation(latitude: region.centerLatitude, longitude: region.centerLongitude)
        return points.count { point in
            CLLocation(latitude: point.latitude, longitude: point.longitude)
                .distance(from: centre) <= region.radiusMeters
        }
    }

    /// The total a region had before anyone struck anything off.
    ///
    /// `RegionIndex.parkCount` is already net of the user's own rejections, since discovery
    /// skips an excluded place before it is ever saved. Adding them back recovers the figure
    /// both sides can start from.
    static func rawTotal(for region: RegionIndex, localCount: Int, myExclusions: [ExclusionPoint]) -> Int {
        max(region.parkCount, localCount) + count(myExclusions, inside: region)
    }

    /// The denominator both sides should count against.
    static func fairTotal(rawTotal: Int, region: RegionIndex, union: [ExclusionPoint]) -> Int {
        max(0, rawTotal - count(union, inside: region))
    }
}
