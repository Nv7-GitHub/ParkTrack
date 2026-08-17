import Foundation
import CoreLocation
import MapKit
import Observation
import SwiftData

/// A park the map returned that has not (necessarily) been saved yet.
///
/// Search UI needs to show results before anything is written to the store, so discovery
/// hands back this value type and only materialises a `Park` when the user commits.
struct ParkCandidate: Identifiable, Hashable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let category: String?
    let addressLine: String?

    static func == (lhs: ParkCandidate, rhs: ParkCandidate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Finds parks anywhere in the world via MapKit and caches them as `Park` records.
///
/// Two constraints shape the whole design. `MKLocalSearch` caps each response at roughly
/// 10-25 results regardless of how large the region is, so a single request over a metro
/// area silently returns a fraction of what's there; we compensate by tiling the region and
/// by running both a category-filtered and a plain-text pass, then merging. And the map's
/// own result identifiers are not stable between searches, so dedup keys on
/// `Park.identity(name:coordinate:)` instead.
///
/// Nothing here is region-specific: every result comes from whatever region the caller asks
/// about, and the only baked-in knowledge is generic English park vocabulary.
@Observable
@MainActor
final class ParkDiscoveryService {
    private let modelContext: ModelContext

    private(set) var isSearching = false
    private(set) var lastError: String?

    /// Above this many concurrent `MKLocalSearch` calls Apple starts throttling us.
    private nonisolated static let maxConcurrentSearches = 4
    /// Tiles beyond this are more requests than any one scan should cost the user.
    nonisolated static let maxTilesPerScan = 16
    /// Roughly 6 km, small enough that the per-request result cap rarely truncates a tile.
    private nonisolated static let targetTileSpanDegrees = 0.06

    private nonisolated static let parkLikeCategories: Set<MKPointOfInterestCategory> = [.park, .nationalPark]

    /// Generic vocabulary, not a place list: these are the words that make an uncategorised
    /// map result plausibly a park in the first place.
    private nonisolated static let parkLikeWords: Set<String> = [
        "park", "parks", "green", "greens", "commons", "preserve", "preserves",
        "trail", "trails", "garden", "gardens", "playfield", "playfields",
        "arboretum", "arboretums", "woods", "meadow", "meadows"
    ]

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Discovery

    @discardableResult
    func discoverParks(in region: MKCoordinateRegion) async -> [Park] {
        isSearching = true
        lastError = nil
        defer { isSearching = false }

        let outcome = await Self.candidates(coveringTilesOf: region)
        if let failure = outcome.failure { lastError = failure }
        guard !outcome.candidates.isEmpty else { return [] }
        return persist(outcome.candidates)
    }

    @discardableResult
    func discoverParks(around coordinate: CLLocationCoordinate2D, radiusMiles: Double) async -> [Park] {
        let meters = max(radiusMiles, 0.25) * 1609.344 * 2
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: meters,
            longitudinalMeters: meters
        )
        return await discoverParks(in: region)
    }

    func searchParks(named query: String, near coordinate: CLLocationCoordinate2D?) async -> [ParkCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        isSearching = true
        lastError = nil
        defer { isSearching = false }

        let region = coordinate.map {
            MKCoordinateRegion(center: $0, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        do {
            return try await Self.search(query: trimmed, region: region, poiFiltered: false, requireParkLike: false)
        } catch {
            lastError = Self.message(for: error)
            return []
        }
    }

    // MARK: - Materialising parks

    @discardableResult
    func park(for candidate: ParkCandidate) -> Park {
        if let existing = existingPark(identifier: candidate.id) { return existing }
        let park = Park(
            identifier: candidate.id,
            name: candidate.name,
            latitude: candidate.coordinate.latitude,
            longitude: candidate.coordinate.longitude,
            categoryRaw: candidate.category
        )
        park.postalAddress = candidate.addressLine
        modelContext.insert(park)
        scheduleRegionResolution(for: park)
        return park
    }

    @discardableResult
    func park(named name: String, at coordinate: CLLocationCoordinate2D) -> Park {
        let identifier = Park.identity(name: name, coordinate: coordinate)
        if let existing = existingPark(identifier: identifier) { return existing }
        let park = Park(
            identifier: identifier,
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        modelContext.insert(park)
        scheduleRegionResolution(for: park)
        return park
    }

    /// Nearest cached park first: logging a visit shouldn't wait on the network when we
    /// already know what's underfoot.
    func nearestPark(to coordinate: CLLocationCoordinate2D, within meters: CLLocationDistance) async -> Park? {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let cached = nearestCachedPark(to: origin, within: meters) { return cached }

        let radiusMiles = max(meters / 1609.344, 0.5)
        _ = await discoverParks(around: coordinate, radiusMiles: radiusMiles)
        return nearestCachedPark(to: origin, within: meters)
    }

    // MARK: - Store access

    private func allParks() -> [Park] {
        (try? modelContext.fetch(FetchDescriptor<Park>())) ?? []
    }

    private func existingPark(identifier: String) -> Park? {
        var descriptor = FetchDescriptor<Park>(predicate: #Predicate { $0.identifier == identifier })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func nearestCachedPark(to origin: CLLocation, within meters: CLLocationDistance) -> Park? {
        allParks()
            .map { ($0, $0.distance(from: origin)) }
            .filter { $0.1 <= meters }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Insert everything new in one pass, keyed against a single fetch so re-scanning an
    /// area never produces a second copy of a park.
    private func persist(_ candidates: [ParkCandidate]) -> [Park] {
        var byIdentifier = Dictionary(
            allParks().map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [Park] = []
        for candidate in candidates {
            if let existing = byIdentifier[candidate.id] {
                if existing.postalAddress == nil { existing.postalAddress = candidate.addressLine }
                if existing.categoryRaw == nil { existing.categoryRaw = candidate.category }
                result.append(existing)
                continue
            }
            let park = Park(
                identifier: candidate.id,
                name: candidate.name,
                latitude: candidate.coordinate.latitude,
                longitude: candidate.coordinate.longitude,
                categoryRaw: candidate.category
            )
            park.postalAddress = candidate.addressLine
            modelContext.insert(park)
            byIdentifier[candidate.id] = park
            result.append(park)
        }

        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                lastError = "Couldn't save the parks we found. \(error.localizedDescription)"
            }
        }
        return result
    }

    private func scheduleRegionResolution(for park: Park) {
        Task { await RegionResolver.shared.resolve(park) }
    }

    // MARK: - Map search

    /// A tile pass never throws: a failed tile just contributes nothing, and the first
    /// human-readable failure rides along so the UI can say something happened.
    private struct TileOutcome {
        var candidates: [ParkCandidate] = []
        var failure: String?
    }

    /// Runs every tile of `region`, at most `maxConcurrentSearches` at a time, and merges.
    private nonisolated static func candidates(coveringTilesOf region: MKCoordinateRegion) async -> TileOutcome {
        let tiles = tiles(for: region, maxTiles: maxTilesPerScan)

        var merged = TileOutcome()
        await withTaskGroup(of: TileOutcome.self) { group in
            var next = 0
            while next < tiles.count && next < maxConcurrentSearches {
                let tile = tiles[next]
                group.addTask { await candidates(in: tile) }
                next += 1
            }
            while let batch = await group.next() {
                merged.candidates.append(contentsOf: batch.candidates)
                if merged.failure == nil { merged.failure = batch.failure }
                if next < tiles.count {
                    let tile = tiles[next]
                    group.addTask { await candidates(in: tile) }
                    next += 1
                }
            }
        }
        merged.candidates = deduped(merged.candidates)
        // A tile that failed while others succeeded isn't worth bothering the user about.
        if !merged.candidates.isEmpty { merged.failure = nil }
        return merged
    }

    /// One tile, two passes: the POI filter is precise but sparse, the plain text query
    /// catches parks Apple never categorised. Merged, they cover far more ground.
    private nonisolated static func candidates(in region: MKCoordinateRegion) async -> TileOutcome {
        var outcome = TileOutcome()
        for poiFiltered in [true, false] {
            do {
                let found = try await search(
                    query: "park",
                    region: region,
                    poiFiltered: poiFiltered,
                    requireParkLike: true
                )
                outcome.candidates.append(contentsOf: found)
            } catch {
                if outcome.failure == nil { outcome.failure = message(for: error) }
            }
        }
        return outcome
    }

    private nonisolated static func search(
        query: String,
        region: MKCoordinateRegion?,
        poiFiltered: Bool,
        requireParkLike: Bool
    ) async throws -> [ParkCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        if poiFiltered {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .nationalPark])
        }
        if let region { request.region = region }

        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item in
            candidate(from: item, requireParkLike: requireParkLike)
        }
    }

    private nonisolated static func candidate(from item: MKMapItem, requireParkLike: Bool) -> ParkCandidate? {
        guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let coordinate = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        if requireParkLike && !isParkLike(name: name, category: item.pointOfInterestCategory) { return nil }

        return ParkCandidate(
            id: Park.identity(name: name, coordinate: coordinate),
            name: name,
            coordinate: coordinate,
            category: item.pointOfInterestCategory?.rawValue,
            addressLine: item.placemark.title
        )
    }

    // MARK: - Pure helpers

    /// A categorised result has to be categorised as a park; an uncategorised one has to at
    /// least be *named* like one, which is what keeps restaurants and parking garages out.
    nonisolated static func isParkLike(name: String, category: MKPointOfInterestCategory?) -> Bool {
        if let category { return parkLikeCategories.contains(category) }
        return hasParkLikeName(name)
    }

    /// Whole-word matching on purpose: "Parking Garage" must not read as a park.
    nonisolated static func hasParkLikeName(_ name: String) -> Bool {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let words = folded.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { parkLikeWords.contains($0) }
    }

    /// Splits a region into an NxN grid sized so each tile is small enough that the
    /// per-request result cap rarely bites, without ever exceeding `maxTiles` requests.
    nonisolated static func tiles(for region: MKCoordinateRegion, maxTiles: Int = maxTilesPerScan) -> [MKCoordinateRegion] {
        let side = gridSide(for: region.span, maxTiles: maxTiles)
        guard side > 1 else { return [region] }

        let latStep = region.span.latitudeDelta / Double(side)
        let lonStep = region.span.longitudeDelta / Double(side)
        let originLat = region.center.latitude - region.span.latitudeDelta / 2
        let originLon = region.center.longitude - region.span.longitudeDelta / 2
        let span = MKCoordinateSpan(latitudeDelta: latStep, longitudeDelta: lonStep)

        return (0..<side).flatMap { row in
            (0..<side).map { column in
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: originLat + latStep * (Double(row) + 0.5),
                        longitude: originLon + lonStep * (Double(column) + 0.5)
                    ),
                    span: span
                )
            }
        }
    }

    nonisolated static func gridSide(for span: MKCoordinateSpan, maxTiles: Int) -> Int {
        let cap = max(1, Int(Double(max(maxTiles, 1)).squareRoot().rounded(.down)))
        let widest = max(span.latitudeDelta, span.longitudeDelta)
        guard widest.isFinite, widest > 0 else { return 1 }
        let needed = Int((widest / targetTileSpanDegrees).rounded(.up))
        return min(max(needed, 1), cap)
    }

    nonisolated static func deduped(_ candidates: [ParkCandidate]) -> [ParkCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    private nonisolated static func message(for error: Error) -> String {
        if let mkError = error as? MKError {
            switch mkError.code {
            case .placemarkNotFound, .unknown: return "No parks came back for that search."
            case .serverFailure, .loadingThrottled: return "The map service is busy. Try again in a moment."
            default: break
            }
        }
        return error.localizedDescription
    }
}
