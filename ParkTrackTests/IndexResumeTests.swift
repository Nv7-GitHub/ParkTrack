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
