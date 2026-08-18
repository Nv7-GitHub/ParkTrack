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
    /// Whether this result looks like a park at all. A search covers everything on the map,
    /// so a coffee shop can be a perfectly good way to navigate — it just is not a park, and
    /// must never be filed as one.
    var isParkLike: Bool = true

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
        /// The span of the individual search that covered this ground, in degrees.
        ///
        /// Coverage is not one quality. A viewport scan sweeps a whole screen in a few wide
        /// requests, and each request answers with at most a couple of dozen results, so wide
        /// ground is thinly seen. An index searches in small tiles precisely so nothing is
        /// missed. Both are "searched", but only the fine one can back a claim about how many
        /// parks a place has — so the resolution travels with the record, and indexing reuses
        /// only ground already searched at least as finely as it would search it itself.
        var resolution: Double = ScannedArea.coarsest
        /// See `ScannedArea.searchGeneration`.
        var generation: Int = 0

        init(_ region: MKCoordinateRegion, resolution: Double = ScannedArea.coarsest, generation: Int = 0) {
            self.resolution = resolution
            self.generation = generation
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

    /// Room for a whole index run and then some.
    ///
    /// This used to be 24, which is ample for browsing — a screen is swept in a handful of
    /// wide squares — and hopeless for indexing, which records one small square per tile and
    /// is allowed `maxIndexSearches` of them. Indexing San Francisco and killing the app
    /// part-way therefore kept 24 tiles out of a few hundred, and reopening started again
    /// from almost nothing.
    ///
    /// The cap is barely approached in practice: a finished index replaces all of its tiles
    /// with the single square it completed, so only an interrupted one holds many at once.
    private static let limit = 512

    private var squares: [Square] = []

    /// The recorded squares as plain bounds, for saving.
    var bounds: [(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double, resolution: Double, generation: Int)] {
        squares.map { ($0.minLatitude, $0.maxLatitude, $0.minLongitude, $0.maxLongitude, $0.resolution, $0.generation) }
    }

    /// Rebuilds coverage from saved bounds.
    mutating func restore(
        _ saved: [(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double, resolution: Double, generation: Int)]
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
            record(region, resolution: entry.resolution, generation: entry.generation)
        }
    }

    mutating func record(_ region: MKCoordinateRegion, resolution: Double? = nil, generation: Int = 0) {
        let square = Square(region, resolution: resolution ?? region.span.latitudeDelta, generation: generation)
        guard square.isUsable else { return }
        // Only swallow ground that was not searched more finely than this. A wide, thin pass
        // must not erase the memory of a careful one underneath it.
        squares.removeAll { square.contains($0) && $0.resolution >= square.resolution && $0.generation <= square.generation }
        squares.append(square)
        // Over the cap the smallest square goes.
        //
        // Preferring to drop the *coarsest* looked right — index tiles are the smallest
        // things here, so dropping by size seemed to throw away exactly the progress a
        // resumed index needs. But the coarse squares are what the completion rings read to
        // say an area has been swept, and there are only ever a handful of them, so
        // targeting them meant indexing one city could quietly un-sweep the ground around
        // the user's home. The size rule protects those, and the cap is now large enough
        // that a single index run — bounded by `maxIndexSearches` — fits underneath it
        // without evicting anything at all.
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

    /// Whether this ground has been searched at least as finely as `resolution` — the test an
    /// exhaustive index applies before deciding it can skip a tile.
    func coversFinely(_ region: MKCoordinateRegion, resolution: Double, generation: Int = 0) -> Bool {
        let square = Square(region)
        guard square.isUsable else { return false }
        return squares.contains {
            $0.contains(square) && $0.resolution <= resolution * 1.05 && $0.generation >= generation
        }
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
    nonisolated static let minimumSweepRadiusMiles = 0.25

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
            ($0.minLatitude, $0.maxLatitude, $0.minLongitude, $0.maxLongitude, $0.resolution, $0.searchGeneration)
        })
    }

    /// Writes the current coverage back, touching only what actually changed.
    ///
    /// An index calls this every few tiles so that killing the app loses at most a handful
    /// of searches. It used to delete every row and reinsert the lot, which was fair enough
    /// when coverage held a couple of dozen squares — but an index in progress holds one per
    /// tile, so a long sweep was rewriting hundreds of rows dozens of times, on the main
    /// actor, while the user watched a progress bar. Nearly all of those rows are identical
    /// from one call to the next.
    ///
    /// A square's bounds and resolution are its identity: `record` never keeps two of the
    /// same, and one that is swallowed is gone rather than altered. So reconciling by key is
    /// exact, and a call that changes nothing writes nothing at all — which also spares
    /// every derived cache in the app a needless invalidation.
    private func persistCoverage() {
        let existing = (try? modelContext.fetch(FetchDescriptor<ScannedArea>())) ?? []

        var stored: [String: ScannedArea] = [:]
        for area in existing {
            let key = Self.coverageKey(
                minLatitude: area.minLatitude,
                maxLatitude: area.maxLatitude,
                minLongitude: area.minLongitude,
                maxLongitude: area.maxLongitude,
                resolution: area.resolution,
                generation: area.searchGeneration
            )
            // A duplicate can only be leftover from an interrupted write; keep one.
            if stored.updateValue(area, forKey: key) != nil {
                modelContext.delete(area)
            }
        }

        var wanted: Set<String> = []
        for entry in coverage.bounds {
            let key = Self.coverageKey(
                minLatitude: entry.minLatitude,
                maxLatitude: entry.maxLatitude,
                minLongitude: entry.minLongitude,
                maxLongitude: entry.maxLongitude,
                resolution: entry.resolution,
                generation: entry.generation
            )
            wanted.insert(key)
            guard stored[key] == nil else { continue }
            modelContext.insert(ScannedArea(
                minLatitude: entry.minLatitude,
                maxLatitude: entry.maxLatitude,
                minLongitude: entry.minLongitude,
                maxLongitude: entry.maxLongitude,
                resolution: entry.resolution,
                searchGeneration: entry.generation
            ))
        }

        for (key, area) in stored where !wanted.contains(key) {
            modelContext.delete(area)
        }

        if modelContext.hasChanges { try? modelContext.save() }
    }

    /// Identity of a swept square. Rounded well below the precision any search works at, so
    /// a value that has been through `Double` arithmetic still matches the row it wrote.
    private nonisolated static func coverageKey(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double,
        resolution: Double,
        generation: Int
    ) -> String {
        func rounded(_ value: Double) -> Int64 { Int64((value * 1e7).rounded()) }
        return "\(rounded(minLatitude)),\(rounded(maxLatitude)),\(rounded(minLongitude)),\(rounded(maxLongitude)),\(rounded(resolution)),\(generation)"
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
    /// A sweep that hits it reports itself as approximate and resumes where it stopped.
    nonisolated static let maxIndexSearches = 320

    /// How many batches in a row may fail outright before a sweep gives up.
    nonisolated static let maxConsecutiveBatchFailures = 6

    /// Which generation of search an index sweep performs today.
    ///
    /// Bump when a change makes previously swept ground no longer equivalent to what a
    /// sweep would find now. Generation 1 is the first that asks both ways — the category
    /// filter and a plain text search — rather than the filter alone.
    nonisolated static let searchGeneration = 1

    /// How many cells a sweep keeps in flight.
    ///
    /// The throttle spaces the *starts* of searches, so it caps the request rate however
    /// many callers there are — running cells one at a time did not make the app politer,
    /// it just left the connection idle through every round trip. Measured on Bellevue, a
    /// sweep spent about 1.5 seconds per search against a 320 ms spacing, which is to say
    /// four fifths of it waiting. Overlapping them fills that gap without asking the map
    /// service for anything faster than it was already getting.
    /// How many cells a sweep works on at once.
    ///
    /// One — because a cell is already two searches, asked together, so this is two requests
    /// in flight and not one. Setting it to three meant six, which is precisely the level
    /// measured to fail: the map service refuses, refused searches come back with no
    /// candidates at all, and a sweep reading no candidates as "not this place" walls itself
    /// in and finishes almost immediately having found nothing. Indexing Boston did exactly
    /// that — sixty areas, zero parks.
    ///
    /// Two in flight still covers the round trip that sequential searching spent idle, which
    /// was most of the win.
    nonisolated static let concurrentCellSearches = 1

    // MARK: - The index lattice

    /// How far a sweep will keep probing past the last cell that belonged to the region.
    ///
    /// A city is not always one connected piece of land at this resolution — a bay, a park
    /// the size of two cells, an island reached by a bridge. Giving up at the first cell
    /// that comes back as somewhere else would cut those off, so a sweep keeps going a
    /// little way and resumes properly if the region turns up again.
    nonisolated static let regionProbeDepth = 2

    /// One cell of a fixed worldwide lattice, at the finest size worth searching.
    ///
    /// Cut from the world rather than from the region, so the same ground always produces
    /// exactly the same cell — on a later run, and for a neighbouring place whose own sweep
    /// overlaps this one. Coverage is matched by containment, so cells that line up are what
    /// make swept ground reusable at all.
    nonisolated static func latticeCell(containing coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let step = minimumTileSpanDegrees
        let latitudeIndex = (coordinate.latitude / step).rounded(.down)
        let longitudeIndex = (coordinate.longitude / step).rounded(.down)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (latitudeIndex + 0.5) * step,
                longitude: (longitudeIndex + 0.5) * step
            ),
            span: MKCoordinateSpan(latitudeDelta: step, longitudeDelta: step)
        )
    }

    /// The eight cells around one, so a sweep can grow outward in any direction.
    nonisolated static func latticeNeighbours(of cell: MKCoordinateRegion) -> [MKCoordinateRegion] {
        let step = minimumTileSpanDegrees
        var neighbours: [MKCoordinateRegion] = []
        for latitudeOffset in -1...1 {
            for longitudeOffset in -1...1 where !(latitudeOffset == 0 && longitudeOffset == 0) {
                let coordinate = CLLocationCoordinate2D(
                    latitude: cell.center.latitude + Double(latitudeOffset) * step,
                    longitude: cell.center.longitude + Double(longitudeOffset) * step
                )
                guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
                neighbours.append(latticeCell(containing: coordinate))
            }
        }
        return neighbours
    }

    /// Stable key for a lattice cell, for the visited set.
    nonisolated static func latticeKey(_ cell: MKCoordinateRegion) -> Int64 {
        let step = minimumTileSpanDegrees
        let latitudeIndex = Int64((cell.center.latitude / step).rounded(.down))
        let longitudeIndex = Int64((cell.center.longitude / step).rounded(.down))
        return latitudeIndex &* 1_000_003 &+ longitudeIndex
    }

    /// Whether any part of a tile lies within `radiusMeters` of a point.
    ///
    /// Compared against the tile's nearest corner rather than its centre, so a tile that
    /// only clips the edge of the region is still searched.
    nonisolated static func tile(
        _ tile: MKCoordinateRegion,
        intersectsCircleAround centre: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) -> Bool {
        let minLatitude = tile.center.latitude - tile.span.latitudeDelta / 2
        let maxLatitude = tile.center.latitude + tile.span.latitudeDelta / 2
        let minLongitude = tile.center.longitude - tile.span.longitudeDelta / 2
        let maxLongitude = tile.center.longitude + tile.span.longitudeDelta / 2

        let nearest = CLLocationCoordinate2D(
            latitude: min(max(centre.latitude, minLatitude), maxLatitude),
            longitude: min(max(centre.longitude, minLongitude), maxLongitude)
        )
        guard CLLocationCoordinate2DIsValid(nearest) else { return false }
        return CLLocation(latitude: nearest.latitude, longitude: nearest.longitude)
            .distance(from: CLLocation(latitude: centre.latitude, longitude: centre.longitude))
            <= radiusMeters
    }

    /// The ground one index covers, derived from nothing but its centre and radius.
    ///
    /// Every tile of a dense sweep is cut out of this, and swept ground is matched by
    /// containment — so two runs over the same region only line up if this square is
    /// identical, to the bit. That is why a region's geometry is settled once and then kept
    /// rather than re-derived from the geocoder on each attempt.
    nonisolated static func indexSquare(
        around coordinate: CLLocationCoordinate2D,
        radiusMiles: Double
    ) -> MKCoordinateRegion {
        let sideMeters = max(radiusMiles, minimumSweepRadiusMiles) * 2 * Format.metersPerMile
        return MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: sideMeters,
            longitudinalMeters: sideMeters
        )
    }

    /// Sweeps a place by following its shape, rather than by covering a box around it.
    ///
    /// There is no public API for a city's boundary — `CLPlacemark` offers a circle and
    /// nothing else — and that circle is drawn around everything the name might refer to.
    /// San Francisco's is 42 km, which takes in Oakland, Marin and a great deal of ocean:
    /// squared off and cut into cells, 1,449 searches for a city of 121 km², against a
    /// budget of 320. It could never finish.
    ///
    /// So the shape is discovered instead of assumed. The sweep starts at the centre and
    /// grows outward one cell at a time, and a cell whose results all belong somewhere else
    /// is a wall it does not expand through. What gets searched is then proportional to the
    /// place itself rather than to the square around it, and the boundary costs one request
    /// per cell along it. The circle survives only as a backstop, so a runaway can never
    /// wander further than the geocoder thought the place extended.
    ///
    /// - Parameter belongsToRegion: Whether a park is actually in the place being indexed.
    ///   Without it the sweep simply fills the circle, which is what a plain area scan wants.
    func sweepDense(
        around coordinate: CLLocationCoordinate2D,
        radiusMiles: Double,
        belongsToRegion: ((Park) -> Bool)? = nil,
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

        let square = Self.indexSquare(around: coordinate, radiusMiles: radiusMiles)
        let radiusMeters = max(radiusMiles, Self.minimumSweepRadiusMiles) * Format.metersPerMile

        var queue: [(cell: MKCoordinateRegion, probe: Int)] = [(Self.latticeCell(containing: coordinate), 0)]
        var visited: Set<Int64> = [Self.latticeKey(queue[0].cell)]
        var found: [String: Park] = [:]
        var order: [String] = []
        var searches = 0
        var reused = 0
        var failures = 0
        var retries: [Int64: Int] = [:]
        var cellsSinceSave = 0
        var completed = true
        var truncated = false

        func report() {
            onProgress?(SweepProgress(
                tilesSearched: searches + reused,
                tilesTotal: searches + reused + queue.count,
                parksFound: order.count
            ))
        }
        report()

        /// Grows into the cells around one that turned out to be part of the place.
        func expand(from cell: MKCoordinateRegion, probe: Int) {
            guard probe <= Self.regionProbeDepth else { return }
            for neighbour in Self.latticeNeighbours(of: cell) {
                let key = Self.latticeKey(neighbour)
                guard !visited.contains(key) else { continue }
                // The circle is the backstop: whatever the results say, a sweep never
                // wanders beyond the extent the place was given.
                guard Self.tile(neighbour, intersectsCircleAround: coordinate, radiusMeters: radiusMeters) else { continue }
                visited.insert(key)
                queue.append((neighbour, probe))
            }
        }

        while !queue.isEmpty {
            if Task.isCancelled { completed = false; break }
            if searches >= Self.maxIndexSearches { truncated = true; break }

            // Ground a previous attempt already searched — including one that was cut short
            // — costs nothing, so it is cleared out of the way before a batch is taken.
            // Whether to keep growing through it is answered from the store rather than by
            // searching it again: the parks it found are already saved, and they know which
            // city they are in.
            var batch: [(cell: MKCoordinateRegion, probe: Int)] = []
            while !queue.isEmpty, batch.count < Self.concurrentCellSearches {
                let entry = queue.removeFirst()
                if coverage.coversFinely(entry.cell, resolution: entry.cell.span.latitudeDelta, generation: Self.searchGeneration) {
                    reused += 1
                    let known = belongsToRegion.map { test in storedParks(in: entry.cell).contains(where: test) } ?? true
                    expand(from: entry.cell, probe: known ? 0 : entry.probe + 1)
                    report()
                    continue
                }
                batch.append(entry)
            }
            guard !batch.isEmpty else { continue }

            let outcomes: [TileOutcome] = await withTaskGroup(of: (Int, TileOutcome).self) { group in
                for (index, entry) in batch.enumerated() {
                    group.addTask { (index, await Self.indexCandidates(in: entry.cell)) }
                }
                var collected = [TileOutcome?](repeating: nil, count: batch.count)
                for await (index, outcome) in group { collected[index] = outcome }
                return collected.map { $0 ?? TileOutcome() }
            }
            searches += batch.count * 2
            if Task.isCancelled { completed = false; break }

            var batchFailures = 0
            for (entry, outcome) in zip(batch, outcomes) {
                let (cell, probe) = entry
                let saved = persist(Self.confined(outcome.candidates, to: cell))
                for park in saved where found[park.identifier] == nil {
                    found[park.identifier] = park
                    order.append(park.identifier)
                }

                // A refusal is not an answer. Recording it as swept, or letting its empty
                // result end the expansion, is how a throttled sweep convinced itself a city
                // had no parks in it.
                if outcome.failure != nil {
                    lastError = outcome.failure
                    batchFailures += 1
                    // Being refused is not the same as having searched. The cell goes back on
                    // the queue so its ground is not quietly dropped from a count that claims
                    // to be exhaustive, and the throttle widens the gap on its own.
                    let key = Self.latticeKey(cell)
                    if retries[key, default: 0] < Self.maxTileRetries {
                        retries[key, default: 0] += 1
                        queue.append((cell, probe))
                    }
                    continue
                }

                // A cell that answered at the result cap is hiding parks behind it. The
                // lattice has no finer step to fall back on — replacing the old splitting
                // quadtree with a flat grid dropped the response to saturation altogether —
                // so the honest thing is to stop calling the total exhaustive. It becomes an
                // "at least this many", which is what `isApproximate` already means.
                if outcome.rawCount >= Self.saturatedResultCount { truncated = true }

                coverage.record(cell, resolution: cell.span.latitudeDelta, generation: Self.searchGeneration)
                cellsSinceSave += 1

                // Only a cell that actually turned up a park in this place resets the probe.
                //
                // Treating an empty cell as neutral instead — on the grounds that a city is
                // allowed to have water in the middle of it — meant expansion never
                // terminated through empty ground at all, and ran to the circle backstop.
                // San Francisco is surrounded by water on three sides and Bellevue sits
                // between two lakes: both spent their whole budget sweeping the sea. A place
                // is still allowed its internal water, because `regionProbeDepth` carries
                // the sweep a couple of cells past nothing before it gives up.
                let belongs = belongsToRegion.map { test in saved.contains(where: test) } ?? true
                expand(from: cell, probe: belongs ? 0 : probe + 1)
            }

            // Only a batch that failed outright counts against giving up. A single refusal
            // among several answers is the throttle doing its job — it has already retried
            // and widened its own spacing — and treating each one as a step towards
            // abandoning the sweep is what made a throttled run quit a fifth of the way in.
            if batchFailures == batch.count {
                failures += 1
                if failures >= Self.maxConsecutiveBatchFailures { completed = false; break }
                try? await Task.sleep(for: .milliseconds(900 * failures))
            } else {
                failures = 0
            }

            if cellsSinceSave >= Self.coverageSaveInterval {
                cellsSinceSave = 0
                persistCoverage()
            }
            report()
        }

        // One text pass over the whole area, for parks the map never categorised. Done once
        // rather than per cell: it used to run alongside every tile, which doubled the cost
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

        // Deliberately not recording the whole square as swept, even on a clean finish. The
        // sweep followed the shape of the place; the corners of the box around it were never
        // searched, and claiming them would let a later sweep of the town next door skip
        // ground nobody has ever looked at. Each cell records itself as it is finished, which
        // is the only claim that is true.
        //
        // Whatever was finished is written down either way. A sweep that stopped early still
        // searched real ground, and losing that is what made a retry repeat everything.
        persistCoverage()
        lastSweepCompleted = completed
        return DenseSweepResult(
            found: order.compactMap { found[$0] },
            completed: completed,
            truncated: truncated
        )
    }

    /// Tiles between writes of the coverage record. Saving after every tile is a store write
    /// per search; this keeps an interrupted sweep's progress without that cost.
    nonisolated static let coverageSaveInterval = 8

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
    func noteScanned(region: MKCoordinateRegion, resolution: Double? = nil) {
        coverage.record(region, resolution: resolution)
        persistCoverage()
    }

    /// Whether this ground has been searched at least as finely as an index would search it.
    func hasSweptFinely(region: MKCoordinateRegion, resolution: Double) -> Bool {
        coverage.coversFinely(region, resolution: resolution)
    }

    /// Whether every part of a completion ring has actually been searched.
    ///
    /// The rings need this to know when a percentage is a fraction of a known total and
    /// when it is still only a floor.
    func hasSwept(around coordinate: CLLocationCoordinate2D, radiusMiles: Double) -> Bool {
        // Largely, not exactly. Demanding one recorded square swallow the ring whole meant
        // walking a hundred metres from where the sweep ran flipped the ring back to
        // uncovered, which read as the app having forgotten.
        isLargelySwept(region: ParkDiscoveryService.boundingSquare(around: coordinate, radiusMiles: radiusMiles))
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
            // Deliberately unfiltered: a landmark is often an easier thing to search for than
            // the park beside it, so the map's whole index is fair game for getting the camera
            // somewhere. What a result *is* travels with it as `isParkLike`, and only the
            // parks are ever added to the catalogue.
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

    /// Parks already saved inside one cell.
    ///
    /// Asked of the store rather than of the map, so a resumed sweep can tell whether ground
    /// it has already covered was part of the place without spending a request to find out
    /// again. Bounded by the cell, so it never materialises the catalogue.
    private func storedParks(in cell: MKCoordinateRegion) -> [Park] {
        let minLatitude = cell.center.latitude - cell.span.latitudeDelta / 2
        let maxLatitude = cell.center.latitude + cell.span.latitudeDelta / 2
        let minLongitude = cell.center.longitude - cell.span.longitudeDelta / 2
        let maxLongitude = cell.center.longitude + cell.span.longitudeDelta / 2
        let descriptor = FetchDescriptor<Park>(
            predicate: #Predicate<Park> {
                $0.latitude >= minLatitude && $0.latitude <= maxLatitude
                    && $0.longitude >= minLongitude && $0.longitude <= maxLongitude
            }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
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
    ///
    /// The fetch asks only about the identifiers in this batch — at most a couple of dozen —
    /// rather than materialising the entire catalogue. A sweep calls this once per level,
    /// and this is the main actor, so pulling every park into memory each time was a stall
    /// the user felt as the map freezing while it scanned.
    ///
    /// Internal so the tests can check what a swept park actually knows about itself.
    @discardableResult
    func persist(_ candidates: [ParkCandidate]) -> [Park] {
        let wanted = Set(candidates.map(\.id))
        let descriptor = FetchDescriptor<Park>(
            predicate: #Predicate<Park> { wanted.contains($0.identifier) }
        )
        var byIdentifier = Dictionary(
            ((try? modelContext.fetch(descriptor)) ?? []).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [Park] = []
        for candidate in candidates {
            if let existing = byIdentifier[candidate.id] {
                if existing.postalAddress == nil { existing.postalAddress = candidate.addressLine }
                if existing.categoryRaw == nil { existing.categoryRaw = candidate.category }
                existing.apply(candidate)
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
            // The search result already said which city this is in, and this is the path
            // every sweep and every index takes. Throwing that away meant a freshly indexed
            // park belonged to no city until the rate-limited geocoder reached it — around
            // one park a second — so an index could report ninety parks found while the city
            // it indexed still read "1 of 2". `park(for:)` had always done this; the bulk
            // path never did.
            park.apply(candidate)
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

    /// Both ways of asking, merged — for a sweep that has to be able to defend its total.
    ///
    /// Neither query contains the other. Measured over thirty-five cells of Bellevue, the
    /// category filter found 37 parks and a plain text search found 38, but between them
    /// they found 41: four the filter missed, three the text missed. A city indexed with one
    /// query alone therefore publishes a total that is quietly about a tenth short, which is
    /// exactly the gap between what an index claimed and what browsing the map had already
    /// turned up.
    ///
    /// It costs two requests per cell instead of one. For a count that calls itself
    /// exhaustive that is the right trade; the map's own browsing scan still runs the cheap
    /// pass and keeps its single wide text query per batch.
    private nonisolated static func indexCandidates(in region: MKCoordinateRegion) async -> TileOutcome {
        // Both at once. They are independent questions and the throttle spaces their starts
        // anyway, so waiting for the first to come back before asking the second only adds a
        // round trip of doing nothing.
        async let filtered = searchOutcome(in: region, poiFiltered: true)
        async let text = searchOutcome(in: region, poiFiltered: false)
        let (a, b) = await (filtered, text)

        var outcome = TileOutcome()
        var seen: Set<String> = []
        for candidate in a.candidates + b.candidates where seen.insert(candidate.id).inserted {
            outcome.candidates.append(candidate)
        }
        // Either query hitting the cap means the cell is still hiding results.
        outcome.rawCount = max(a.rawCount, b.rawCount)
        // Only a genuine failure: one pass refusing while the other answered is not one.
        if outcome.candidates.isEmpty {
            outcome.failure = a.failure ?? b.failure
        }
        return outcome
    }

    private nonisolated static func searchOutcome(
        in region: MKCoordinateRegion,
        poiFiltered: Bool
    ) async -> TileOutcome {
        var outcome = TileOutcome()
        do {
            let (found, raw) = try await searchCounting(
                query: "park",
                region: region,
                poiFiltered: poiFiltered,
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
            isParkLike: isParkLike(name: name, category: item.pointOfInterestCategory),
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
