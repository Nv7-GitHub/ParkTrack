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
    var addressLine: String?

    /// Straight off the map result's placemark. Search already knows what city a result is
    /// in, so taking it here means most parks never need the rate-limited reverse geocoder
    /// — which is what makes indexing a whole city in one pass practical.
    var locality: String?
    var subAdministrativeArea: String?
    var administrativeArea: String?
    var country: String?

    static func == (lhs: ParkCandidate, rhs: ParkCandidate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The ground discovery has actually asked the map about.
///
/// A completion percentage is only honest once the area it measures has been searched:
/// before that the denominator is whatever happens to be cached, not what is out there. The
/// sweep records every square it finishes here, and the rings ask before presenting their
/// numbers as final.
///
/// A newly recorded square swallows every square it contains, so the list stays a handful of
/// entries even after the user has moved around all day.
struct SweptCoverage {
    private struct Square {
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double

        init(_ region: MKCoordinateRegion) {
            minLatitude = region.center.latitude - region.span.latitudeDelta / 2
            maxLatitude = region.center.latitude + region.span.latitudeDelta / 2
            minLongitude = region.center.longitude - region.span.longitudeDelta / 2
            maxLongitude = region.center.longitude + region.span.longitudeDelta / 2
        }

        var isUsable: Bool {
            minLatitude.isFinite && maxLatitude.isFinite && minLongitude.isFinite && maxLongitude.isFinite
                && maxLatitude > minLatitude && maxLongitude > minLongitude
        }

        func contains(_ other: Square) -> Bool {
            other.minLatitude >= minLatitude - SweptCoverage.slack
                && other.maxLatitude <= maxLatitude + SweptCoverage.slack
                && other.minLongitude >= minLongitude - SweptCoverage.slack
                && other.maxLongitude <= maxLongitude + SweptCoverage.slack
        }

        var area: Double { (maxLatitude - minLatitude) * (maxLongitude - minLongitude) }
    }

    /// Squares are rebuilt from metres every time they are compared, and that round trip
    /// through degrees is not bit-exact.
    private static let slack = 1e-9
    private static let limit = 24

    private var squares: [Square] = []

    /// The recorded squares as plain bounds, for saving.
    var bounds: [(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)] {
        squares.map { ($0.minLatitude, $0.maxLatitude, $0.minLongitude, $0.maxLongitude) }
    }

    /// Rebuilds coverage from saved bounds.
    mutating func restore(
        _ saved: [(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)]
    ) {
        for entry in saved {
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (entry.minLatitude + entry.maxLatitude) / 2,
                    longitude: (entry.minLongitude + entry.maxLongitude) / 2
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: entry.maxLatitude - entry.minLatitude,
                    longitudeDelta: entry.maxLongitude - entry.minLongitude
                )
            )
            record(region)
        }
    }

    mutating func record(_ region: MKCoordinateRegion) {
        let square = Square(region)
        guard square.isUsable else { return }
        squares.removeAll { square.contains($0) }
        squares.append(square)
        // Over the cap the smallest square goes, not the oldest: the widest square is the one
        // backing the most rings and the most expensive to search again, and it is usually
        // also the oldest — around wherever the user opened the app.
        if squares.count > Self.limit,
           let smallest = squares.indices.min(by: { squares[$0].area < squares[$1].area }) {
            squares.remove(at: smallest)
        }
    }

    /// Whether one point sits on ground already searched.
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return false }
        return squares.contains { square in
            coordinate.latitude >= square.minLatitude - SweptCoverage.slack
                && coordinate.latitude <= square.maxLatitude + SweptCoverage.slack
                && coordinate.longitude >= square.minLongitude - SweptCoverage.slack
                && coordinate.longitude <= square.maxLongitude + SweptCoverage.slack
        }
    }

    func covers(_ region: MKCoordinateRegion) -> Bool {
        let square = Square(region)
        guard square.isUsable else { return false }
        return squares.contains { $0.contains(square) }
    }

    /// Whether the ring of `radiusMiles` around `center` sits entirely on swept ground.
    func covers(center: CLLocationCoordinate2D, radiusMiles: Double) -> Bool {
        covers(ParkDiscoveryService.boundingSquare(around: center, radiusMiles: radiusMiles))
    }

    static func region(_ outer: MKCoordinateRegion, covers inner: MKCoordinateRegion) -> Bool {
        Square(outer).contains(Square(inner))
    }

    /// Whether a single result landed on the ground that was actually searched.
    static func region(_ outer: MKCoordinateRegion, contains coordinate: CLLocationCoordinate2D) -> Bool {
        let square = Square(outer)
        guard square.isUsable, CLLocationCoordinate2DIsValid(coordinate) else { return false }
        return coordinate.latitude >= square.minLatitude - Self.slack
            && coordinate.latitude <= square.maxLatitude + Self.slack
            && coordinate.longitude >= square.minLongitude - Self.slack
            && coordinate.longitude <= square.maxLongitude + Self.slack
    }
}

/// One widening step of a sweep: the square it completes, and only the tiles that step still
/// has to ask about.
struct SweepLevel {
    let square: MKCoordinateRegion
    let tiles: [MKCoordinateRegion]
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
/// Those caps are also why an area is covered by a progressive `sweep` rather than one wide
/// scan: a single request over a ten-mile radius returns roughly what a request over a
/// two-mile radius does, which is how completion rings ended up quoting the same total for
/// two different radii. The sweep records what it finished in `coverage` so the rings can
/// tell a searched area from an assumed one.
///
/// Nothing here is region-specific: every result comes from whatever region the caller asks
/// about, and the only baked-in knowledge is generic English park vocabulary.
@Observable
@MainActor
final class ParkDiscoveryService {
    private let modelContext: ModelContext

    private(set) var isSearching = false
    private(set) var lastError: String?
    /// False when the last sweep was cut short — cancelled, or abandoned after too many
    /// failed levels. A caller that records "this ground is searched" must check it.
    private(set) var lastSweepCompleted = false

    /// Which ground a sweep has finished. Rings read this to tell a real denominator from
    /// a provisional one.
    private(set) var coverage = SweptCoverage()

    /// One sweep at a time: a second request over the same ground would only duplicate the
    /// requests the first is already making.
    private var isSweeping = false

    /// Tiles beyond this are more requests than any one scan should cost the user.
    /// Every search is serialized by `SearchThrottle`, so this is a time budget as much
    /// as a request budget.
    nonisolated static let maxTilesPerScan = 9
    /// Roughly 6 km, small enough that the per-request result cap rarely truncates a tile.
    private nonisolated static let targetTileSpanDegrees = 0.06
    /// The same 6 km expressed in metres: a sweep works in metres so its squares are the
    /// same shape as the rings it is asked to cover.
    private nonisolated static let targetTileMeters: CLLocationDistance = 6_600
    /// Each level is a 3x3 grid over the last one, so a level triples the extent covered
    /// and costs eight requests.
    private nonisolated static let sweepGridSide = 3
    /// Five levels reach hundreds of miles; the cap is what stops a silly custom radius
    /// from turning into an unbounded plan.
    nonisolated static let maxSweepLevels = 5
    /// Stop once this many levels in a row come back with nothing but failures, so a dead
    /// network ends the sweep instead of grinding through the rest of the plan.
    private nonisolated static let maxFailedLevels = 2
    private nonisolated static let minimumSweepRadiusMiles = 0.25

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
        loadCoverage()
    }

    /// Restores everywhere previous sessions searched, so a relaunch doesn't start blind.
    private func loadCoverage() {
        let saved = (try? modelContext.fetch(FetchDescriptor<ScannedArea>())) ?? []
        coverage.restore(saved.map {
            ($0.minLatitude, $0.maxLatitude, $0.minLongitude, $0.maxLongitude)
        })
    }

    /// Writes the current coverage back. The list is capped at a couple of dozen squares that
    /// swallow each other, so replacing it wholesale is cheaper than reconciling it.
    private func persistCoverage() {
        let existing = (try? modelContext.fetch(FetchDescriptor<ScannedArea>())) ?? []
        for area in existing { modelContext.delete(area) }
        for entry in coverage.bounds {
            modelContext.insert(ScannedArea(
                minLatitude: entry.minLatitude,
                maxLatitude: entry.maxLatitude,
                minLongitude: entry.minLongitude,
                maxLongitude: entry.maxLongitude
            ))
        }
        try? modelContext.save()
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

    /// An explicit "search here now" pass: the same sweep, but it re-asks about ground it
    /// has already covered because the caller asked for it on the user's behalf.
    @discardableResult
    func discoverParks(around coordinate: CLLocationCoordinate2D, radiusMiles: Double) async -> [Park] {
        await sweep(around: coordinate, radiusMiles: radiusMiles, force: true)
    }

    /// Sweeps outward from `coordinate` until the whole of `radiusMiles` has been searched.
    ///
    /// Progressive on purpose. The innermost square is a single request, so the rings and
    /// the nearby lists fill in almost immediately, and each further level triples the
    /// extent for eight more requests; parks are saved level by level rather than at the
    /// end. Levels whose square is already in `coverage` are skipped, which is what makes
    /// pull-to-refresh over ground we have swept cost nothing.
    ///
    /// Cancellation is honoured between requests, so a sweep dies with the view that
    /// started it.
    @discardableResult
    func sweep(around coordinate: CLLocationCoordinate2D, radiusMiles: Double, force: Bool = false) async -> [Park] {
        guard !isSweeping else { return [] }
        isSweeping = true
        isSearching = true
        lastError = nil
        defer {
            isSweeping = false
            isSearching = false
        }

        var found: [String: Park] = [:]
        var order: [String] = []
        var failedLevels = 0
        var completed = true
        defer { lastSweepCompleted = completed }

        for level in Self.sweepLevels(around: coordinate, radiusMiles: radiusMiles) {
            if Task.isCancelled { completed = false; break }
            if !force && coverage.covers(level.square) { continue }

            let outcome = await Self.candidates(inTiles: level.tiles, wideOver: level.square)
            if Task.isCancelled { completed = false; break }

            if !outcome.candidates.isEmpty {
                for park in persist(outcome.candidates) where found[park.identifier] == nil {
                    found[park.identifier] = park
                    order.append(park.identifier)
                }
            }

            // Ground we could not search is not ground we have swept: leaving it unrecorded
            // keeps the ring honest and lets a later refresh retry it.
            if let failure = outcome.failure {
                lastError = failure
                failedLevels += 1
                if failedLevels >= Self.maxFailedLevels { completed = false; break }
                continue
            }
            failedLevels = 0
            coverage.record(level.square)
            persistCoverage()
        }

        return order.compactMap { found[$0] }
    }

    /// How a uniform-density sweep is getting on, for the UI to show while it runs.
    struct SweepProgress {
        let tilesSearched: Int
        let tilesTotal: Int
        let parksFound: Int

        var fraction: Double {
            tilesTotal > 0 ? Double(tilesSearched) / Double(tilesTotal) : 0
        }
    }

    /// What a uniform-density sweep managed to do.
    struct DenseSweepResult {
        let found: [Park]
        /// False when the sweep was cancelled or gave up after repeated failures.
        let completed: Bool
        /// True when the area needed more tiles than the budget allows, so the result is a
        /// floor rather than a full count.
        let truncated: Bool
    }

    /// Where an adaptive sweep starts. Big enough that empty country costs one request,
    /// small enough that a town is not one saturated tile from the outset.
    nonisolated static let coarseTileMeters: CLLocationDistance = 26_000

    /// Results at or above this count mean the map ran out of room to answer, so the tile is
    /// split. `MKLocalSearch` tops out around 25.
    nonisolated static let saturatedResultCount = 20

    /// Refinement stops here. Below roughly 1.5 km a tile is smaller than the parks in it.
    nonisolated static let minimumTileSpanDegrees = 0.014

    /// Hard ceiling on one region's searches, so a pathological area cannot run forever.
    nonisolated static let maxIndexSearches = 320

    /// How many tiles in a row may fail before a dense sweep gives up.
    nonisolated static let maxConsecutiveTileFailures = 12

    /// Sweeps an area at even density, for indexing.
    ///
    /// The ordinary sweep grows in concentric levels that trible in size, so its outer tiles
    /// end up tens of kilometres across — and a single search answers with at most a couple
    /// of dozen results, so a wide tile silently sees a fraction of what is in it. That is
    /// fine for filling a map as the user pans, and wrong for a count that claims to be the
    /// number of parks in a place. Here every tile is the same small size, whatever the
    /// extent, and the caller is told when the area was too big to cover at that density.
    @discardableResult
    func sweepDense(
        around coordinate: CLLocationCoordinate2D,
        radiusMiles: Double,
        onProgress: ((SweepProgress) -> Void)? = nil
    ) async -> DenseSweepResult {
        // Wait for whatever is already searching rather than failing. Bailing out here is how
        // tapping "Index Redmond" while the launch sweep was still running reported itself as
        // interrupted, and how a second tap reported that it simply could not index at all.
        await waitForSweepToFinish()
        isSweeping = true
        isSearching = true
        lastError = nil
        defer {
            isSweeping = false
            isSearching = false
        }

        let sideMeters = max(radiusMiles, Self.minimumSweepRadiusMiles) * 2 * Format.metersPerMile
        let square = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: sideMeters,
            longitudinalMeters: sideMeters
        )

        // Adaptive rather than uniform. A fixed grid fine enough for a city centre costs
        // hundreds of requests across a county, nearly all of them spent confirming that
        // farmland is still empty. Instead every tile starts coarse and is split into four
        // only when its answer comes back at the map's per-request cap, which is the one
        // signal that a tile is hiding parks. Dense ground gets the fine grid it needs and
        // empty ground is dismissed in a single request.
        var queue: [MKCoordinateRegion] = Self.tiles(
            for: square,
            side: max(1, Int((sideMeters / Self.coarseTileMeters).rounded(.up)))
        )
        var found: [String: Park] = [:]
        var order: [String] = []
        var searches = 0
        var failures = 0
        var retries: [String: Int] = [:]
        var completed = true
        var truncated = false

        func report() {
            onProgress?(SweepProgress(
                tilesSearched: searches,
                tilesTotal: searches + queue.count,
                parksFound: order.count
            ))
        }
        report()

        while !queue.isEmpty {
            if Task.isCancelled { completed = false; break }
            if searches >= Self.maxIndexSearches { truncated = true; break }

            let tile = queue.removeFirst()
            let outcome = await Self.candidates(in: tile)
            searches += 1
            if Task.isCancelled { completed = false; break }

            for park in persist(Self.confined(outcome.candidates, to: tile)) where found[park.identifier] == nil {
                found[park.identifier] = park
                order.append(park.identifier)
            }

            if outcome.failure != nil {
                lastError = outcome.failure
                failures += 1
                if failures >= Self.maxConsecutiveTileFailures { completed = false; break }
                // Being refused is not the same as having searched. The tile goes back on the
                // queue so its ground is not quietly dropped from a count that claims to be
                // exhaustive, and the throttle widens the gap on its own.
                if retries[Self.key(for: tile), default: 0] < Self.maxTileRetries {
                    retries[Self.key(for: tile), default: 0] += 1
                    queue.append(tile)
                }
                try? await Task.sleep(for: .milliseconds(900 * failures))
            } else {
                failures = 0
                if outcome.rawCount >= Self.saturatedResultCount,
                   tile.span.latitudeDelta > Self.minimumTileSpanDegrees {
                    queue.append(contentsOf: Self.tiles(for: tile, side: 2))
                }
            }

            report()
        }

        // One text pass over the whole area, for parks the map never categorised. Done once
        // rather than per tile: it used to run alongside every tile, which doubled the cost
        // of a sweep to no benefit, since an uncategorised park is found just as well by a
        // wide query as a narrow one.
        if completed, !Task.isCancelled {
            if let wide = try? await Self.search(query: "park", region: square, poiFiltered: false, requireParkLike: true) {
                for park in persist(Self.confined(wide, to: square)) where found[park.identifier] == nil {
                    found[park.identifier] = park
                    order.append(park.identifier)
                }
            }
            report()
        }

        if completed && !truncated {
            coverage.record(square)
            persistCoverage()
        }
        lastSweepCompleted = completed
        return DenseSweepResult(
            found: order.compactMap { found[$0] },
            completed: completed,
            truncated: truncated
        )
    }

    /// How many times one tile may be re-queued after the map service refuses it.
    nonisolated static let maxTileRetries = 3

    private nonisolated static func key(for region: MKCoordinateRegion) -> String {
        "\(region.center.latitude),\(region.center.longitude),\(region.span.latitudeDelta)"
    }

    /// Drops results that landed outside the tile actually searched. `MKLocalSearch` treats a
    /// region as a hint, so a query can answer with somewhere else entirely.
    private nonisolated static func confined(
        _ candidates: [ParkCandidate],
        to region: MKCoordinateRegion
    ) -> [ParkCandidate] {
        deduped(candidates.filter { SweptCoverage.region(region, contains: $0.coordinate) })
    }

    /// Yields until no sweep is in flight. Everything here is main-actor bound, so this is a
    /// cooperative wait rather than a lock.
    private func waitForSweepToFinish() async {
        while isSweeping {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Whether this exact region has already been searched.
    func hasSwept(region: MKCoordinateRegion) -> Bool {
        coverage.covers(region)
    }

    /// Whether enough of `region` has been searched that scanning it again would mostly
    /// repeat requests. Checks the corners and centre rather than demanding one recorded
    /// square swallow the whole thing, so ground covered by two adjacent passes counts.
    func isLargelySwept(region: MKCoordinateRegion) -> Bool {
        if coverage.covers(region) { return true }
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2
        let probes = [
            region.center,
            CLLocationCoordinate2D(latitude: region.center.latitude - halfLat, longitude: region.center.longitude - halfLon),
            CLLocationCoordinate2D(latitude: region.center.latitude - halfLat, longitude: region.center.longitude + halfLon),
            CLLocationCoordinate2D(latitude: region.center.latitude + halfLat, longitude: region.center.longitude - halfLon),
            CLLocationCoordinate2D(latitude: region.center.latitude + halfLat, longitude: region.center.longitude + halfLon)
        ]
        return probes.allSatisfy { coverage.contains($0) }
    }

    /// Records ground a viewport scan covered, so panning back over it is free. Without this
    /// the map's scans and the indexer's sweeps kept separate memories and re-searched each
    /// other's ground.
    func noteScanned(region: MKCoordinateRegion) {
        coverage.record(region)
        persistCoverage()
    }

    /// Whether every part of a completion ring has actually been searched.
    ///
    /// The rings need this to know when a percentage is a fraction of a known total and
    /// when it is still only a floor.
    func hasSwept(around coordinate: CLLocationCoordinate2D, radiusMiles: Double) -> Bool {
        coverage.covers(center: coordinate, radiusMiles: radiusMiles)
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
        park.apply(candidate)
        modelContext.insert(park)
        // Only the results the map left unplaced still need the slow geocoder.
        if park.regionResolvedAt == nil {
            scheduleRegionResolution(for: park)
        }
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

        let radiusMiles = max(meters / Format.metersPerMile, 0.5)
        _ = await sweep(around: coordinate, radiusMiles: radiusMiles)
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
        /// Raw results the map returned, before filtering. A tile that comes back at the
        /// per-request cap is hiding parks it did not have room to mention, which is the
        /// signal to look at that tile more closely.
        var rawCount: Int = 0
    }

    /// Scans `region` tile by tile, for callers that hand us one region rather than a plan.
    private nonisolated static func candidates(coveringTilesOf region: MKCoordinateRegion) async -> TileOutcome {
        var merged = await candidates(inTiles: tiles(for: region, maxTiles: maxTilesPerScan), wideOver: region)
        // A tile that failed while others succeeded isn't worth bothering the user about.
        if !merged.candidates.isEmpty { merged.failure = nil }
        return merged
    }

    /// One batch of tiles plus one text pass over the ground they cover.
    ///
    /// Searches run one at a time through `SearchThrottle`: MapKit throttles bursts, and a
    /// throttled scan used to come back empty. Each tile uses the precise POI filter, and the
    /// single wide text pass catches parks Apple never categorised — which costs one extra
    /// request instead of doubling the batch.
    ///
    /// The reported failure is deliberately coarse: it survives only when most of the batch
    /// failed, because that is the case where the caller must not treat the ground as
    /// searched.
    private nonisolated static func candidates(
        inTiles tiles: [MKCoordinateRegion],
        wideOver region: MKCoordinateRegion
    ) async -> TileOutcome {
        var merged = TileOutcome()
        var attempted = 0
        var failed = 0

        for tile in tiles {
            if Task.isCancelled { return merged }
            attempted += 1
            let outcome = await candidates(in: tile)
            merged.candidates.append(contentsOf: outcome.candidates)
            if let failure = outcome.failure {
                failed += 1
                if merged.failure == nil { merged.failure = failure }
            }
        }

        if !Task.isCancelled {
            attempted += 1
            do {
                let wide = try await search(query: "park", region: region, poiFiltered: false, requireParkLike: true)
                merged.candidates.append(contentsOf: wide)
            } catch {
                failed += 1
                if merged.failure == nil { merged.failure = message(for: error) }
            }
        }

        // A region is a hint to `MKLocalSearch`, not a bound, and the wide text pass over a
        // large square answers just as happily with parks in the next state. Ground we did
        // not search is ground we cannot claim, so results off the square are dropped rather
        // than saved — otherwise a swept ten-mile ring sits in a catalogue full of parks
        // hundreds of miles away.
        merged.candidates = deduped(merged.candidates.filter {
            SweptCoverage.region(region, contains: $0.coordinate)
        })
        if failed * 2 <= attempted { merged.failure = nil }
        return merged
    }

    /// One tile, POI-filtered. The uncategorised sweep happens once for the whole region.
    private nonisolated static func candidates(in region: MKCoordinateRegion) async -> TileOutcome {
        var outcome = TileOutcome()
        do {
            let (found, raw) = try await searchCounting(
                query: "park",
                region: region,
                poiFiltered: true,
                requireParkLike: true
            )
            outcome.candidates = found
            outcome.rawCount = raw
        } catch {
            outcome.failure = message(for: error)
        }
        return outcome
    }

    /// As `search`, but also reports how many results came back before filtering.
    private nonisolated static func searchCounting(
        query: String,
        region: MKCoordinateRegion?,
        poiFiltered: Bool,
        requireParkLike: Bool
    ) async throws -> ([ParkCandidate], Int) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        if poiFiltered {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .nationalPark])
        }
        if let region { request.region = region }

        let response = try await SearchThrottle.shared.run(request)
        let mapped = response.mapItems.compactMap { candidate(from: $0, requireParkLike: requireParkLike) }
        return (mapped, response.mapItems.count)
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

        let response = try await SearchThrottle.shared.run(request)
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
            addressLine: item.placemark.title,
            locality: item.placemark.locality,
            subAdministrativeArea: item.placemark.subAdministrativeArea,
            administrativeArea: item.placemark.administrativeArea,
            country: item.placemark.country
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

    /// The square a completion ring of `radiusMiles` occupies.
    ///
    /// Sweep levels and coverage queries both go through here so a finished level and the
    /// ring it was meant to cover are built from the same numbers rather than two
    /// almost-equal approximations.
    nonisolated static func boundingSquare(around center: CLLocationCoordinate2D, radiusMiles: Double) -> MKCoordinateRegion {
        let side = max(radiusMiles, minimumSweepRadiusMiles) * 2 * Format.metersPerMile
        return MKCoordinateRegion(center: center, latitudinalMeters: side, longitudinalMeters: side)
    }

    /// Plans a sweep as a series of widening squares, innermost first.
    ///
    /// Each level is a 3x3 grid over a square three times the extent of the last, so the
    /// middle tile is ground the previous level already covered and gets dropped: every
    /// level after the first costs exactly eight requests, and the widest ring a user can
    /// ask for still plans in tens of requests rather than hundreds. Tiles stay fine where
    /// the small rings are and coarsen further out, which is the only way to cover tens of
    /// miles under that budget.
    nonisolated static func sweepLevels(around center: CLLocationCoordinate2D, radiusMiles: Double) -> [SweepLevel] {
        guard CLLocationCoordinate2DIsValid(center), radiusMiles.isFinite else { return [] }
        let requested = max(radiusMiles, minimumSweepRadiusMiles) * 2 * Format.metersPerMile

        var levels: [SweepLevel] = []
        var previous: MKCoordinateRegion?
        var side = min(targetTileMeters, requested)

        while levels.count < maxSweepLevels {
            let square = MKCoordinateRegion(center: center, latitudinalMeters: side, longitudinalMeters: side)
            let grid = tiles(for: square, side: previous == nil ? 1 : sweepGridSide)
            let fresh = previous.map { inner in grid.filter { !SweptCoverage.region(inner, covers: $0) } } ?? grid
            levels.append(SweepLevel(square: square, tiles: fresh))

            if side >= requested { break }
            previous = square
            side = min(side * Double(sweepGridSide), requested)
        }
        return levels
    }

    /// Splits a region into an NxN grid sized so each tile is small enough that the
    /// per-request result cap rarely bites, without ever exceeding `maxTiles` requests.
    nonisolated static func tiles(for region: MKCoordinateRegion, maxTiles: Int = maxTilesPerScan) -> [MKCoordinateRegion] {
        tiles(for: region, side: gridSide(for: region.span, maxTiles: maxTiles))
    }

    nonisolated static func tiles(for region: MKCoordinateRegion, side: Int) -> [MKCoordinateRegion] {
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
