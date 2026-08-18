import Foundation
import CoreLocation
import SwiftData

/// Fills in the city / county / state fields the stats screens group by.
///
/// `CLGeocoder` is rate-limited far more aggressively than it documents, and going over the
/// limit gets the whole app throttled rather than just failing one lookup. So every request
/// in the app funnels through this one serialized queue with a deliberate gap between calls,
/// and each park is geocoded exactly once (`Park.regionResolvedAt` is the receipt).
///
/// The geocoder returns whatever administrative divisions exist wherever the park is, so
/// this stays correct outside any one country.
@MainActor
final class RegionResolver {
    static let shared = RegionResolver()

    /// Apple throttles around one request per second; 1.2s leaves headroom.
    private static let minimumInterval: TimeInterval = 1.2

    private let geocoder = CLGeocoder()
    private let locationManager = CLLocationManager()
    private var lastRequestAt: Date?
    /// Tail of the serial queue. Every unit of work awaits its predecessor.
    private var queue: Task<Void, Never> = Task {}

    private init() {}

    /// How many parks a recheck would look at, so the screen can say so before starting.
    func reverifiableParkCount(context: ModelContext, within scopes: Set<String>?) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Park>())) ?? []
        return all.count { park in
            // Only what is still to do, so the figure on screen falls as the work is done.
            guard park.locality != nil, park.regionVerifiedAt == nil else { return false }
            guard let scopes else { return true }
            return RegionKind.allCases.contains { kind in
                RegionIndex.identity(kind: kind, park: park).map(scopes.contains) ?? false
            }
        }
    }

    /// Re-checks parks against the geocoder and corrects any that were placed wrongly.
    ///
    /// Inference is the reason this is needed: a park with no placemark of its own borrows
    /// one from its neighbours, and near a boundary with nothing on the far side of it — a
    /// river, a rail yard — every neighbour can agree and every neighbour can be wrong. This
    /// asks the geocoder itself, one park at a time, and reports how many it moved.
    ///
    /// Parks known to have been inferred go first, since they are the ones that can be
    /// wrong; anything else is checked only if the caller asks for more than there are.
    /// - Parameter within: Region identities worth checking, or nil for everywhere. The
    ///   geocoder answers about once a second, so checking a whole catalogue is tens of
    ///   minutes and would run into its limits; the places whose totals actually claim to be
    ///   authoritative are the indexed ones, and there are usually a handful.
    @discardableResult
    func reverifyRegions(
        context: ModelContext,
        limit: Int,
        within scopes: Set<String>? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> Int {
        guard limit > 0 else { return 0 }
        let all = (try? context.fetch(FetchDescriptor<Park>())) ?? []
        let candidates = all
            .filter { $0.locality != nil && $0.regionVerifiedAt == nil }
            .filter { park in
                guard let scopes else { return true }
                return RegionKind.allCases.contains { kind in
                    RegionIndex.identity(kind: kind, park: park).map(scopes.contains) ?? false
                }
            }
            .sorted { lhs, rhs in
                switch (lhs.regionInferredAt, rhs.regionInferredAt) {
                case (.some, .none): return true
                case (.none, .some): return false
                default: return lhs.name < rhs.name
                }
            }
            .prefix(limit)

        var corrected = 0
        var checked = 0
        for park in candidates {
            if Task.isCancelled { break }
            checked += 1
            onProgress?(checked, candidates.count)

            await throttle()
            guard let placemark = try? await geocoder.reverseGeocodeLocation(park.location).first else {
                // Left unverified so a later run tries again; it is a refusal, not an answer.
                continue
            }
            let locality = placemark.locality?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard let locality, !locality.isEmpty else { continue }

            if park.locality != locality {
                park.locality = locality
                park.subAdministrativeArea = placemark.subAdministrativeArea
                park.administrativeArea = placemark.administrativeArea
                park.country = placemark.country
                corrected += 1
            }
            // Checked against the geocoder now, so it is no longer a guess either way — and
            // marked, so the next batch starts where this one stopped rather than here.
            park.regionInferredAt = nil
            park.regionResolvedAt = Date()
            park.regionVerifiedAt = Date()
        }
        if context.hasChanges { try? context.save() }
        return corrected
    }

    /// Resolves up to `limit` unresolved parks, visited ones first and then nearest to the
    /// user, so the screens someone is most likely looking at fill in first.
    func resolveMissingRegions(context: ModelContext, limit: Int) async {
        guard limit > 0 else { return }

        let descriptor = FetchDescriptor<Park>(predicate: #Predicate { $0.regionResolvedAt == nil })
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        let origin = locationManager.location
        let ordered = pending.sorted { lhs, rhs in
            if lhs.isVisited != rhs.isVisited { return lhs.isVisited }
            guard let origin else { return lhs.name < rhs.name }
            return lhs.distance(from: origin) < rhs.distance(from: origin)
        }

        // Neighbours first, and they cost nothing. Parks arrive in clusters from a swept
        // area, most already carry a locality straight off the map result, and a park a few
        // hundred metres from three parks that all agree they're in the same city is in that
        // city. Only what's left over is worth spending the geocoder's rate limit on.
        let placed = (try? context.fetch(
            FetchDescriptor<Park>(predicate: #Predicate { $0.locality != nil })
        )) ?? []
        var stillUnknown: [Park] = []
        for park in ordered {
            if Self.adoptRegion(for: park, from: placed) { continue }
            stillUnknown.append(park)
        }
        if context.hasChanges { try? context.save() }

        for park in stillUnknown.prefix(limit) {
            if Task.isCancelled { return }
            await resolve(park)
        }
    }

    /// How close a placed park has to be to vouch for an unplaced one. About 1.2 km: close
    /// enough to be the same town in any built-up area, and the agreement check below covers
    /// the case where a boundary runs between them.
    static let neighbourRadiusMeters: CLLocationDistance = 1_200

    /// At least one neighbour has to be this close, about 400 m, before their agreement is
    /// worth anything.
    ///
    /// Unanimity alone was meant to catch boundaries — parks either side of a city limit
    /// disagree — but that needs parks on both sides, and a boundary drawn along a river,
    /// a motorway or a rail yard has none. The Commonwealth Avenue Mall sits in Boston about
    /// a kilometre across the Charles from Cambridge: every placed park within 1.2 km of it
    /// was in Cambridge, they agreed unanimously, and it was filed under Cambridge and
    /// counted towards Cambridge's total.
    ///
    /// Something 400 m away is on the same side of whatever separates them. Where nothing is
    /// that close the park simply waits for the geocoder, which is slower and right.
    static let vouchingRadiusMeters: CLLocationDistance = 400

    /// Adopts a region from nearby parks when they agree, and reports whether it did.
    ///
    /// Requires unanimity among the neighbours found: near a city limit the parks on either
    /// side disagree, and guessing there would quietly file a park under the wrong city and
    /// corrupt that city's completion count.
    @discardableResult
    static func adoptRegion(for park: Park, from placed: [Park]) -> Bool {
        let origin = park.location
        let neighbours = placed.filter {
            $0.identifier != park.identifier
                && $0.distance(from: origin) <= neighbourRadiusMeters
        }
        guard !neighbours.isEmpty else { return false }
        // Someone has to actually be nearby, not merely nearest.
        guard neighbours.contains(where: { $0.distance(from: origin) <= vouchingRadiusMeters }) else {
            return false
        }

        let localities = Set(neighbours.compactMap(\.locality))
        guard localities.count == 1, let locality = localities.first else { return false }

        park.locality = locality
        let counties = Set(neighbours.compactMap(\.subAdministrativeArea))
        if counties.count == 1 { park.subAdministrativeArea = counties.first }
        let states = Set(neighbours.compactMap(\.administrativeArea))
        if states.count == 1 { park.administrativeArea = states.first }
        let countries = Set(neighbours.compactMap(\.country))
        if countries.count == 1 { park.country = countries.first }
        park.regionResolvedAt = Date()
        park.regionInferredAt = Date()
        return true
    }

    func resolve(_ park: Park) async {
        guard park.regionResolvedAt == nil else { return }
        await enqueue { [weak self] in
            guard let self else { return }
            guard park.regionResolvedAt == nil else { return }
            await self.throttle()
            await self.performReverseGeocode(park)
        }
    }

    // MARK: - Serialization

    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous.value
            await work()
        }
        queue = task
        await task.value
    }

    private func throttle() async {
        if let lastRequestAt {
            let elapsed = Date().timeIntervalSince(lastRequestAt)
            if elapsed < Self.minimumInterval {
                try? await Task.sleep(for: .seconds(Self.minimumInterval - elapsed))
            }
        }
        lastRequestAt = Date()
    }

    private func performReverseGeocode(_ park: Park) async {
        guard let placemark = try? await geocoder.reverseGeocodeLocation(park.location).first else {
            // Leaving `regionResolvedAt` nil lets a later pass retry; a throttled failure
            // is temporary and shouldn't permanently blank out a park's region.
            return
        }

        park.locality = placemark.locality
        park.subAdministrativeArea = placemark.subAdministrativeArea
        park.administrativeArea = placemark.administrativeArea
        park.country = placemark.country
        park.postalAddress = Self.addressLine(from: placemark) ?? park.postalAddress
        park.regionResolvedAt = Date()
        // Straight from the geocoder, so there is nothing left for a recheck to confirm.
        park.regionVerifiedAt = Date()
        park.regionInferredAt = nil

        if let context = park.modelContext, context.hasChanges {
            try? context.save()
        }
    }

    /// Built by hand rather than via `CNPostalAddressFormatter` so the string stays a simple
    /// one-liner and we avoid pulling in Contacts just for formatting.
    private static func addressLine(from placemark: CLPlacemark) -> String? {
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        let cityState = [placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: ", ")
        let parts = [street, cityState, placemark.postalCode, placemark.country]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
