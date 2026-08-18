import XCTest
import CoreLocation
import MapKit
import SwiftData
@testable import ParkTrack

/// Indexing a large city is hundreds of small searches against a rate limit, so an attempt
/// that is interrupted has to be worth something: the ground it did cover must still be
/// covered next time. These pin down that it is.
@MainActor
final class IndexResumeTests: XCTestCase {

    /// A grid of index-grade tiles over roughly the extent of a city.
    private func cityTiles(count: Int, span: Double = 0.014) -> [MKCoordinateRegion] {
        (0..<count).map { index in
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: 37.75 + Double(index / 20) * span,
                    longitude: -122.45 + Double(index % 20) * span
                ),
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            )
        }
    }

    private func record(_ tiles: [MKCoordinateRegion], into coverage: inout SweptCoverage) {
        for tile in tiles {
            coverage.record(tile, resolution: tile.span.latitudeDelta)
        }
    }

    private func finelyCovered(_ tiles: [MKCoordinateRegion], in coverage: SweptCoverage) -> Int {
        tiles.filter { coverage.coversFinely($0, resolution: $0.span.latitudeDelta) }.count
    }

    /// A single index run's worth of tiles, all remembered.
    ///
    /// The budget for one region is `maxIndexSearches`, so anything less than that being
    /// retained means an interrupted index throws its own work away.
    func testAWholeIndexRunFitsInCoverage() {
        var coverage = SweptCoverage()
        let tiles = cityTiles(count: ParkDiscoveryService.maxIndexSearches)
        record(tiles, into: &coverage)

        XCTAssertEqual(
            finelyCovered(tiles, in: coverage),
            tiles.count,
            "Every tile a run searched has to still count as searched"
        )
    }

    /// The reported bug: index San Francisco, kill the app part-way, reopen — and it starts
    /// again from nothing.
    func testAnInterruptedIndexResumesWhereItStopped() {
        var coverage = SweptCoverage()
        let tiles = cityTiles(count: 200)
        record(tiles, into: &coverage)

        // What a relaunch does: the squares are written out, then rebuilt from the store.
        var restored = SweptCoverage()
        restored.restore(coverage.bounds)

        XCTAssertEqual(
            finelyCovered(tiles, in: restored),
            tiles.count,
            "Ground searched before the app died must not be searched again"
        )
    }

    /// Coverage still has to be bounded — the whole point of a cap is that a user who roams
    /// for months does not accumulate forever.
    func testCoverageStaysBounded() {
        var coverage = SweptCoverage()
        record(cityTiles(count: 5_000), into: &coverage)
        XCTAssertLessThanOrEqual(coverage.bounds.count, 1_000, "Coverage cannot grow without limit")
    }

    /// A finished index collapses its tiles into the one square it completed, which is what
    /// keeps the cap from ever being reached in ordinary use.
    func testAFinishedIndexCollapsesItsTiles() {
        var coverage = SweptCoverage()
        let tiles = cityTiles(count: 100)
        record(tiles, into: &coverage)
        XCTAssertGreaterThan(coverage.bounds.count, 1)

        let whole = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.785, longitude: -122.32),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
        coverage.record(whole, resolution: 0.014)

        XCTAssertEqual(coverage.bounds.count, 1, "One square now stands for all of them")
        XCTAssertEqual(finelyCovered(tiles, in: coverage), tiles.count)
    }

    // MARK: - Through the store

    /// The reported scenario end to end: index a big city, kill the app outright part-way,
    /// reopen. The service is rebuilt from the store, so anything the periodic writes did
    /// not keep is searched all over again.
    ///
    /// The existing resume test used a single tile, which is why this went unnoticed: one
    /// tile fits under any cap.
    func testAnInterruptedIndexResumesAfterTheAppIsKilled() {
        let container = PersistenceController.makeInMemoryContainer()
        let service = ParkDiscoveryService(modelContext: ModelContext(container))

        let tiles = cityTiles(count: 200)
        for tile in tiles {
            service.noteScanned(region: tile, resolution: tile.span.latitudeDelta)
        }

        // Nothing carried over in memory — this is a fresh launch reading the store.
        let relaunched = ParkDiscoveryService(modelContext: ModelContext(container))
        let remembered = tiles.filter {
            relaunched.hasSweptFinely(region: $0, resolution: $0.span.latitudeDelta)
        }

        XCTAssertEqual(
            remembered.count,
            tiles.count,
            "Every tile searched before the app died has to survive the relaunch"
        )
    }

    /// Writing coverage that has not moved must not touch the store. An index writes every
    /// few tiles, and a needless write is both work on the main actor and an invalidation of
    /// every derived cache in the app.
    func testRewritingUnchangedCoverageWritesNothing() {
        let container = PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let service = ParkDiscoveryService(modelContext: context)

        let tiles = cityTiles(count: 40)
        for tile in tiles {
            service.noteScanned(region: tile, resolution: tile.span.latitudeDelta)
        }

        let rows = (try? context.fetch(FetchDescriptor<ScannedArea>())) ?? []
        XCTAssertEqual(rows.count, tiles.count)
        let identities = Set(rows.map { ObjectIdentifier($0) })

        // Recording ground already covered changes nothing, so the rows should be the very
        // same objects rather than a fresh set.
        service.noteScanned(region: tiles[0], resolution: tiles[0].span.latitudeDelta)

        let after = (try? context.fetch(FetchDescriptor<ScannedArea>())) ?? []
        XCTAssertEqual(Set(after.map { ObjectIdentifier($0) }), identities, "Unchanged coverage was rewritten")
    }

    /// Indexing a city must not un-sweep the ground around the user.
    ///
    /// The rings on Home read coverage to decide whether an area has been swept or is only
    /// partially known. There are just a handful of those wide squares, against hundreds of
    /// index tiles, so an eviction rule that went after them turned "Swept" back into
    /// "Partial" the moment a city was indexed.
    func testIndexingACityDoesNotUnsweepTheAreaAroundHome() {
        var coverage = SweptCoverage()

        // A 25-mile sweep around home, of the kind the rings are built on.
        let home = CLLocationCoordinate2D(latitude: 47.674, longitude: -122.121)
        let sweep = ParkDiscoveryService.boundingSquare(around: home, radiusMiles: 25)
        coverage.record(sweep, resolution: sweep.span.latitudeDelta)
        XCTAssertTrue(coverage.covers(center: home, radiusMiles: 25))

        // Then a full budget's worth of index tiles somewhere else entirely.
        record(cityTiles(count: ParkDiscoveryService.maxIndexSearches), into: &coverage)

        XCTAssertTrue(
            coverage.covers(center: home, radiusMiles: 25),
            "Home is still swept"
        )
    }

    /// Even well past the cap, the wide squares are the last things to go.
    func testTheWidestCoverageSurvivesHeavyPressure() {
        var coverage = SweptCoverage()
        let home = CLLocationCoordinate2D(latitude: 47.674, longitude: -122.121)
        let sweep = ParkDiscoveryService.boundingSquare(around: home, radiusMiles: 25)
        coverage.record(sweep, resolution: sweep.span.latitudeDelta)

        record(cityTiles(count: 3_000), into: &coverage)

        XCTAssertTrue(coverage.covers(center: home, radiusMiles: 25))
    }

    /// A coarse pass must never be able to erase the memory of a fine one underneath it,
    /// or a browse of the map would undo an index.
    func testACoarsePassDoesNotEraseFineCoverage() {
        var coverage = SweptCoverage()
        let tiles = cityTiles(count: 50)
        record(tiles, into: &coverage)

        coverage.record(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.785, longitude: -122.32),
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ),
            resolution: ScannedArea.coarsest
        )

        XCTAssertEqual(finelyCovered(tiles, in: coverage), tiles.count)
    }
}

/// Cells come from a fixed worldwide lattice, which is what lets one run reuse another's
/// work — and what lets a sweep follow the shape of a place instead of covering a box.
@MainActor
final class IndexLatticeTests: XCTestCase {

    private let centre = CLLocationCoordinate2D(latitude: 37.7599, longitude: -122.4370)
    private var probeDepth: Int { ParkDiscoveryService.regionProbeDepth(atLatitude: centre.latitude) }

    private func cell(_ coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        ParkDiscoveryService.latticeCell(containing: coordinate)
    }

    func testTheSameGroundAlwaysGivesTheSameCell() {
        let a = cell(centre)
        // Anywhere inside the cell has to land on the cell.
        let inside = CLLocationCoordinate2D(
            latitude: a.center.latitude + a.span.latitudeDelta * 0.4,
            longitude: a.center.longitude - a.span.longitudeDelta * 0.4
        )
        let b = cell(inside)

        XCTAssertEqual(ParkDiscoveryService.latticeKey(a), ParkDiscoveryService.latticeKey(b))
        XCTAssertEqual(a.center.latitude, b.center.latitude, accuracy: 1e-12)
    }

    /// The regression that made resuming impossible: the grid used to hang off the region's
    /// geocoded centre, which moves. On a world lattice it cannot.
    func testACentreThatMovesDoesNotMoveTheGrid() {
        let drifted = CLLocationCoordinate2D(latitude: centre.latitude + 0.00005, longitude: centre.longitude)
        XCTAssertEqual(
            ParkDiscoveryService.latticeKey(cell(centre)),
            ParkDiscoveryService.latticeKey(cell(drifted)),
            "Five metres of geocoder drift used to throw away every finished cell"
        )
    }

    /// Two places whose sweeps overlap share the ground between them, so indexing a city
    /// leaves work its neighbouring county can reuse.
    func testNeighbouringRegionsShareTheirOverlap() {
        var coverage = SweptCoverage()
        let shared = cell(centre)
        coverage.record(shared, resolution: shared.span.latitudeDelta)

        // Somewhere else inside the same cell — measured from the cell rather than from an
        // arbitrary coordinate, which otherwise happens to sit on a grid line.
        let fromElsewhere = ParkDiscoveryService.latticeCell(
            containing: CLLocationCoordinate2D(
                latitude: shared.center.latitude + shared.span.latitudeDelta / 4,
                longitude: shared.center.longitude + shared.span.longitudeDelta / 4
            )
        )
        XCTAssertTrue(coverage.coversFinely(fromElsewhere, resolution: fromElsewhere.span.latitudeDelta))
    }

    func testEveryNeighbourTouchesTheCellItCameFrom() {
        let origin = cell(centre)
        let neighbours = ParkDiscoveryService.latticeNeighbours(of: origin)

        XCTAssertEqual(neighbours.count, 8)
        XCTAssertEqual(Set(neighbours.map(ParkDiscoveryService.latticeKey)).count, 8, "No duplicates")
        XCTAssertFalse(
            neighbours.map(ParkDiscoveryService.latticeKey).contains(ParkDiscoveryService.latticeKey(origin)),
            "A cell is not its own neighbour"
        )
        for neighbour in neighbours {
            let gap = abs(neighbour.center.latitude - origin.center.latitude)
            XCTAssertLessThanOrEqual(gap, origin.span.latitudeDelta * 1.01)
        }
    }

    // MARK: - Following the shape

    /// What a cell turns out to be when it is searched.
    enum Ground {
        /// A park in the place being indexed.
        case belongs
        /// Parks, but all of them somewhere else.
        case elsewhere
        /// Nothing at all — water, an airfield, a stretch of nowhere.
        case empty
    }

    /// How far a cell of each kind carries the sweep from the last one that belonged, as
    /// `sweepDense` weighs it: nothing here is weaker evidence of a boundary than parks that
    /// belong to the town next door.
    private func probeAfter(_ ground: Ground, from probe: Int) -> Int {
        switch ground {
        case .belongs: return 0
        case .empty: return probe + 1
        case .elsewhere:
            return probe + ParkDiscoveryService.probeCost(forSomewhereElseAtLatitude: centre.latitude)
        }
    }

    /// Models the sweep offline: grow from the centre, treat `ground` as what the map would
    /// say, and count the cells that would actually be searched.
    private func cellsSearched(
        radiusMeters: CLLocationDistance,
        ground: (CLLocationCoordinate2D) -> Ground
    ) -> Int {
        var queue: [(MKCoordinateRegion, Int)] = [(cell(centre), 0)]
        var visited: Set<Int64> = [ParkDiscoveryService.latticeKey(queue[0].0)]
        var searched = 0

        while let (current, probe) = queue.first {
            queue.removeFirst()
            searched += 1
            let nextProbe = probeAfter(ground(current.center), from: probe)
            guard nextProbe <= probeDepth else { continue }
            for neighbour in ParkDiscoveryService.latticeNeighbours(of: current) {
                let key = ParkDiscoveryService.latticeKey(neighbour)
                guard !visited.contains(key) else { continue }
                guard ParkDiscoveryService.tile(
                    neighbour, intersectsCircleAround: centre, radiusMeters: radiusMeters
                ) else { continue }
                visited.insert(key)
                queue.append((neighbour, nextProbe))
            }
        }
        return searched
    }

    /// San Francisco's numbers: a 30 km geocoded radius around a city about 6 km across.
    func testASweepCostsWhatThePlaceIsWorthNotWhatTheCircleIs() {
        let cityRadius: CLLocationDistance = 6_000
        let geocodedRadius: CLLocationDistance = 30_000
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)

        let shaped = cellsSearched(radiusMeters: geocodedRadius) { coordinate in
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: origin) <= cityRadius ? .belongs : .elsewhere
        }
        // What filling the circle costs, which is what the sweep used to do.
        let wholeCircle = cellsSearched(radiusMeters: geocodedRadius) { _ in .belongs }

        XCTAssertLessThan(shaped, wholeCircle / 4, "Following the shape has to be dramatically cheaper")
        XCTAssertLessThanOrEqual(
            shaped,
            ParkDiscoveryService.maxIndexSearches,
            "…and it has to fit in the budget, or the city can never finish"
        )
        print("PLAN shaped=\(shaped) wholeCircle=\(wholeCircle) budget=\(ParkDiscoveryService.maxIndexSearches)")
    }

    /// A place with water through the middle is still one place. The sweep keeps going a
    /// little way past a cell that came back as somewhere else.
    func testASweepCrossesASmallGapInThePlace() {
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        func metres(_ coordinate: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: origin)
        }
        // Land, a 2 km channel, then more land.
        let reached = cellsSearched(radiusMeters: 30_000) { coordinate in
            let distance = metres(coordinate)
            return distance <= 2_000 || (distance >= 4_000 && distance <= 6_000) ? .belongs : .empty
        }
        let nearSideOnly = cellsSearched(radiusMeters: 30_000) { metres($0) <= 2_000 ? .belongs : .elsewhere }

        XCTAssertGreaterThan(reached, nearSideOnly, "The far bank has to be reached across the channel")
    }

    /// The reported failure: a city on the coast spent its entire budget sweeping the sea,
    /// because empty ground was treated as neither here nor there and so never ended the
    /// expansion.
    func testASweepDoesNotRunAwayIntoEmptyGround() {
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        let coastal = cellsSearched(radiusMeters: 30_000) { coordinate in
            // Land to the north, open water everywhere else — San Francisco, roughly.
            let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: origin)
            return (distance <= 3_000 && coordinate.latitude >= centre.latitude) ? .belongs : .empty
        }

        XCTAssertLessThanOrEqual(
            coastal,
            ParkDiscoveryService.maxIndexSearches,
            "The sea is not part of the city and must not be swept to the horizon"
        )
        print("PLAN coastal=\(coastal)")
    }

    // MARK: - Spending the budget across runs

    /// Runs the sweep with a budget and a coverage store, so repeated attempts can be
    /// followed the way the real thing works.
    private func budgetedRun(
        budget: Int,
        radiusMeters: CLLocationDistance,
        coverage: inout SweptCoverage,
        ground: (CLLocationCoordinate2D) -> Ground
    ) -> (searched: Int, reused: Int) {
        var queue: [(MKCoordinateRegion, Int)] = [(cell(centre), 0)]
        var visited: Set<Int64> = [ParkDiscoveryService.latticeKey(queue[0].0)]
        var searched = 0
        var reused = 0

        while let (current, probe) = queue.first {
            queue.removeFirst()
            if searched >= budget { break }

            let alreadyDone = coverage.coversFinely(current, resolution: current.span.latitudeDelta)
            if alreadyDone {
                reused += 1
            } else {
                searched += 1
                coverage.record(current, resolution: current.span.latitudeDelta)
            }

            let nextProbe = probeAfter(ground(current.center), from: probe)
            guard nextProbe <= probeDepth else { continue }
            for neighbour in ParkDiscoveryService.latticeNeighbours(of: current) {
                let key = ParkDiscoveryService.latticeKey(neighbour)
                guard !visited.contains(key) else { continue }
                guard ParkDiscoveryService.tile(
                    neighbour, intersectsCircleAround: centre, radiusMeters: radiusMeters
                ) else { continue }
                visited.insert(key)
                queue.append((neighbour, nextProbe))
            }
        }
        return (searched, reused)
    }

    /// The question behind the ceiling: does a second attempt spend its budget on new
    /// ground, so two runs really are worth twice one?
    func testASecondRunSpendsItsWholeBudgetOnNewGround() {
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        func ground(_ coordinate: CLLocationCoordinate2D) -> Ground {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: origin) <= 20_000 ? .belongs : .elsewhere
        }

        var coverage = SweptCoverage()
        let budget = 100

        let first = budgetedRun(budget: budget, radiusMeters: 30_000, coverage: &coverage, ground: ground)
        XCTAssertEqual(first.searched, budget, "The first run spends the lot")
        XCTAssertEqual(first.reused, 0)

        // A relaunch: coverage is all that carries over.
        var restored = SweptCoverage()
        restored.restore(coverage.bounds)

        let second = budgetedRun(budget: budget, radiusMeters: 30_000, coverage: &restored, ground: ground)
        XCTAssertEqual(second.reused, budget, "Everything the first run did is skipped, not redone")
        XCTAssertEqual(second.searched, budget, "…and the whole budget goes on ground nobody has seen")
    }

    /// A run over ground entirely covered already must cost nothing at all.
    func testAFullyCoveredRegionCostsNoSearches() {
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        func ground(_ coordinate: CLLocationCoordinate2D) -> Ground {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: origin) <= 8_000 ? .belongs : .elsewhere
        }

        var coverage = SweptCoverage()
        // Enough attempts to finish it.
        var guard_ = 0
        while guard_ < 40 {
            let run = budgetedRun(budget: 200, radiusMeters: 30_000, coverage: &coverage, ground: ground)
            guard_ += 1
            if run.searched == 0 { break }
        }

        let final = budgetedRun(budget: 200, radiusMeters: 30_000, coverage: &coverage, ground: ground)
        XCTAssertEqual(final.searched, 0, "Nothing left to search means nothing is searched")
        XCTAssertGreaterThan(final.reused, 0, "…and the ground is still walked, from the record")
    }

    /// And it converges: enough attempts finish the place, rather than circling forever.
    func testRepeatedRunsEventuallyFinish() {
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        func ground(_ coordinate: CLLocationCoordinate2D) -> Ground {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: origin) <= 8_000 ? .belongs : .elsewhere
        }

        var coverage = SweptCoverage()
        var runs = 0
        var lastSearched = Int.max
        while lastSearched > 0, runs < 20 {
            let result = budgetedRun(budget: 100, radiusMeters: 30_000, coverage: &coverage, ground: ground)
            lastSearched = result.searched
            runs += 1
        }
        XCTAssertLessThan(runs, 20, "A place has to finish in a sane number of attempts")
        print("PLAN runs to finish: \(runs)")
    }

    // MARK: - Fixing a cache built by an older sweep

    /// Ground swept before the index asked the map both ways is real coverage, but it is not
    /// what a sweep would find now — about a tenth short. Re-indexing has to redo it.
    func testGroundSweptByAnOlderGenerationIsNotReused() {
        var coverage = SweptCoverage()
        let old = cell(centre)
        coverage.record(old, resolution: old.span.latitudeDelta, generation: 0)

        XCTAssertFalse(
            coverage.coversFinely(old, resolution: old.span.latitudeDelta,
                                  generation: ParkDiscoveryService.searchGeneration),
            "A re-index must not skip ground the old search under-covered"
        )
        XCTAssertTrue(
            coverage.coversFinely(old, resolution: old.span.latitudeDelta, generation: 0),
            "…but the map may still browse it without re-searching"
        )
    }

    /// Once redone, it is skipped again — so a re-index costs less the second time and
    /// continuing an unfinished one costs only what it never reached.
    func testGroundRedoneAtTheCurrentGenerationIsReusedAgain() {
        var coverage = SweptCoverage()
        let old = cell(centre)
        coverage.record(old, resolution: old.span.latitudeDelta, generation: 0)
        coverage.record(old, resolution: old.span.latitudeDelta,
                        generation: ParkDiscoveryService.searchGeneration)

        XCTAssertTrue(coverage.coversFinely(old, resolution: old.span.latitudeDelta,
                                            generation: ParkDiscoveryService.searchGeneration))
    }

    /// Every place counted by the old sweep has to surface as needing attention, or the
    /// short totals stay on screen looking authoritative.
    func testAnIndexFromTheOldSweepAsksToBeRedone() {
        let record = RegionIndex(
            identifier: RegionIndex.identity(kind: .city, name: "Bellevue", container: "WA"),
            kind: .city, name: "Bellevue", container: "WA", country: "United States",
            center: centre, radiusMeters: 8_833
        )
        record.parkCount = 66
        record.indexedAt = Date()
        record.indexerVersion = 1

        XCTAssertTrue(record.needsReindexing)
        XCTAssertFalse(record.isIndexed, "…and it reads as partial until it is")
    }

    /// Coverage from the old, biased sweep can never be reused — but does it get out of the
    /// way of the new sweep, or does it sit there taking up room?
    func testOldGenerationCoverageDoesNotCrowdOutTheNew() {
        var coverage = SweptCoverage()
        // Three cities' worth of cells recorded by the previous generation, at the cell size
        // it used.
        for index in 0..<350 {
            let stale = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 47.0 + Double(index) * 0.014, longitude: -122.0),
                span: MKCoordinateSpan(latitudeDelta: 0.014, longitudeDelta: 0.014)
            )
            coverage.record(stale, resolution: 0.014, generation: 1)
        }
        // Then a full run at the current generation and cell size.
        var recorded: [MKCoordinateRegion] = []
        for index in 0..<ParkDiscoveryService.maxIndexSearches {
            let cell = ParkDiscoveryService.latticeCell(
                containing: CLLocationCoordinate2D(latitude: 40.0 + Double(index) * 0.010, longitude: -122.0)
            )
            recorded.append(cell)
            coverage.record(cell, resolution: cell.span.latitudeDelta,
                            generation: ParkDiscoveryService.searchGeneration)
        }

        let kept = recorded.count {
            coverage.coversFinely($0, resolution: $0.span.latitudeDelta,
                                  generation: ParkDiscoveryService.searchGeneration)
        }
        XCTAssertEqual(kept, recorded.count, "the new run's cells were evicted by dead ones")
    }

    /// …but not so far that it wanders into the next town.
    func testASweepStopsAtALargeGap() {
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        let reached = cellsSearched(radiusMeters: 30_000) { coordinate in
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: origin) <= 2_000 ? .belongs : .elsewhere
        }
        XCTAssertLessThan(reached, 120, "A sweep must not keep going once the place has ended")
    }
}


/// Guards on how a sweep decides where to go next, and on which parks still need checking.
@MainActor
final class SweepExpansionTests: XCTestCase {

    private let centre = CLLocationCoordinate2D(latitude: 47.6139, longitude: -122.2017)
    private var probeDepth: Int { ParkDiscoveryService.regionProbeDepth(atLatitude: centre.latitude) }

    /// A cell first reached from a wall, with its probe nearly spent, has to be reachable
    /// again at full depth once a neighbour turns out to belong — otherwise the sweep stops
    /// short of ground it had every reason to search.
    func testACellReachedFromAWallCanBeReachedAgainAtFullDepth() throws {
        var bestProbe: [Int64: Int] = [:]
        var queue: [(MKCoordinateRegion, Int)] = []

        func expand(from cell: MKCoordinateRegion, probe: Int) {
            guard probe <= probeDepth else { return }
            for neighbour in ParkDiscoveryService.latticeNeighbours(of: cell) {
                let key = ParkDiscoveryService.latticeKey(neighbour)
                if let seen = bestProbe[key], seen <= probe { continue }
                bestProbe[key] = probe
                queue.append((neighbour, probe))
            }
        }

        let start = ParkDiscoveryService.latticeCell(containing: centre)
        // Reached first from a wall, with its probe all but spent.
        let spent = probeDepth
        expand(from: start, probe: spent)
        let target = try XCTUnwrap(queue.first).0
        let key = ParkDiscoveryService.latticeKey(target)
        XCTAssertEqual(bestProbe[key], spent)

        // Then a cell that genuinely belongs reaches the same ground.
        queue.removeAll()
        expand(from: start, probe: 0)

        XCTAssertEqual(bestProbe[key], 0, "The better route has to win")
        XCTAssertTrue(
            queue.contains { ParkDiscoveryService.latticeKey($0.0) == key },
            "…and the cell has to be queued again to use it"
        )
    }

    /// A flood fill needs a seed inside what it is filling. A city's geocoded centre is not
    /// reliably that — a harbour, a river, a downtown block with no park on it — and giving
    /// up two cells from a bad seed means never finding the city at all.
    func testASweepFindsAPlaceItsCentreIsNotIn() {
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        func distance(_ coordinate: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: origin)
        }

        // The place is a ring 4-7 km out; the centre and everything near it is water.
        func ground(_ coordinate: CLLocationCoordinate2D) -> Bool {
            let metres = distance(coordinate)
            return metres >= 4_000 && metres <= 7_000
        }

        var bestProbe: [Int64: Int] = [:]
        var queue: [(MKCoordinateRegion, Int)] = [(ParkDiscoveryService.latticeCell(containing: centre), 0)]
        bestProbe[ParkDiscoveryService.latticeKey(queue[0].0)] = 0
        var hasFound = false
        var searched = 0
        var reachedThePlace = 0
        var cursor = 0

        while cursor < queue.count, searched < 2_000 {
            let (cell, probe) = queue[cursor]
            cursor += 1
            searched += 1

            let belongs = ground(cell.center)
            if belongs { hasFound = true; reachedThePlace += 1 }
            let next = (belongs || !hasFound) ? 0 : probe + 1
            guard next <= probeDepth else { continue }
            for neighbour in ParkDiscoveryService.latticeNeighbours(of: cell) {
                let key = ParkDiscoveryService.latticeKey(neighbour)
                if let seen = bestProbe[key], seen <= next { continue }
                guard ParkDiscoveryService.tile(
                    neighbour, intersectsCircleAround: centre, radiusMeters: 12_000
                ) else { continue }
                bestProbe[key] = next
                queue.append((neighbour, next))
            }
        }

        XCTAssertGreaterThan(reachedThePlace, 10, "The sweep has to cross the water and find the city")
    }

    /// A small city must cost what a small city is worth, even when its geocoded circle is
    /// enormous and its centre happens to hold no park.
    ///
    /// The seed hunt expands at full depth, and everything it queues keeps that depth — so
    /// without discarding the flood once the place is found, a city with twenty parks spent
    /// an entire budget three runs running.
    func testASmallCityInAWideCircleCostsLittle() {
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        func belongs(_ coordinate: CLLocationCoordinate2D) -> Bool {
            let metres = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: origin)
            // A city about 5 km across, which is roughly Sammamish.
            return metres <= 4_500
        }

        var bestProbe: [Int64: Int] = [:]
        var queue: [(MKCoordinateRegion, Int)] = [(ParkDiscoveryService.latticeCell(containing: centre), 0)]
        bestProbe[ParkDiscoveryService.latticeKey(queue[0].0)] = 0
        var hasFound = false
        var searched = 0
        var cursor = 0

        while cursor < queue.count, searched < 400 {
            let (cell, probe) = queue[cursor]
            cursor += 1
            searched += 1

            let isCity = belongs(cell.center)
            if isCity, !hasFound {
                hasFound = true
                queue.removeSubrange(cursor...)
                for (key, depth) in bestProbe where depth == 0 {
                    if key != ParkDiscoveryService.latticeKey(cell) { bestProbe.removeValue(forKey: key) }
                }
            }
            let next = (isCity || !hasFound) ? 0 : probe + 1
            guard next <= probeDepth else { continue }
            for neighbour in ParkDiscoveryService.latticeNeighbours(of: cell, includingDiagonals: next == 0) {
                let key = ParkDiscoveryService.latticeKey(neighbour)
                if let seen = bestProbe[key], seen <= next { continue }
                // A generous circle, as a real geocoded city radius is.
                guard ParkDiscoveryService.tile(
                    neighbour, intersectsCircleAround: centre, radiusMeters: 25_000
                ) else { continue }
                bestProbe[key] = next
                queue.append((neighbour, next))
            }
        }

        XCTAssertTrue(hasFound, "The city has to be found at all")
        XCTAssertLessThan(
            searched * 2,
            ParkDiscoveryService.maxIndexSearches,
            "A small city must not exhaust the budget just because its circle is wide"
        )
        print("PLAN small city in wide circle: \(searched) cells, \(searched * 2) requests")
    }

    /// The same route twice is not worth queueing twice.
    func testAWorseOrEqualRouteIsIgnored() {
        var bestProbe: [Int64: Int] = [:]
        var queued = 0

        func expand(probe: Int) {
            for neighbour in ParkDiscoveryService.latticeNeighbours(
                of: ParkDiscoveryService.latticeCell(containing: centre)
            ) {
                let key = ParkDiscoveryService.latticeKey(neighbour)
                if let seen = bestProbe[key], seen <= probe { continue }
                bestProbe[key] = probe
                queued += 1
            }
        }

        expand(probe: 0)
        let afterFirst = queued
        expand(probe: 0)
        expand(probe: probeDepth)
        XCTAssertEqual(queued, afterFirst, "Nothing was learnt, so nothing is queued")
    }
}

/// The allowance a sweep gets to find the place it was asked about, before deciding the
/// lookup was wrong rather than the ground empty.
final class SeedingBudgetTests: XCTestCase {

    /// Seattle's latitude, where a lattice cell is a third smaller than its degrees suggest.
    private let latitude = 47.6

    private func budget(radiusMiles: Double) -> Int {
        ParkDiscoveryService.seedingBudget(radiusMiles: radiusMiles, latitude: latitude)
    }

    /// A city's centre is not reliably inside it — there is a Sammamish next to a lake
    /// called Sammamish — so the allowance has to cross the city's own radius.
    func testACityCanReachAcrossItsOwnRadius() {
        let cellArea = ParkDiscoveryService.cellAreaSquareKilometres(atLatitude: latitude)
        // One request per cell, spreading from a point: the reach is the radius of the disc
        // the allowance buys.
        let reachKm = (Double(budget(radiusMiles: 5.5)) * cellArea / Double.pi).squareRoot()
        XCTAssertGreaterThanOrEqual(reachKm, 5.5 * 1.609, "It has to be able to reach the edge")
    }

    /// A county's can be forty miles of farmland first, and giving up there would report a
    /// real place as one the map could not find.
    func testACountyGetsAMuchLargerAllowance() {
        XCTAssertGreaterThan(budget(radiusMiles: 37), budget(radiusMiles: 1.5))
    }

    /// A cell is smaller away from the equator, so the same circle takes more of them.
    func testTheAllowanceFollowsHowBigACellActuallyIs() {
        XCTAssertGreaterThan(budget(radiusMiles: 3), ParkDiscoveryService.seedingBudget(radiusMiles: 3, latitude: 0))
    }

    /// However lost it gets, the hunt must leave something for the sweep it was starting.
    func testTheHuntNeverEatsTheWholeRun() {
        for radius in [1.0, 10.0, 40.0, 500.0] {
            XCTAssertLessThanOrEqual(budget(radiusMiles: radius), ParkDiscoveryService.maxIndexSearches / 2)
        }
    }
}
