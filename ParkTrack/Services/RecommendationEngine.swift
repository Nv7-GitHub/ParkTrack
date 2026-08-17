import Foundation
import CoreLocation

/// Why a park was suggested. The raw value is part of `Recommendation.id`, so a park can
/// carry several candidate reasons through scoring and still collapse to one row.
enum RecommendationReason: String {
    case closest
    case finishRadius
    case finishRegion
    case newTerritory
    case wishlist
    case weekendPick
}

/// One suggested next park, already scored and explained.
struct Recommendation: Identifiable {
    var id: String { park.identifier + reason.rawValue }
    let park: Park
    let reason: RecommendationReason
    let score: Double
    let headline: String
    let detail: String
    let distanceMeters: Double?
}

/// Picks what to visit next.
///
/// The engine is pure: everything comes from the parks handed in plus an optional origin,
/// so it works identically anywhere in the world and can be exercised in tests without
/// location services, a map provider, or a store. Each reason produces candidates scored
/// on 0...1, those get multiplied by a reason weight, and a park keeps only its best row —
/// that way a wishlisted park that also finishes a ring surfaces once, at its strongest.
enum RecommendationEngine {

    /// How much each reason is allowed to matter. Wishlist wins by construction: it is the
    /// one signal the user gave us explicitly.
    private enum Weight {
        static let wishlist = 1.0
        static let finishRadius = 0.85
        static let finishRegion = 0.8
        static let closest = 0.7
        static let newTerritory = 0.72
        static let weekendPick = 0.55
    }

    /// No single reason may take more than this share of the list. Without it one reason
    /// crowds out the rest — a user with visits spread thinly saw nothing but "new
    /// territory", because that was the only reason every unvisited park could claim.
    private static let maxShareOfOneReason = 0.4

    /// A set this close to done is treated as a headline finish, and says so.
    private static let nearlyDoneRemaining = 5
    private static let nearlyDoneFraction = 0.5

    static func recommendations(
        parks: [Park],
        origin: CLLocation?,
        home: CLLocationCoordinate2D?,
        radiiMiles: [Double],
        limit: Int
    ) -> [Recommendation] {
        guard limit > 0 else { return [] }

        let visited = parks.filter(\.isVisited)
        let candidates = parks.filter { !$0.isVisited }
        guard !candidates.isEmpty else { return [] }

        let anchor = resolveAnchor(origin: origin, home: home, visited: visited)
        // Rings belong to the user's home, matching the completion screens, and only fall
        // back to the anchor when no home has been set.
        let ringCenter = home.flatMap { coordinate in
            CLLocationCoordinate2DIsValid(coordinate)
                ? CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                : nil
        } ?? anchor
        let radii = radiiMiles.filter { $0 > 0 }.sorted()

        var rows: [Recommendation] = []
        rows += wishlistRows(candidates, anchor: anchor)
        rows += closestRows(candidates, anchor: anchor, limit: limit)
        rows += radiusRows(parks: parks, candidates: candidates, center: ringCenter, anchor: anchor, radiiMiles: radii)
        rows += regionRows(parks: parks, candidates: candidates, anchor: anchor)
        rows += newTerritoryRows(visited: visited, candidates: candidates, anchor: anchor)
        rows += weekendRows(candidates, anchor: anchor, radiiMiles: radii)

        let ranked = rows.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let l = lhs.distanceMeters ?? .greatestFiniteMagnitude
            let r = rhs.distanceMeters ?? .greatestFiniteMagnitude
            if l != r { return l < r }
            return lhs.park.name < rhs.park.name
        }
        return diversified(ranked, limit: limit)
    }

    /// Picks the best rows without letting one reason fill the list, and without showing the
    /// same park twice.
    ///
    /// Order matters here. Collapsing each park to its single best-scoring reason first — the
    /// obvious way to deduplicate — destroys the variety before the cap can protect it: when
    /// most unvisited parks are in untouched places, they all become "new territory" and
    /// there is nothing of another kind left to promote. So the cap is applied across all
    /// rows, and a park is only claimed once it is actually picked.
    ///
    /// The second pass ignores the cap, so a short list is still a full list.
    private static func diversified(_ ranked: [Recommendation], limit: Int) -> [Recommendation] {
        let perReasonCap = max(1, Int((Double(limit) * maxShareOfOneReason).rounded(.up)))
        var counts: [RecommendationReason: Int] = [:]
        var claimed: Set<String> = []
        var picked: [Recommendation] = []

        for row in ranked where picked.count < limit {
            guard !claimed.contains(row.park.identifier) else { continue }
            guard counts[row.reason, default: 0] < perReasonCap else { continue }
            counts[row.reason, default: 0] += 1
            claimed.insert(row.park.identifier)
            picked.append(row)
        }

        for row in ranked where picked.count < limit {
            guard !claimed.contains(row.park.identifier) else { continue }
            claimed.insert(row.park.identifier)
            picked.append(row)
        }

        return picked
    }

    // MARK: - Anchor

    /// Where "near me" is measured from. Live location is best, then the home the user set,
    /// then the middle of everywhere they've already been. With none of those we still
    /// recommend, just without any distance signal.
    private static func resolveAnchor(
        origin: CLLocation?,
        home: CLLocationCoordinate2D?,
        visited: [Park]
    ) -> CLLocation? {
        if let origin { return origin }
        if let home, CLLocationCoordinate2DIsValid(home) {
            return CLLocation(latitude: home.latitude, longitude: home.longitude)
        }
        guard !visited.isEmpty else { return nil }
        let lat = visited.map(\.latitude).reduce(0, +) / Double(visited.count)
        let lon = visited.map(\.longitude).reduce(0, +) / Double(visited.count)
        return CLLocation(latitude: lat, longitude: lon)
    }

    private static func distance(_ park: Park, from anchor: CLLocation?) -> CLLocationDistance? {
        anchor.map { park.distance(from: $0) }
    }

    /// Smooth 1...0 falloff so ranking never depends on an arbitrary distance cutoff.
    private static func proximity(_ meters: CLLocationDistance?) -> Double {
        guard let meters else { return 0.5 }
        let halfLife = 3 * Format.metersPerMile
        return 1 / (1 + max(meters, 0) / halfLife)
    }

    /// Shared "how satisfying is finishing this set" curve: mostly about where the set lands
    /// afterwards, partly about how few stragglers are left.
    private static func completionScore(visited: Int, total: Int, remaining: Int) -> Double? {
        guard total > 0, visited > 0, remaining > 0 else { return nil }
        // Every started set can be finished, so every started set is a candidate — it used to
        // take a hard gate at half done or five left, which meant a user partway through
        // anywhere got no finishing suggestions at all. Progress now moves the score instead
        // of deciding whether the reason exists, so a nearly-done city outranks a barely
        // started one without silencing it.
        let alreadyDone = Double(visited) / Double(total)
        let after = Double(visited + 1) / Double(total)
        return 0.40 * after + 0.25 * (1 / Double(remaining)) + 0.35 * alreadyDone
    }

    /// Whether a set is close enough to done to be worth shouting about in the headline.
    private static func isNearlyDone(visited: Int, total: Int, remaining: Int) -> Bool {
        guard total > 0 else { return false }
        return remaining <= nearlyDoneRemaining || Double(visited) / Double(total) >= nearlyDoneFraction
    }

    // MARK: - Reasons

    private static func wishlistRows(_ candidates: [Park], anchor: CLLocation?) -> [Recommendation] {
        candidates.filter(\.isWishlisted).map { park in
            let meters = distance(park, from: anchor)
            let detail = meters.map { "You saved this one — it's \(Format.distance($0)) away." }
                ?? "You saved this one for later."
            return Recommendation(
                park: park,
                reason: .wishlist,
                score: Weight.wishlist * (0.85 + 0.15 * proximity(meters)),
                headline: "Wishlist",
                detail: detail,
                distanceMeters: meters
            )
        }
    }

    private static func closestRows(
        _ candidates: [Park],
        anchor: CLLocation?,
        limit: Int
    ) -> [Recommendation] {
        guard anchor != nil else { return [] }
        let ranked = candidates
            .compactMap { park -> (Park, CLLocationDistance)? in
                distance(park, from: anchor).map { (park, $0) }
            }
            .sorted { $0.1 < $1.1 }
            .prefix(max(limit * 2, 4))

        return ranked.enumerated().map { index, entry in
            let (park, meters) = entry
            return Recommendation(
                park: park,
                reason: .closest,
                score: Weight.closest * proximity(meters),
                headline: index == 0 ? "Closest" : "Nearby",
                detail: "\(park.name) is \(Format.distance(meters)) away and still unlogged.",
                distanceMeters: meters
            )
        }
    }

    private static func radiusRows(
        parks: [Park],
        candidates: [Park],
        center: CLLocation?,
        anchor: CLLocation?,
        radiiMiles: [Double]
    ) -> [Recommendation] {
        guard let center, !radiiMiles.isEmpty else { return [] }
        var rows: [Recommendation] = []

        for radius in radiiMiles {
            let limitMeters = radius * Format.metersPerMile
            let inside = parks.filter { $0.distance(from: center) <= limitMeters }
            let visitedCount = inside.filter(\.isVisited).count
            let remaining = inside.filter { !$0.isVisited }
            guard let base = completionScore(
                visited: visitedCount,
                total: inside.count,
                remaining: remaining.count
            ) else { continue }

            let after = Double(visitedCount + 1) / Double(inside.count)
            let ids = Set(remaining.map(\.identifier))

            for park in candidates where ids.contains(park.identifier) {
                let meters = distance(park, from: anchor)
                rows.append(Recommendation(
                    park: park,
                    reason: .finishRadius,
                    score: Weight.finishRadius * base,
                    headline: "\(remaining.count) left within \(Format.miles(radius))",
                    detail: "Visiting this would put you at \(Format.percent(after)) within \(Format.miles(radius)).",
                    distanceMeters: meters
                ))
            }
        }
        return rows
    }

    private static func regionRows(
        parks: [Park],
        candidates: [Park],
        anchor: CLLocation?
    ) -> [Recommendation] {
        var grouped: [String: [Park]] = [:]
        for park in parks {
            guard let region = regionName(park) else { continue }
            grouped[region, default: []].append(park)
        }

        var rows: [Recommendation] = []
        for (region, group) in grouped {
            let visitedCount = group.filter(\.isVisited).count
            let remaining = group.filter { !$0.isVisited }
            guard let base = completionScore(
                visited: visitedCount,
                total: group.count,
                remaining: remaining.count
            ) else { continue }

            let after = Double(visitedCount + 1) / Double(group.count)
            let ids = Set(remaining.map(\.identifier))

            for park in candidates where ids.contains(park.identifier) {
                rows.append(Recommendation(
                    park: park,
                    reason: .finishRegion,
                    score: Weight.finishRegion * base,
                    headline: "\(remaining.count) left in \(region)",
                    detail: "Visiting this would put you at \(Format.percent(after)) of \(region).",
                    distanceMeters: distance(park, from: anchor)
                ))
            }
        }
        return rows
    }

    private static func newTerritoryRows(
        visited: [Park],
        candidates: [Park],
        anchor: CLLocation?
    ) -> [Recommendation] {
        let explored = Set(visited.compactMap(regionName))
        return candidates.compactMap { park in
            guard let region = regionName(park), !explored.contains(region) else { return nil }
            let meters = distance(park, from: anchor)
            return Recommendation(
                park: park,
                reason: .newTerritory,
                score: Weight.newTerritory * (0.7 + 0.3 * proximity(meters)),
                headline: "New territory",
                detail: "This would be your first logged park in \(region).",
                distanceMeters: meters
            )
        }
    }

    /// A deliberate day-trip: past the innermost ring but still inside the outermost, and
    /// spread apart so the list doesn't read as three neighbours of the closest pick.
    private static func weekendRows(
        _ candidates: [Park],
        anchor: CLLocation?,
        radiiMiles: [Double]
    ) -> [Recommendation] {
        guard let anchor, let inner = radiiMiles.first, let outer = radiiMiles.last, outer > inner else {
            return []
        }
        let innerMeters = inner * Format.metersPerMile
        let outerMeters = outer * Format.metersPerMile
        let separation = outerMeters * 0.2

        let pool = candidates
            .map { ($0, $0.distance(from: anchor)) }
            .filter { $0.1 > innerMeters && $0.1 <= outerMeters }
            .sorted { $0.1 > $1.1 }

        var picked: [Park] = []
        var rows: [Recommendation] = []
        for (park, meters) in pool {
            guard picked.allSatisfy({ $0.location.distance(from: park.location) >= separation }) else { continue }
            picked.append(park)
            let fraction = meters / outerMeters
            let sweetSpot = max(0, 1 - abs(fraction - 0.6) / 0.6)
            rows.append(Recommendation(
                park: park,
                reason: .weekendPick,
                score: Weight.weekendPick * (0.5 + 0.5 * sweetSpot),
                headline: "Weekend pick",
                detail: "A bigger outing at \(Format.distance(meters)) out, away from your usual loop.",
                distanceMeters: meters
            ))
            if picked.count >= 3 { break }
        }
        return rows
    }

    /// City first, county second — whatever the geocoder managed to resolve for this park.
    private static func regionName(_ park: Park) -> String? {
        for value in [park.locality, park.subAdministrativeArea] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
}
