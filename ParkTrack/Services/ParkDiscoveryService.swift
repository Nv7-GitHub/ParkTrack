import Foundation
import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftData

/// Everything a sweep does, so a run that goes wrong can be read back afterwards rather
/// than guessed at. Visible in Console.app, and in Xcode's debug console, under the
/// subsystem below.
let sweepLog = Logger(subsystem: "com.nv7.parktrack", category: "sweep")

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
    /// wide squares — and hopeless for indexing, which records one small square per cell and
    /// is allowed `maxIndexSearches` of them. Indexing San Francisco and killing the app
    /// part-way therefore kept 24 tiles out of a few hundred, and reopening started again
    /// from almost nothing.
    ///
    /// Tied to the index budget rather than written down separately, because the two have to
    /// agree: a cap below it silently evicts cells a finished run just recorded — the
    /// smallest squares are exactly the index's own — and a resumed sweep re-searches ground
    /// it had already paid for.
    private static let limit = ParkDiscoveryService.maxIndexSearches + 64

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

    /// Whether a record is from a superseded index generation, and so can never be reused.
    ///
    /// A generation is stamped by one thing only: an index sweep recording a cell it has
    /// just searched. Everything else — a map pan, a completion ring, ground restored from
    /// a build that predates generations — records generation zero, and is left alone here
    /// whatever size it is, because a small square is not by itself evidence of an index.
    ///
    /// A stamped record from an earlier generation is dead weight: `coversFinely` will never
    /// accept it again, since the method that produced it has been replaced. That would be
    /// harmless if it only took up space, but index cells are also the *smallest* squares
    /// here and the cap evicts the smallest. Three cities indexed by the old sweep leave
    /// about 350 of them, and a fresh 700-cell run measured losing 286 of its own — so the
    /// run finished, wrote down less than half the ground it had searched, and the next one
    /// paid for that ground all over again.
    private static func isSuperseded(_ square: Square) -> Bool {
        square.generation > 0 && square.generation < ParkDiscoveryService.searchGeneration
    }

    mutating func record(_ region: MKCoordinateRegion, resolution: Double? = nil, generation: Int = 0) {
        let square = Square(region, resolution: resolution ?? region.span.latitudeDelta, generation: generation)
        guard square.isUsable else { return }
        // Restoring reads every square the store kept, including the dead ones; this is where
        // they stop coming back. The next `persistCoverage` then deletes their rows.
        guard !Self.isSuperseded(square) else { return }
        // Only swallow ground that was not searched more finely than this. A wide, thin pass
        // must not erase the memory of a careful one underneath it.
        squares.removeAll {
            Self.isSuperseded($0)
                || (square.contains($0) && $0.resolution >= square.resolution && $0.generation <= square.generation)
        }
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

    /// What the map may call something for it to count as a park.
    ///
    /// `playground` is not declared by the SDK, but the service returns it — Meydenbauer
    /// Park in Bellevue carries it — and a filter built from the raw value works: over one
    /// patch of downtown Bellevue, asking for parks alone returned three results and asking
    /// for parks and playgrounds returned five, the extra two being Inspiration Playground
    /// and Kids' Cove. Those are areas *inside* a park rather than parks in their own right,
    /// which is a fair thing to collect separately.
    /// What the map may call something for it to count as a park.
    ///
    /// Just parks. `playground` was tried and taken out again, and the reason is worth
    /// keeping: the category is not about playgrounds. Apple files public play areas, mall
    /// play areas and commercial children's businesses under it alike, and indexing
    /// collected Blaze Robotics Academy, Pop Smart Academy and Twinkle Land Play Cafe as
    /// parks. Nothing in the data separates them — Inspiration Playground and Twinkle Land
    /// Play Cafe both carry a street number, a street, a phone number and a URL, and the
    /// most park-like of the lot, Kids' Cove, is at 250 Bellevue Square, inside a shopping
    /// centre. A list of business words in the name was tried next and leaked twice.
    ///
    /// Little is lost. A playground inside a park is already counted as that park, which is
    /// separately categorised: Meydenbauer Bay Park is `.park` and stays, while the
    /// "Meydenbauer Park" playground within it was the duplicate.
    private nonisolated static let parkLikeCategories: Set<MKPointOfInterestCategory> = [.park, .nationalPark]

    /// Undeclared by the SDK, but the service returns it — so a saved park may carry it, and
    /// the tidy-up sheet has to recognise it to offer those for removal.
    nonisolated static let playgroundCategory = MKPointOfInterestCategory(rawValue: "MKPOICategoryPlayground")

    /// Words that make an uncategorised map result plausibly a park.
    ///
    /// Generic vocabulary, not a place list — and deliberately missing the most obvious
    /// word of all. "Park" is what people name *buildings* after: every false positive that
    /// prompted this used it and nothing else — Parkside Esterra Park, Capella at Esterra
    /// Park, Park Bellevue, Park 88, all blocks of flats named for the park across the road,
    /// all uncategorised. So are "green", "commons", "meadow" and "woods", which name
    /// housing developments at least as often as they name open ground.
    ///
    /// What is left is vocabulary nobody puts on an apartment building. South Mercer
    /// Playfields is uncategorised and is plainly a park; so is Bellevue Botanical Garden.
    /// Keeping those costs nothing the tidy-up sheet cannot undo, where admitting anything
    /// called "Park" cost a catalogue full of flats.
    private nonisolated static let parkLikeWords: Set<String> = [
        "preserve", "preserves", "trail", "trails", "garden", "gardens",
        "playfield", "playfields", "arboretum", "arboretums", "greenway", "greenways"
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

    /// What a scan of one region did.
    struct ScanOutcome {
        let parks: [Park]
        /// The ground actually asked about, which is wider than the caller's region when the
        /// caller's was too small for the map to answer about. Whoever records coverage has
        /// to record this rather than what they asked for.
        let region: MKCoordinateRegion
        /// Whether this ground may be written down as searched. False when the map answered
        /// about somewhere else, which is not the same as answering that there is nothing here.
        let coveredGround: Bool
    }

    /// Widens a region to the smallest one a text search will actually answer about.
    ///
    /// Below roughly 0.05° the map discards the region and answers from the device's own
    /// surroundings, and the results are then dropped for being outside the region — so a
    /// scan of a zoomed-in view away from home found nothing, every time, and then recorded
    /// the ground as searched so it would never try again. Asking about a little more ground
    /// than the screen is showing is the difference between an answer and no answer.
    nonisolated static func scannableRegion(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        guard region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite else { return region }
        return MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(
                latitudeDelta: max(region.span.latitudeDelta, wideTileSpanDegrees),
                longitudeDelta: max(region.span.longitudeDelta, wideTileSpanDegrees)
            )
        )
    }

    @discardableResult
    func discoverParks(in region: MKCoordinateRegion) async -> ScanOutcome {
        isSearching = true
        lastError = nil
        defer { isSearching = false }

        let asked = Self.scannableRegion(region)
        let outcome = await Self.candidates(coveringTilesOf: asked)
        if let failure = outcome.failure { lastError = failure }
        let claimable = !outcome.answeredAboutSomewhereElse && outcome.failure == nil
        guard !outcome.candidates.isEmpty else {
            return ScanOutcome(parks: [], region: asked, coveredGround: claimable)
        }
        return ScanOutcome(parks: persist(outcome.candidates), region: asked, coveredGround: claimable)
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
        /// True when the count is a floor rather than a total: the budget ran out, or
        /// searches came back at the map's per-request cap. See `RegionIndex.isApproximate`.
        let truncated: Bool
    }

    /// Where an adaptive sweep starts. Big enough that empty country costs one request,
    /// small enough that a town is not one saturated tile from the outset.
    nonisolated static let coarseTileMeters: CLLocationDistance = 26_000

    /// This many parks *inside* one cell means the answer may have been cut off rather than
    /// finished, so the total is a floor. See `TileOutcome.rawCount`, which is what is
    /// compared against it — results in the cell, not results in the response.
    ///
    /// A cell is about a kilometre across. Twenty parks inside one is a botanical garden
    /// district, not a suburb, so in practice this fires where it should and nowhere else.
    nonisolated static let saturatedResultCount = 20

    /// Refinement stops here. Below roughly 1.5 km a tile is smaller than the parks in it.
    nonisolated static let minimumTileSpanDegrees = 0.014

    /// Hard ceiling on one region's searches — one per cell — so a pathological area cannot
    /// run forever. A sweep that hits it reports itself as approximate and resumes where it
    /// stopped.
    ///
    /// It has to be large enough that half of it, which is all the hunt for the place is
    /// allowed, still spans a city's own radius: the geocoder's centre is not reliably inside
    /// the place, and a hunt that cannot cross the circle gives up on a city that is really
    /// there. At about 0.8 km² a cell, a 5.5-mile city is roughly 300 cells of circle, so
    /// half of this covers it with room over. Cells are half the size they were and cost one
    /// request each instead of two, so this is not more traffic than the 320 it replaces —
    /// it is the same ground, counted honestly.
    nonisolated static let maxIndexSearches = 700

    /// How many batches in a row may fail outright before a sweep gives up.
    nonisolated static let maxConsecutiveBatchFailures = 6

    /// Which generation of search an index sweep performs today.
    ///
    /// Bump when a change makes previously swept ground no longer equivalent to what a
    /// sweep would find now. Generation 1 is the first that asks both ways — the category
    /// filter and a plain text search — rather than the filter alone. Generation 2 asks the
    /// bounded points-of-interest request instead of either, which is the first generation
    /// whose answers are actually about the cell it asked about; every earlier record claims
    /// ground the map never looked at, so none of it may be reused.
    nonisolated static let searchGeneration = 3

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

    /// How far a sweep keeps going past the last cell that belonged to the region, in metres.
    ///
    /// A city is not one continuous run of parks. A residential plateau can have two
    /// kilometres of houses between one park and the next, and the sweep has to be able to
    /// cross that — as well as a bay, a park the size of several cells, an island reached by
    /// a bridge — or the far side of a city is simply never reached.
    ///
    /// A distance, not a number of cells, because the number of cells is not the thing being
    /// judged. When the lattice was cut finer to fit inside what the map will answer about,
    /// a fixed depth of one cell silently became a shorter reach, and Sammamish indexed its
    /// southern half and walled itself off from its northern one.
    nonisolated static let regionProbeMeters: CLLocationDistance = 3_000

    /// `regionProbeMeters` in cells, at a given latitude.
    ///
    /// Measured against the narrow side of a cell — longitude, away from the equator — so
    /// the reach holds in the direction it is shortest rather than only on average.
    nonisolated static func regionProbeDepth(atLatitude latitude: Double) -> Int {
        let cellWidth = indexCellSpanDegrees * metersPerDegreeLatitude
            * max(cos(latitude * .pi / 180), 0.05)
        return max(2, Int((regionProbeMeters / cellWidth).rounded(.up)))
    }

    /// What a cell of somewhere else costs against that reach, against 1 for a cell that
    /// answered with nothing.
    ///
    /// The two are not the same evidence. Nothing here means only that: a lake, a golf
    /// course, four streets of housing — a city is allowed all of those in the middle of it.
    /// Parks that belong to the next town along is a boundary, and one the sweep should stop
    /// at quickly, or indexing a city pays for a skirt right round it. Half the reach means
    /// two such cells end the expansion however small the cells have become.
    nonisolated static func probeCost(forSomewhereElseAtLatitude latitude: Double) -> Int {
        max(1, regionProbeDepth(atLatitude: latitude) / 2)
    }

    /// The area of one lattice cell at a given latitude, in square kilometres.
    ///
    /// Cells are not square. A degree of longitude is shorter than a degree of latitude
    /// everywhere but the equator, so treating one as square overstates its area by a third
    /// at Seattle's latitude — and anything counted in cells is undercounted by as much.
    nonisolated static func cellAreaSquareKilometres(atLatitude latitude: Double) -> Double {
        let heightKm = indexCellSpanDegrees * metersPerDegreeLatitude / 1_000
        let widthKm = heightKm * cos(latitude * .pi / 180)
        return max(heightKm * widthKm, 0.0001)
    }

    /// Searches a sweep may spend looking for the place before deciding it cannot find it.
    ///
    /// Expanding at full depth until the first match is what lets a city whose centre is
    /// water still be found. But cells queued during that phase keep the depth they were
    /// queued at, so once the place *is* found and walls start forming, every one of them is
    /// still searched — the hunt for the seed poisons the queue behind it.
    ///
    /// The hunt spreads outward from the centre, so reaching something *d* away costs a whole
    /// disc of radius *d*, and the centre is not reliably inside the place: there is a city
    /// called Sammamish next to a lake called Sammamish, and geocoding the name can land in
    /// the water kilometres from any park in the city. So the allowance is the area it might
    /// have to cross rather than a constant — capped at half the run, so a hunt that really
    /// is going nowhere still leaves something for the sweep it was meant to start.
    nonisolated static func seedingBudget(radiusMiles: Double, latitude: Double) -> Int {
        let discKm = radiusMiles * 1.609
        let discCells = Double.pi * discKm * discKm / cellAreaSquareKilometres(atLatitude: latitude)
        // Rounded up: the allowance is meant to cover the disc, and flooring it leaves the
        // hunt a cell short of the edge it was sized to reach.
        return min(maxIndexSearches / 2, max(48, Int(discCells.rounded(.up))))
    }

    /// One cell of a fixed worldwide lattice, at the finest size worth searching.
    ///
    /// Cut from the world rather than from the region, so the same ground always produces
    /// exactly the same cell — on a later run, and for a neighbouring place whose own sweep
    /// overlaps this one. Coverage is matched by containment, so cells that line up are what
    /// make swept ground reusable at all.
    /// The size of one index cell, about a kilometre.
    ///
    /// Set by the reach of the request that asks about it. `MKLocalPointsOfInterestRequest`
    /// answers about a kilometre out however large a radius it is given — measured, a 3 km
    /// and a 20 km request over downtown Bellevue returned the same fourteen parks, none
    /// beyond 1.0 km. Ground outside that reach is not searched however confidently the cell
    /// claims it, so a cell has to fit inside it, corners included.
    ///
    /// A degree of longitude is longest at the equator, and that is the case this has to
    /// hold for: 0.010° there is 1.11 km square, whose half-diagonal is 0.79 km. At
    /// Seattle's latitude the same cell is 1.11 km by 0.75 km, a half-diagonal of 0.67 km.
    /// Both sit inside the reach with room to spare, which is the point — a cell whose
    /// corners are out of reach is ground the sweep records as searched and never saw.
    ///
    /// Cells this size are also cheaper than the 1.5 km ones they replace, despite there
    /// being about twice as many, because each now costs one request instead of two and
    /// because the ground they cover is ground that was genuinely asked about.
    nonisolated static let indexCellSpanDegrees = 0.010

    /// The smallest region a natural-language search will actually answer about.
    ///
    /// Measured over one spot in Sammamish, varying nothing but the span: at 0.010°, 0.014°
    /// and 0.03° not one of twenty-five results was inside the region, and at 0.06° eight
    /// were. Somewhere near 0.05° the map stops honouring the region and starts answering
    /// from wherever the device is. Anything asking a text query about less ground than this
    /// is not asking about that ground at all.
    nonisolated static let wideTileSpanDegrees = 0.06

    /// A ceiling on the text pass, so indexing a county does not turn it into a second sweep.
    nonisolated static let maxWideTiles = 16

    /// Cuts `region` into tiles no smaller than the map will answer about.
    ///
    /// Never finer than `wideTileSpanDegrees`, and never more than `maxWideTiles` of them —
    /// so a small region is one tile and a county is a coarse grid over itself rather than
    /// hundreds of requests.
    nonisolated static func wideTiles(covering region: MKCoordinateRegion) -> [MKCoordinateRegion] {
        guard region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite,
              region.span.latitudeDelta > 0 || region.span.longitudeDelta > 0 else { return [] }
        // A place smaller than one tile still has to be asked about in a whole tile, or the
        // pass meant to cover it asks a question the map will not answer.
        let region = scannableRegion(region)
        let widest = max(region.span.latitudeDelta, region.span.longitudeDelta)
        let cap = max(1, Int(Double(maxWideTiles).squareRoot().rounded(.down)))
        let side = min(max(Int((widest / wideTileSpanDegrees).rounded(.down)), 1), cap)
        return tiles(for: region, side: side)
    }

    nonisolated static func latticeCell(containing coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let step = indexCellSpanDegrees
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

    /// The cells around one, so a sweep can grow outward.
    ///
    /// All eight from ground that belongs to the place, since that is the shape being
    /// filled. Only the four square neighbours when probing past a wall: a probe is a guess
    /// that the place continues on the far side of something, and the diagonals of a guess
    /// are mostly the same ground reached the long way. Probing two deep in eight directions
    /// wraps a two-cell skirt right round a city's perimeter, which for somewhere the size
    /// of Sammamish is more cells than the city itself.
    nonisolated static func latticeNeighbours(
        of cell: MKCoordinateRegion,
        includingDiagonals: Bool = true
    ) -> [MKCoordinateRegion] {
        let step = indexCellSpanDegrees
        var neighbours: [MKCoordinateRegion] = []
        for latitudeOffset in -1...1 {
            for longitudeOffset in -1...1 where !(latitudeOffset == 0 && longitudeOffset == 0) {
                if !includingDiagonals, latitudeOffset != 0, longitudeOffset != 0 { continue }
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
        let step = indexCellSpanDegrees
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
    /// - Parameter searchCell: How one cell is asked about. Defaults to the real map
    ///   service; a test supplies a synthetic city so the traversal can be measured without
    ///   spending searches against a shared rate limit.
    func sweepDense(
        around coordinate: CLLocationCoordinate2D,
        radiusMiles: Double,
        belongsToRegion: ((Park) -> Bool)? = nil,
        searchCell: (@Sendable (MKCoordinateRegion) async -> TileOutcome)? = nil,
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
        // The best probe depth each cell has been reached at, not merely whether it has.
        //
        // A plain visited set marks a cell the moment it is queued, so one first reached
        // from a wall — two cells from anything belonging, and about to give up — could
        // never be re-reached at full depth when a neighbour later turned out to be part of
        // the place. The sweep stopped short of ground it had every reason to search.
        var bestProbe: [Int64: Int] = [Self.latticeKey(queue[0].cell): 0]
        var found: [String: Park] = [:]
        var order: [String] = []
        var searches = 0
        var reused = 0
        var failures = 0
        var retries: [Int64: Int] = [:]
        var cellsSinceSave = 0
        /// The ground the sweep actually walked, which is what the text pass covers.
        ///
        /// Not the square around the circle: the sweep follows the shape of the place, and
        /// tiling the whole box would spend requests on corners it deliberately never went
        /// near. Grown by every cell taken off the queue, searched or reused, so a resumed
        /// sweep that reused everything still knows where the place is.
        var walked: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)?
        func note(walkedOver cell: MKCoordinateRegion) {
            let minLatitude = cell.center.latitude - cell.span.latitudeDelta / 2
            let maxLatitude = cell.center.latitude + cell.span.latitudeDelta / 2
            let minLongitude = cell.center.longitude - cell.span.longitudeDelta / 2
            let maxLongitude = cell.center.longitude + cell.span.longitudeDelta / 2
            guard let current = walked else {
                walked = (minLatitude, maxLatitude, minLongitude, maxLongitude)
                return
            }
            walked = (
                min(current.minLatitude, minLatitude),
                max(current.maxLatitude, maxLatitude),
                min(current.minLongitude, minLongitude),
                max(current.maxLongitude, maxLongitude)
            )
        }
        var completed = true
        var truncated = false
        /// Whether the sweep has found the place it is looking for yet.
        ///
        /// A flood fill needs a seed inside what it is filling, and the geocoder's centre
        /// for a city is not reliably that: it can land in a harbour, a river, an industrial
        /// strip, a downtown block with no park on it. Enforcing the give-up rule from the
        /// first cell meant such a place died two cells from its own centre having found
        /// nothing — which is exactly what indexing Boston, whose centre sits by the water,
        /// looked like. So the rule only applies once there is something to have left.
        var hasFoundRegion = false
        /// See `seedingBudget(radiusMiles:latitude:)`.
        let seedingBudget = Self.seedingBudget(radiusMiles: radiusMiles, latitude: coordinate.latitude)

        /// Consumed from the front by an index rather than by shifting the array. A sweep
        /// queues thousands of cells, and `removeFirst` on an `Array` copies the remainder
        /// every time, which is quadratic in the size of the frontier.
        var cursor = 0

        func report() {
            onProgress?(SweepProgress(
                tilesSearched: searches + reused,
                tilesTotal: searches + reused + max(0, queue.count - cursor),
                parksFound: order.count
            ))
        }
        report()
        sweepLog.notice("""
            sweep starting at \(coordinate.latitude, privacy: .public),\(coordinate.longitude, privacy: .public) \
            radius=\(radiusMiles, privacy: .public)mi cell=\(Self.indexCellSpanDegrees * 111, privacy: .public)km \
            budget=\(Self.maxIndexSearches, privacy: .public)
            """)

        let probeDepth = Self.regionProbeDepth(atLatitude: coordinate.latitude)
        let elsewhereCost = Self.probeCost(forSomewhereElseAtLatitude: coordinate.latitude)

        /// Grows into the cells around one that turned out to be part of the place.
        ///
        /// `probe` is how far the sweep has strayed from the last cell that belonged, counted
        /// against `probeDepth` — one for a cell that answered with nothing, more for one
        /// that answered with somewhere else.
        func expand(from cell: MKCoordinateRegion, probe: Int) {
            guard probe <= probeDepth else { return }
            for neighbour in Self.latticeNeighbours(of: cell, includingDiagonals: probe == 0) {
                let key = Self.latticeKey(neighbour)
                // Reaching somewhere with more depth to spare is worth queueing again.
                if let seen = bestProbe[key], seen <= probe { continue }
                // The circle is the backstop: whatever the results say, a sweep never
                // wanders beyond the extent the place was given.
                guard Self.tile(neighbour, intersectsCircleAround: coordinate, radiusMeters: radiusMeters) else { continue }
                bestProbe[key] = probe
                queue.append((neighbour, probe))
            }
        }

        while cursor < queue.count {
            if Task.isCancelled { completed = false; break }
            if searches >= Self.maxIndexSearches { truncated = true; break }
            if !hasFoundRegion, searches >= seedingBudget {
                sweepLog.error("gave up looking for the region after \(searches, privacy: .public) searches")
                lastError = "Couldn't find that place on the map. Try indexing it by a fuller name."
                completed = false
                break
            }

            // Ground a previous attempt already searched — including one that was cut short
            // — costs nothing, so it is cleared out of the way before a batch is taken.
            // Whether to keep growing through it is answered from the store rather than by
            // searching it again: the parks it found are already saved, and they know which
            // city they are in.
            var batch: [(cell: MKCoordinateRegion, probe: Int)] = []
            while cursor < queue.count, batch.count < Self.concurrentCellSearches {
                let entry = queue[cursor]
                cursor += 1
                if coverage.coversFinely(entry.cell, resolution: entry.cell.span.latitudeDelta, generation: Self.searchGeneration) {
                    reused += 1
                    note(walkedOver: entry.cell)
                    let stored = storedParks(in: entry.cell)
                    let known = belongsToRegion.map { test in stored.contains(where: test) } ?? true
                    if known { hasFoundRegion = true }
                    // The same weighing as a freshly searched cell, from what that cell's
                    // last search left behind.
                    let strayed = stored.isEmpty ? 1 : elsewhereCost
                    expand(from: entry.cell, probe: (known || !hasFoundRegion) ? 0 : entry.probe + strayed)
                    report()
                    continue
                }
                batch.append(entry)
            }
            guard !batch.isEmpty else { continue }

            let outcomes: [TileOutcome] = await withTaskGroup(of: (Int, TileOutcome).self) { group in
                for (index, entry) in batch.enumerated() {
                    group.addTask {
                        let outcome: TileOutcome
                        if let searchCell {
                            outcome = await searchCell(entry.cell)
                        } else {
                            outcome = await Self.indexCandidates(in: entry.cell)
                        }
                        return (index, outcome)
                    }
                }
                var collected = [TileOutcome?](repeating: nil, count: batch.count)
                for await (index, outcome) in group { collected[index] = outcome }
                return collected.map { $0 ?? TileOutcome() }
            }
            // One request per cell, which is also what the progress bar counts. It used to
            // add two — the cell cost two searches — while the remaining queue counted cells,
            // so "Searched 320 of 320 areas" was really 160 areas, and the budget looked
            // twice as spent as it was.
            searches += batch.count
            if Task.isCancelled { completed = false; break }
            sweepLog.debug("""
                batch of \(batch.count, privacy: .public) cells: \
                results \(outcomes.map(\.candidates.count).description, privacy: .public), \
                raw \(outcomes.map(\.rawCount).description, privacy: .public), \
                failures \(outcomes.compactMap(\.failure).count, privacy: .public)
                """)

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
                    } else {
                        // Out of retries. The cell is ground nobody has looked at, so the
                        // total cannot call itself exhaustive — it used to be dropped in
                        // silence, and a run the map had refused a dozen cells of published
                        // itself as a complete count of the place.
                        truncated = true
                        sweepLog.error("gave up on cell \(key, privacy: .public) after \(Self.maxTileRetries, privacy: .public) refusals")
                    }
                    continue
                }

                // A cell packed to the cap with parks of its own may be hiding more behind
                // them, and the lattice has no finer step to fall back on, so the honest
                // thing is to stop calling the total exhaustive: it becomes an "at least
                // this many", which is what `isApproximate` means.
                if outcome.rawCount >= Self.saturatedResultCount { truncated = true }

                coverage.record(cell, resolution: cell.span.latitudeDelta, generation: Self.searchGeneration)
                note(walkedOver: cell)
                cellsSinceSave += 1

                // Only a cell that actually turned up a park in this place resets the probe.
                //
                // Treating an empty cell as costing nothing at all — on the grounds that a
                // city is allowed water in the middle of it — meant expansion never
                // terminated through empty ground and ran to the circle backstop. San
                // Francisco is surrounded by water on three sides and Bellevue sits between
                // two lakes: both spent their whole budget sweeping the sea. It costs less
                // than a cell of somewhere else instead, so a place keeps its internal
                // water and its quiet streets without the sweep wandering out to sea.
                let belongs = belongsToRegion.map { test in saved.contains(where: test) } ?? true
                // A cell that answered with nothing has said only that there are no parks
                // here, which is true of a great deal of any city. A cell that answered with
                // parks belonging to the next town along has said where the edge is.
                let strayed = saved.isEmpty ? 1 : elsewhereCost
                if belongs, !hasFoundRegion {
                    hasFoundRegion = true
                    // Everything queued while hunting for the seed was queued at full depth,
                    // which is no longer a claim anyone made about it. Only this cell and
                    // what grows from it is the place; the rest goes back to being unvisited
                    // so the ordinary rules decide whether it is worth reaching.
                    queue.removeSubrange(cursor...)
                    for (key, probe) in bestProbe where probe == 0 {
                        if key != Self.latticeKey(cell) { bestProbe.removeValue(forKey: key) }
                    }
                }
                sweepLog.debug("""
                    cell \(Self.latticeKey(cell), privacy: .public) \
                    at \(cell.center.latitude, privacy: .public),\(cell.center.longitude, privacy: .public) \
                    kept \(saved.count, privacy: .public) of \(outcome.candidates.count, privacy: .public), \
                    belongs=\(belongs, privacy: .public) probe=\(probe, privacy: .public) \
                    queue=\(queue.count, privacy: .public)
                    """)
                // Until the place has been found at all, keep going: the give-up rule is
                // about having left somewhere, and the sweep may not have arrived yet.
                expand(from: cell, probe: (belongs || !hasFoundRegion) ? 0 : probe + strayed)
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

        // A text pass for the parks the map never categorised, which the per-cell request
        // cannot see: it asks for a category, and these have none. South Mercer Playfields
        // and Bellevue Botanical Garden are both this.
        //
        // Tiled, not one search over the whole square. One query answers with about
        // twenty-five results however much ground it is given, so a single pass over a
        // fifteen-kilometre city is a sample rather than a sweep — Illahee Trail Park sat in
        // Sammamish through a full index and was turned up immediately by one 0.06° search.
        // Tiles are cut no finer than the map will answer about, and there are at most
        // sixteen, so this is a handful of requests on top of a run that costs hundreds.
        //
        // Over the ground the sweep walked rather than the square around the circle, and run
        // whether or not this attempt searched anything new — a re-index that reuses every
        // cell still has to do this pass, because the last one may not have.
        //
        // Skipped when the caller supplied its own map: a test that injects `searchCell` is
        // describing the whole world it wants swept, and a live request sneaking in behind it
        // made the offline suite depend on what the real service happened to return that day.
        if completed, !Task.isCancelled, searchCell == nil, let walked {
            let footprint = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (walked.minLatitude + walked.maxLatitude) / 2,
                    longitude: (walked.minLongitude + walked.maxLongitude) / 2
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: walked.maxLatitude - walked.minLatitude,
                    longitudeDelta: walked.maxLongitude - walked.minLongitude
                )
            )
            let wideTiles = Self.wideTiles(covering: footprint)
            sweepLog.notice("text pass over \(wideTiles.count, privacy: .public) tiles of the swept ground")
            for tile in wideTiles {
                if Task.isCancelled { break }
                guard let wide = try? await Self.search(
                    query: "park", region: tile, poiFiltered: false, requireParkLike: true
                ) else { continue }
                searches += 1
                for park in persist(Self.confined(wide, to: tile)) where found[park.identifier] == nil {
                    found[park.identifier] = park
                    order.append(park.identifier)
                }
                report()
            }
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
        sweepLog.notice("""
            sweep finished: searches=\(searches, privacy: .public) reused=\(reused, privacy: .public) \
            parks=\(order.count, privacy: .public) completed=\(completed, privacy: .public) \
            truncated=\(truncated, privacy: .public) error=\(self.lastError ?? "none", privacy: .public)
            """)
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
        // Adding one by hand is the user changing their mind, and it has to stick: leaving
        // the exclusion in place would let this park be added now and dropped by the next
        // sweep that passed over it.
        for struckOff in excludedPlaces() where struckOff.identifier == candidate.id {
            modelContext.delete(struckOff)
        }
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
    // MARK: - Places the user has rejected

    /// Whether this place has been struck off by hand. See `ExcludedPlace`.
    func isExcluded(_ identifier: String) -> Bool {
        !excludedIdentifiers(among: [identifier]).isEmpty
    }

    /// Which of these have been struck off, in one question.
    private func excludedIdentifiers(among identifiers: [String]) -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        let wanted = Set(identifiers)
        let descriptor = FetchDescriptor<ExcludedPlace>(
            predicate: #Predicate<ExcludedPlace> { wanted.contains($0.identifier) }
        )
        return Set(((try? modelContext.fetch(descriptor)) ?? []).map(\.identifier))
    }

    /// Removes a park from the catalogue and remembers not to file it again.
    ///
    /// The two halves belong together: deleting without recording is undone by the next
    /// sweep, and recording without deleting leaves the thing the user objected to on screen.
    func exclude(_ park: Park) {
        if !isExcluded(park.identifier) {
            modelContext.insert(ExcludedPlace(park: park))
        }
        modelContext.delete(park)
        try? modelContext.save()
    }

    /// Lets a place back in. The next sweep over that ground will find it again.
    func readmit(_ excluded: ExcludedPlace) {
        modelContext.delete(excluded)
        try? modelContext.save()
    }

    func excludedPlaces() -> [ExcludedPlace] {
        let descriptor = FetchDescriptor<ExcludedPlace>(sortBy: [SortDescriptor(\.name)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }

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
        // Places the user has said are not parks. The map has not changed its mind about
        // them, so without this every sweep over that ground files them again and removing
        // one achieves nothing that lasts.
        //
        // Asked once for the whole batch, not once per candidate: a sweep calls this for
        // every cell it searches, and a fetch per result is hundreds of round trips to the
        // store on the main actor while the user watches a progress bar.
        let struckOff = excludedIdentifiers(among: candidates.map(\.id))
        let candidates = candidates.filter { !struckOff.contains($0.id) }
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
    /// Internal so a test can drive `sweepDense` without touching the map service: the
    /// traversal is the part worth exercising, and it costs nothing to run offline.
    struct TileOutcome {
        var candidates: [ParkCandidate] = []
        var failure: String?
        /// How many results landed inside the ground that was asked about.
        ///
        /// This used to be the raw size of the response, on the theory that a full response
        /// is a tile hiding parks it had no room to mention. Against the real service that
        /// measured nothing at all: a search answers with about twenty-five results whatever
        /// it is asked, and below about 0.05° those results are not even from the region.
        /// A cell of Kirkland came back with twenty-five parks of which two were in the cell
        /// — and, being twenty-five, marked the sweep "at least this many" for ever. Every
        /// index of every populated place was permanently approximate, and no amount of
        /// re-indexing could clear it, because the number was never about the cell.
        ///
        /// Counting only what was in the cell makes the test mean what it says.
        var rawCount: Int = 0

        /// True when the map answered with plenty and none of it was on the ground asked
        /// about — the signature of a region too small to be honoured, where the search
        /// falls back to the device's own surroundings. Distinct from a genuinely empty
        /// answer, which is what a stretch of farmland looks like and is worth recording as
        /// searched. See `ParkDiscoveryService.scannableRegion(_:)`.
        var answeredAboutSomewhereElse = false
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
        let offered = deduped(merged.candidates).count
        merged.candidates = deduped(merged.candidates.filter {
            SweptCoverage.region(region, contains: $0.coordinate)
        })
        // Plenty offered, none of it here. The question was not answered, so the ground it
        // was about has not been searched and must not be written down as though it had.
        merged.answeredAboutSomewhereElse = offered > 0 && merged.candidates.isEmpty
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

    /// Asks the map what is actually in one cell.
    ///
    /// Not `MKLocalSearch.Request` with a region, which is what this used to be and which
    /// cannot answer that question at this size. Its `region` is honoured above roughly
    /// 0.05° and discarded below it, and what it falls back to is the device's own location.
    /// Measured over one spot in Sammamish, varying nothing but the span:
    ///
    ///     0.010°   0 of 25 results inside the region
    ///     0.014°   0 of 25
    ///     0.03°    0 of 25
    ///     0.06°    8 of 25
    ///     0.12°   13 of 25
    ///
    /// The index asked at 0.014° and threw every answer away as out-of-cell. A real sweep of
    /// Sammamish searched seventy-six cells, saved zero parks, and gave up saying the map
    /// could not find the place — while browsing the same ground found plenty, because a
    /// browsing scan tiles at 0.06° and lands on the working side of the threshold.
    ///
    /// It is also why indexing Bellevue looked fine and Sammamish did not. The device is in
    /// Bellevue: every sub-threshold cell fell back to it and answered with Bellevue parks,
    /// which for Bellevue happened to be the right answer. Nowhere else got that luck.
    ///
    /// `MKLocalPointsOfInterestRequest` has no such threshold: it is bounded at every size,
    /// so the same cell answers with the parks that are in it. Measured, its reach is about
    /// a kilometre whatever radius it is handed — 3 km and 20 km requests over downtown
    /// Bellevue both returned the same fourteen parks, none further out than 1.0 km — which
    /// is why `indexCellSpanDegrees` is sized to fit inside that reach.
    ///
    /// It is one request per cell rather than two, and there is no text pass paired with it,
    /// because there is nothing left for one to add: the results it used to contribute were
    /// the uncategorised ones, and uncategorised results are not parks. See `isParkLike`.
    nonisolated static func indexCandidates(in region: MKCoordinateRegion) async -> TileOutcome {
        var outcome = TileOutcome()
        let request = MKLocalPointsOfInterestRequest(
            center: region.center,
            radius: cellRequestRadius(for: region)
        )
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: Array(parkLikeCategories))

        do {
            let response = try await SearchThrottle.shared.run(request)
            outcome.candidates = deduped(response.mapItems.compactMap {
                candidate(from: $0, requireParkLike: true)
            })
            outcome.rawCount = resultsInside(
                region,
                coordinates: response.mapItems.map(\.placemark.coordinate)
            )
        } catch {
            // An empty answer is not a refusal. This request reports "nothing within a
            // kilometre of here" as an error, and a good deal of any city is exactly that:
            // a cell of housing, a cell of water. Reading it as a failure put the cell back
            // on the queue three times over and counted it towards abandoning the sweep.
            if let mkError = error as? MKError, mkError.code == .placemarkNotFound {
                return outcome
            }
            outcome.failure = message(for: error)
        }
        return outcome
    }

    /// How much of an answer was about the ground that was asked about.
    ///
    /// This is the whole of the saturation test, and getting it wrong is what pinned every
    /// index at "at least this many". A cell of Kirkland, measured, answered with 25 parks
    /// of which 2 were in the cell: judged on 25 it looked full to bursting, judged on 2 it
    /// is a suburb with two parks in it, which is what it is.
    nonisolated static func resultsInside(
        _ cell: MKCoordinateRegion,
        coordinates: [CLLocationCoordinate2D]
    ) -> Int {
        coordinates.count { SweptCoverage.region(cell, contains: $0) }
    }

    /// The radius that covers a whole cell: its half-diagonal, so the corners are in it too.
    ///
    /// A degree of longitude shrinks towards the poles, so a cell cut from a fixed degree
    /// lattice is widest at the equator. This measures the cell in front of it rather than
    /// assuming one shape for the whole world.
    nonisolated static func cellRequestRadius(for cell: MKCoordinateRegion) -> CLLocationDistance {
        let halfLatitude = cell.span.latitudeDelta / 2 * metersPerDegreeLatitude
        let halfLongitude = cell.span.longitudeDelta / 2
            * metersPerDegreeLatitude * cos(cell.center.latitude * .pi / 180)
        return (halfLatitude * halfLatitude + halfLongitude * halfLongitude).squareRoot()
    }

    nonisolated static let metersPerDegreeLatitude: CLLocationDistance = 111_320

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

    /// Whether a map result is a park, which now means: the map says so.
    ///
    /// It used to mean "the map says so, *or* it has a park word in its name", so that a park
    /// the map never got round to categorising would still be found. Measured against the
    /// real service, that fallback does not do what it was meant to. Over a dense cell of
    /// Kirkland and Bellevue, every genuine park came back carrying `MKPOICategoryPark`, and
    /// the only uncategorised results were apartment buildings — "Park Bellevue", "Park 88",
    /// "Parkside Esterra Park", "Capella at Esterra Park". A block of flats named after the
    /// park it overlooks is the *typical* uncategorised result, not the exception, so the
    /// fallback admitted far more homes and offices than it ever rescued parks.
    ///
    /// The name is still worth having as a hint for a human — see `hasParkLikeName` — but it
    /// is not enough on its own to file something in the catalogue.
    nonisolated static func isParkLike(name: String, category: MKPointOfInterestCategory?) -> Bool {
        if let category { return parkLikeCategories.contains(category) }
        return hasParkLikeName(name)
    }

    /// Whether a name reads like a park's, for explaining a judgement rather than making one.
    ///
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
