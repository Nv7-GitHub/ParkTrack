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

        let fromElsewhere = ParkDiscoveryService.latticeCell(
            containing: CLLocationCoordinate2D(
                latitude: centre.latitude + 0.0001,
                longitude: centre.longitude + 0.0001
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

    /// Models the sweep offline: grow from the centre, treat `isInPlace` as what the map
    /// would say, and count the cells that would actually be searched.
    private func cellsSearched(
        radiusMeters: CLLocationDistance,
        isInPlace: (CLLocationCoordinate2D) -> Bool
    ) -> Int {
        var queue: [(MKCoordinateRegion, Int)] = [(cell(centre), 0)]
        var visited: Set<Int64> = [ParkDiscoveryService.latticeKey(queue[0].0)]
        var searched = 0

        while let (current, probe) = queue.first {
            queue.removeFirst()
            searched += 1
            let belongs = isInPlace(current.center)
            let nextProbe = belongs ? 0 : probe + 1
            guard nextProbe <= ParkDiscoveryService.regionProbeDepth else { continue }
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
                .distance(from: origin) <= cityRadius
        }
        // What filling the circle costs, which is what the sweep used to do.
        let wholeCircle = cellsSearched(radiusMeters: geocodedRadius) { _ in true }

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
            return distance <= 2_000 || (distance >= 4_000 && distance <= 6_000)
        }
        let nearSideOnly = cellsSearched(radiusMeters: 30_000) { metres($0) <= 2_000 }

        XCTAssertGreaterThan(reached, nearSideOnly, "The far bank has to be reached across the channel")
    }

    /// …but not so far that it wanders into the next town.
    func testASweepStopsAtALargeGap() {
        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        let reached = cellsSearched(radiusMeters: 30_000) { coordinate in
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: origin) <= 2_000
        }
        XCTAssertLessThan(reached, 120, "A sweep must not keep going once the place has ended")
    }
}

