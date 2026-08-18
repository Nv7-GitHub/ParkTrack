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

/// Resuming only works if the two runs cut the ground the same way.
///
/// Swept ground is matched by containment, so a tile grid that has shifted even slightly
/// lines up with nothing that was searched before. The grid comes from a region's centre
/// and radius, which is why those are settled once and then kept.
@MainActor
final class IndexGridStabilityTests: XCTestCase {

    private let centre = CLLocationCoordinate2D(latitude: 37.7599, longitude: -122.4370)
    private let radiusMiles = 8.0

    /// Every leaf a run would search, mirroring what `sweepDense` does when everything
    /// saturates — which, measured against the live map, is what happens in a city.
    private func leaves(around coordinate: CLLocationCoordinate2D, radiusMiles: Double) -> [MKCoordinateRegion] {
        let square = ParkDiscoveryService.indexSquare(around: coordinate, radiusMiles: radiusMiles)
        let sideMeters = radiusMiles * 2 * Format.metersPerMile
        var queue = ParkDiscoveryService.tiles(
            for: square,
            side: max(1, Int((sideMeters / ParkDiscoveryService.coarseTileMeters).rounded(.up)))
        )
        var leaves: [MKCoordinateRegion] = []
        while let tile = queue.first {
            queue.removeFirst()
            if let side = ParkDiscoveryService.splitSide(for: tile) {
                queue.append(contentsOf: ParkDiscoveryService.tiles(for: tile, side: side))
            } else {
                leaves.append(tile)
            }
        }
        return leaves
    }

    private func covered(_ tiles: [MKCoordinateRegion], by coverage: SweptCoverage) -> Int {
        tiles.filter { coverage.coversFinely($0, resolution: $0.span.latitudeDelta) }.count
    }

    func testTheSameRegionProducesTheSameGridEveryTime() {
        let first = leaves(around: centre, radiusMiles: radiusMiles)
        let second = leaves(around: centre, radiusMiles: radiusMiles)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.center.latitude, b.center.latitude)
            XCTAssertEqual(a.center.longitude, b.center.longitude)
            XCTAssertEqual(a.span.latitudeDelta, b.span.latitudeDelta)
        }
    }

    /// The whole point: a second attempt skips everything the first one finished.
    func testAResumedRunSkipsEveryTileTheFirstRunFinished() {
        var coverage = SweptCoverage()
        let first = leaves(around: centre, radiusMiles: radiusMiles)
        // Half a run, then the app dies.
        let done = Array(first.prefix(first.count / 2))
        for tile in done {
            coverage.record(tile, resolution: tile.span.latitudeDelta)
        }

        var restored = SweptCoverage()
        restored.restore(coverage.bounds)

        let second = leaves(around: centre, radiusMiles: radiusMiles)
        XCTAssertEqual(
            covered(second, by: restored),
            done.count,
            "A resumed run has to skip exactly what the first one finished"
        )
    }

    /// The regression this guards: the centre used to be re-derived from the geocoder on
    /// every attempt, and `CLGeocoder` does not answer identically twice. A few metres is
    /// all it takes.
    func testACentreThatMovesAFewMetresThrowsAwayEveryFinishedTile() {
        var coverage = SweptCoverage()
        for tile in leaves(around: centre, radiusMiles: radiusMiles) {
            coverage.record(tile, resolution: tile.span.latitudeDelta)
        }

        // Roughly five metres north — well inside the noise of a place lookup.
        let drifted = CLLocationCoordinate2D(
            latitude: centre.latitude + 0.00005,
            longitude: centre.longitude
        )
        let shifted = leaves(around: drifted, radiusMiles: radiusMiles)

        XCTAssertEqual(
            covered(shifted, by: coverage),
            0,
            "This is what made a resumed index start from nothing"
        )
    }

    /// …and the radius matters just as much as the centre.
    func testARadiusThatMovesThrowsAwayEveryFinishedTile() {
        var coverage = SweptCoverage()
        for tile in leaves(around: centre, radiusMiles: radiusMiles) {
            coverage.record(tile, resolution: tile.span.latitudeDelta)
        }

        let shifted = leaves(around: centre, radiusMiles: radiusMiles + 0.05)
        XCTAssertEqual(covered(shifted, by: coverage), 0)
    }
}

/// How finely a saturated tile is cut.
///
/// Measured against the real map service: `MKLocalSearch` caps every answer at about 25
/// results however wide the region, so any populated tile above a couple of kilometres
/// saturates — every tile at every level did, over a dense city and a suburb alike. So the
/// intermediate steps of a halving search are requests spent confirming what is already
/// known, and skipping them is what lets a large city finish inside its budget.
final class TileSplittingTests: XCTestCase {

    private func region(spanDegrees: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.42),
            span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
        )
    }

    /// Roughly the 26 km tile a sweep starts from.
    func testAWideTileIsCutAsFinelyAsAllowed() {
        XCTAssertEqual(ParkDiscoveryService.splitSide(for: region(spanDegrees: 0.234)), 4)
    }

    /// A tile whose children would fall below the useful minimum is left alone.
    func testATileNearTheMinimumIsNotCut() {
        XCTAssertNil(ParkDiscoveryService.splitSide(for: region(spanDegrees: 0.0147)))
        XCTAssertNil(ParkDiscoveryService.splitSide(for: region(spanDegrees: ParkDiscoveryService.minimumTileSpanDegrees)))
    }

    /// Whatever the cut, no child may come out smaller than the floor — that is the line
    /// past which a tile is smaller than the parks in it.
    func testChildrenNeverFallBelowTheMinimum() {
        for span in stride(from: 0.028, through: 0.5, by: 0.004) {
            guard let side = ParkDiscoveryService.splitSide(for: region(spanDegrees: span)) else { continue }
            let childSpan = span / Double(side)
            XCTAssertGreaterThanOrEqual(
                childSpan,
                ParkDiscoveryService.minimumTileSpanDegrees * 0.999,
                "A \(span)° tile cut \(side) ways gives \(childSpan)° children"
            )
        }
    }

    /// The point of the change: a city reaches the same final resolution in far fewer
    /// requests, and inside the budget it used to blow through.
    func testACityFitsInsideTheSearchBudget() {
        var queue = [region(spanDegrees: 0.234)]
        var requests = 0
        var finest = Double.greatestFiniteMagnitude

        // Everything saturates, which is what the live probe measured.
        while let tile = queue.first {
            queue.removeFirst()
            requests += 1
            finest = min(finest, tile.span.latitudeDelta)
            guard let side = ParkDiscoveryService.splitSide(for: tile) else { continue }
            queue.append(contentsOf: ParkDiscoveryService.tiles(for: tile, side: side))
        }

        XCTAssertLessThanOrEqual(
            requests,
            ParkDiscoveryService.maxIndexSearches,
            "A city has to be able to finish, not just resume forever"
        )
        XCTAssertLessThanOrEqual(finest, ParkDiscoveryService.minimumTileSpanDegrees * 1.1,
                                 "…and still reach full resolution")
    }
}
