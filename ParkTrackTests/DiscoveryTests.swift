import XCTest
import SwiftData
import CoreLocation
import MapKit
@testable import ParkTrack

/// Covers the pure pieces of discovery: what counts as a park, how a region is tiled,
/// and that re-seeing the same park collapses to one entry.
final class DiscoveryTests: XCTestCase {

    // MARK: - Park-like filter

    func testCategorisedParkIsKept() {
        XCTAssertTrue(ParkDiscoveryService.isParkLike(name: "Riverbend", category: .park))
        XCTAssertTrue(ParkDiscoveryService.isParkLike(name: "Great Basin", category: .nationalPark))
    }

    func testNonParkCategoriesAreDropped() {
        XCTAssertFalse(ParkDiscoveryService.isParkLike(name: "Park Avenue Diner", category: .restaurant))
        XCTAssertFalse(ParkDiscoveryService.isParkLike(name: "Park Place Market", category: .store))
        XCTAssertFalse(ParkDiscoveryService.isParkLike(name: "Central Park Garage", category: .parking))
        XCTAssertFalse(ParkDiscoveryService.isParkLike(name: "Parkview Elementary", category: .school))
    }

    func testUncategorisedResultsNeedAParkishName() {
        for name in ["Cedar Park", "The Commons", "Wetland Preserve", "Botanical Gardens",
                     "Ridge Trail", "North Playfield", "Hillside Arboretum", "Quiet Meadow",
                     "Old Woods", "Village Green"] {
            XCTAssertTrue(ParkDiscoveryService.isParkLike(name: name, category: nil), name)
        }
    }

    func testUncategorisedNonParkNamesAreDropped() {
        for name in ["Parking Garage", "Parkside Dental", "Riverside Apartments", "Main Street Deli"] {
            XCTAssertFalse(ParkDiscoveryService.isParkLike(name: name, category: nil), name)
        }
    }

    func testParkishNameIgnoresCaseAndDiacritics() {
        XCTAssertTrue(ParkDiscoveryService.isParkLike(name: "parc JARDÍN gardens", category: nil))
    }

    // MARK: - Tiling

    func testSmallSpanIsASingleTile() {
        let region = MKCoordinateRegion(
            center: .init(latitude: 10, longitude: 20),
            span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        let tiles = ParkDiscoveryService.tiles(for: region)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].span.latitudeDelta, 0.02, accuracy: 1e-9)
    }

    func testLargeSpanIsTiledUpToTheRequestCap() {
        let region = MKCoordinateRegion(
            center: .init(latitude: 10, longitude: 20),
            span: .init(latitudeDelta: 1.0, longitudeDelta: 1.0)
        )
        let tiles = ParkDiscoveryService.tiles(for: region, maxTiles: 16)
        XCTAssertEqual(tiles.count, 16)
        for tile in tiles {
            XCTAssertEqual(tile.span.latitudeDelta, 0.25, accuracy: 1e-9)
            XCTAssertEqual(tile.span.longitudeDelta, 0.25, accuracy: 1e-9)
        }
    }

    func testTilesCoverTheOriginalRegionExactly() {
        let region = MKCoordinateRegion(
            center: .init(latitude: -33.5, longitude: 151.2),
            span: .init(latitudeDelta: 0.8, longitudeDelta: 0.4)
        )
        let tiles = ParkDiscoveryService.tiles(for: region)
        let minLat = tiles.map { $0.center.latitude - $0.span.latitudeDelta / 2 }.min()!
        let maxLat = tiles.map { $0.center.latitude + $0.span.latitudeDelta / 2 }.max()!
        let minLon = tiles.map { $0.center.longitude - $0.span.longitudeDelta / 2 }.min()!
        let maxLon = tiles.map { $0.center.longitude + $0.span.longitudeDelta / 2 }.max()!
        XCTAssertEqual(minLat, region.center.latitude - 0.4, accuracy: 1e-9)
        XCTAssertEqual(maxLat, region.center.latitude + 0.4, accuracy: 1e-9)
        XCTAssertEqual(minLon, region.center.longitude - 0.2, accuracy: 1e-9)
        XCTAssertEqual(maxLon, region.center.longitude + 0.2, accuracy: 1e-9)
    }

    func testTilingNeverExceedsTheRequestCap() {
        let huge = MKCoordinateRegion(
            center: .init(latitude: 0, longitude: 0),
            span: .init(latitudeDelta: 40, longitudeDelta: 40)
        )
        XCTAssertLessThanOrEqual(ParkDiscoveryService.tiles(for: huge).count, ParkDiscoveryService.maxTilesPerScan)
        XCTAssertEqual(ParkDiscoveryService.tiles(for: huge, maxTiles: 4).count, 4)
    }

    func testDegenerateSpanStillYieldsOneTile() {
        let point = MKCoordinateRegion(
            center: .init(latitude: 5, longitude: 5),
            span: .init(latitudeDelta: 0, longitudeDelta: 0)
        )
        XCTAssertEqual(ParkDiscoveryService.tiles(for: point).count, 1)
    }

    // MARK: - Dedup

    func testDedupCollapsesTheSameParkSeenTwice() {
        let coordinate = CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33)
        let poiPass = makeCandidate(name: "Waterfront Park", coordinate: coordinate)
        let textPass = makeCandidate(name: "  waterfront park", coordinate: coordinate)
        let deduped = ParkDiscoveryService.deduped([poiPass, textPass])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].name, "Waterfront Park")
    }

    func testDedupKeepsDistinctParksThatShareAName() {
        let a = makeCandidate(name: "Memorial Park", coordinate: .init(latitude: 47.61, longitude: -122.33))
        let b = makeCandidate(name: "Memorial Park", coordinate: .init(latitude: -37.81, longitude: 144.96))
        XCTAssertEqual(ParkDiscoveryService.deduped([a, b]).count, 2)
    }

    func testDedupPreservesDiscoveryOrder() {
        let a = makeCandidate(name: "Alder Park", coordinate: .init(latitude: 1, longitude: 1))
        let b = makeCandidate(name: "Birch Park", coordinate: .init(latitude: 2, longitude: 2))
        let deduped = ParkDiscoveryService.deduped([a, b, a, b])
        XCTAssertEqual(deduped.map(\.name), ["Alder Park", "Birch Park"])
    }

    private func makeCandidate(name: String, coordinate: CLLocationCoordinate2D) -> ParkCandidate {
        ParkCandidate(
            id: Park.identity(name: name, coordinate: coordinate),
            name: name,
            coordinate: coordinate,
            category: nil,
            addressLine: nil
        )
    }
}

/// Covers the bookkeeping that decides whether a completion percentage is a real fraction
/// of a known total or only a floor: how a sweep is planned, and what ground it may then
/// claim to have searched. A mistake here shows up as a ring quoting a confident number
/// over land nothing ever looked at.
final class SweepCoverageTests: XCTestCase {
    private let center = CLLocationCoordinate2D(latitude: 12.5, longitude: 34.5)
    private let radii: [Double] = [2.5, 5, 10]

    // MARK: - Planning

    func testTheFirstLevelIsASingleRequest() {
        let levels = ParkDiscoveryService.sweepLevels(around: center, radiusMiles: 10)
        XCTAssertEqual(levels.first?.tiles.count, 1)
    }

    func testEveryLaterLevelDropsTheTileTheLevelBelowAlreadySearched() {
        let levels = ParkDiscoveryService.sweepLevels(around: center, radiusMiles: 10)
        XCTAssertGreaterThan(levels.count, 1)
        for level in levels.dropFirst() {
            XCTAssertEqual(level.tiles.count, 8)
        }
    }

    func testLevelsWidenStrictlyOutward() {
        let spans = ParkDiscoveryService.sweepLevels(around: center, radiusMiles: 25)
            .map(\.square.span.latitudeDelta)
        XCTAssertEqual(spans, spans.sorted())
        XCTAssertEqual(Set(spans).count, spans.count)
    }

    func testTheLastLevelCoversTheRingItWasAskedAbout() {
        for radius in radii + [0.5, 25] {
            let levels = ParkDiscoveryService.sweepLevels(around: center, radiusMiles: radius)
            guard let last = levels.last else { return XCTFail("no plan for \(radius)") }
            let ring = ParkDiscoveryService.boundingSquare(around: center, radiusMiles: radius)
            XCTAssertTrue(SweptCoverage.region(last.square, covers: ring), "\(radius) mi")
        }
    }

    /// A level's own tiles plus the level below it must leave no gap, or the sweep would
    /// record ground it never searched.
    func testALevelsTilesReachTheEdgesOfThatLevel() {
        let levels = ParkDiscoveryService.sweepLevels(around: center, radiusMiles: 25)
        for level in levels.dropFirst() {
            let minLat = level.tiles.map { $0.center.latitude - $0.span.latitudeDelta / 2 }.min()!
            let maxLat = level.tiles.map { $0.center.latitude + $0.span.latitudeDelta / 2 }.max()!
            let minLon = level.tiles.map { $0.center.longitude - $0.span.longitudeDelta / 2 }.min()!
            let maxLon = level.tiles.map { $0.center.longitude + $0.span.longitudeDelta / 2 }.max()!
            XCTAssertEqual(minLat, level.square.center.latitude - level.square.span.latitudeDelta / 2, accuracy: 1e-9)
            XCTAssertEqual(maxLat, level.square.center.latitude + level.square.span.latitudeDelta / 2, accuracy: 1e-9)
            XCTAssertEqual(minLon, level.square.center.longitude - level.square.span.longitudeDelta / 2, accuracy: 1e-9)
            XCTAssertEqual(maxLon, level.square.center.longitude + level.square.span.longitudeDelta / 2, accuracy: 1e-9)
        }
    }

    func testATinyRingIsOneLevelOfOneTile() {
        let levels = ParkDiscoveryService.sweepLevels(around: center, radiusMiles: 0.1)
        XCTAssertEqual(levels.count, 1)
        XCTAssertEqual(levels.first?.tiles.count, 1)
    }

    func testAnAbsurdRadiusStillPlansAFiniteNumberOfRequests() {
        let levels = ParkDiscoveryService.sweepLevels(around: center, radiusMiles: 5_000)
        XCTAssertLessThanOrEqual(levels.count, ParkDiscoveryService.maxSweepLevels)
        XCTAssertLessThanOrEqual(levels.reduce(0) { $0 + $1.tiles.count }, 1 + 8 * ParkDiscoveryService.maxSweepLevels)
    }

    func testNonsenseInputPlansNothing() {
        XCTAssertTrue(ParkDiscoveryService.sweepLevels(around: center, radiusMiles: .nan).isEmpty)
        XCTAssertTrue(ParkDiscoveryService.sweepLevels(around: center, radiusMiles: .infinity).isEmpty)
        let offGlobe = CLLocationCoordinate2D(latitude: 200, longitude: 400)
        XCTAssertTrue(ParkDiscoveryService.sweepLevels(around: offGlobe, radiusMiles: 5).isEmpty)
    }

    // MARK: - Coverage bookkeeping

    func testNothingIsSweptBeforeASweepRuns() {
        let coverage = SweptCoverage()
        for radius in radii {
            XCTAssertFalse(coverage.covers(center: center, radiusMiles: radius))
        }
    }

    /// The square a level records and the square a ring asks about are both rebuilt from
    /// metres, so this is the round-trip that decides whether a finished sweep is ever
    /// recognised as finished.
    func testRecordingARingsOwnSquareMarksThatRingSwept() {
        for radius in radii + [0.5, 7.25, 25, 37.5] {
            var coverage = SweptCoverage()
            coverage.record(ParkDiscoveryService.boundingSquare(around: center, radiusMiles: radius))
            XCTAssertTrue(coverage.covers(center: center, radiusMiles: radius), "\(radius) mi")
        }
    }

    func testASweptRingSaysNothingAboutAWiderOne() {
        var coverage = SweptCoverage()
        coverage.record(ParkDiscoveryService.boundingSquare(around: center, radiusMiles: 5))
        XCTAssertTrue(coverage.covers(center: center, radiusMiles: 2.5))
        XCTAssertFalse(coverage.covers(center: center, radiusMiles: 10))
    }

    func testCoverageIsTiedToWhereTheSweepHappened() {
        var coverage = SweptCoverage()
        coverage.record(ParkDiscoveryService.boundingSquare(around: center, radiusMiles: 10))
        let elsewhere = CLLocationCoordinate2D(latitude: center.latitude + 5, longitude: center.longitude + 5)
        XCTAssertFalse(coverage.covers(center: elsewhere, radiusMiles: 2.5))
    }

    func testDegenerateRegionsAreNeitherRecordedNorCovered() {
        let point = MKCoordinateRegion(
            center: center,
            span: .init(latitudeDelta: 0, longitudeDelta: 0)
        )
        var coverage = SweptCoverage()
        coverage.record(point)
        XCTAssertFalse(coverage.covers(center: center, radiusMiles: 2.5))

        coverage.record(ParkDiscoveryService.boundingSquare(around: center, radiusMiles: 10))
        XCTAssertFalse(coverage.covers(point))
        XCTAssertFalse(coverage.covers(MKCoordinateRegion(
            center: center,
            span: .init(latitudeDelta: .nan, longitudeDelta: .nan)
        )))
    }

    /// Rings narrower than the widest one swept must stay swept, however many squares the
    /// user's wandering has pushed through the list since.
    func testAWanderingUserNeverLosesGroundAlreadySwept() {
        var coverage = SweptCoverage()
        coverage.record(ParkDiscoveryService.boundingSquare(around: center, radiusMiles: 10))
        for step in 1...40 {
            let away = CLLocationCoordinate2D(latitude: center.latitude + Double(step), longitude: center.longitude)
            coverage.record(ParkDiscoveryService.boundingSquare(around: away, radiusMiles: 1))
        }
        XCTAssertTrue(coverage.covers(center: center, radiusMiles: 10))
    }

    // MARK: - Plan and bookkeeping together

    /// The whole point of the two halves: walking the plan marks every ring the user asked
    /// about as swept, and the narrow rings get there before the wide ones do — which is
    /// what lets Home show a settled percentage nearby while it is still searching further out.
    func testWalkingThePlanSweepsNarrowRingsBeforeWideOnes() {
        var coverage = SweptCoverage()
        var sweptAtLevel: [Double: Int] = [:]

        for (index, level) in ParkDiscoveryService.sweepLevels(around: center, radiusMiles: 10).enumerated() {
            coverage.record(level.square)
            for radius in radii where sweptAtLevel[radius] == nil && coverage.covers(center: center, radiusMiles: radius) {
                sweptAtLevel[radius] = index
            }
        }

        XCTAssertEqual(sweptAtLevel.count, radii.count, "every requested ring should end up swept")
        XCTAssertLessThan(sweptAtLevel[2.5]!, sweptAtLevel[10]!)
        XCTAssertLessThanOrEqual(sweptAtLevel[5]!, sweptAtLevel[10]!)
    }

    func testASkippedLevelIsOneAlreadySwept() {
        let levels = ParkDiscoveryService.sweepLevels(around: center, radiusMiles: 10)
        var coverage = SweptCoverage()
        for level in levels { coverage.record(level.square) }
        for level in levels {
            XCTAssertTrue(coverage.covers(level.square))
        }
    }
}

/// `MKLocalSearch` treats a search region as a hint rather than a bound, so discovery has to
/// decide for itself which results landed on the ground it actually searched.
final class SearchRegionBoundsTests: XCTestCase {
    private let square = MKCoordinateRegion(
        center: .init(latitude: 12.5, longitude: 34.5),
        span: .init(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )

    func testAResultInsideTheSearchedSquareIsKept() {
        XCTAssertTrue(SweptCoverage.region(square, contains: .init(latitude: 12.5, longitude: 34.5)))
        XCTAssertTrue(SweptCoverage.region(square, contains: .init(latitude: 12.55, longitude: 34.45)))
    }

    func testAResultOnTheEdgeCounts() {
        XCTAssertTrue(SweptCoverage.region(square, contains: .init(latitude: 12.6, longitude: 34.6)))
        XCTAssertTrue(SweptCoverage.region(square, contains: .init(latitude: 12.4, longitude: 34.4)))
    }

    func testAResultTheMapVolunteeredFromFarAwayIsDropped() {
        XCTAssertFalse(SweptCoverage.region(square, contains: .init(latitude: 12.5, longitude: 44.5)))
        XCTAssertFalse(SweptCoverage.region(square, contains: .init(latitude: 22.5, longitude: 34.5)))
        XCTAssertFalse(SweptCoverage.region(square, contains: .init(latitude: 12.5, longitude: 34.61)))
    }

    func testNonsenseCoordinatesAreDropped() {
        XCTAssertFalse(SweptCoverage.region(square, contains: .init(latitude: .nan, longitude: 34.5)))
        XCTAssertFalse(SweptCoverage.region(square, contains: .init(latitude: 200, longitude: 400)))
    }

    func testADegenerateSearchRegionKeepsNothing() {
        let point = MKCoordinateRegion(
            center: square.center,
            span: .init(latitudeDelta: 0, longitudeDelta: 0)
        )
        XCTAssertFalse(SweptCoverage.region(point, contains: square.center))
    }

    /// Every tile a level searches sits inside that level's square, so tile results survive
    /// the filter the level applies to them.
    func testEverySweepTileSitsInsideTheLevelItBelongsTo() {
        let center = CLLocationCoordinate2D(latitude: 12.5, longitude: 34.5)
        for level in ParkDiscoveryService.sweepLevels(around: center, radiusMiles: 10) {
            for tile in level.tiles {
                XCTAssertTrue(SweptCoverage.region(level.square, covers: tile))
                XCTAssertTrue(SweptCoverage.region(level.square, contains: tile.center))
            }
        }
    }
}

/// Searched ground is cached like the parks in it, and survives a relaunch. Before this the
/// map forgot everywhere it had looked each time the app started.
@MainActor
final class ScannedAreaPersistenceTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = PersistenceController.makeInMemoryContainer()
    }

    private func region(lat: Double, lon: Double, span: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
    }

    func testCoverageSurvivesANewService() {
        let context = ModelContext(container)
        let first = ParkDiscoveryService(modelContext: context)
        let area = region(lat: 47.6, lon: -122.2, span: 0.1)
        XCTAssertFalse(first.hasSwept(region: area))

        first.noteScanned(region: area)
        XCTAssertTrue(first.hasSwept(region: area))

        // A new service is what a relaunch produces.
        let second = ParkDiscoveryService(modelContext: ModelContext(container))
        XCTAssertTrue(second.hasSwept(region: area), "A relaunch must not forget where it has searched")
    }

    func testASmallPanOverScannedGroundIsNotRescanned() {
        let service = ParkDiscoveryService(modelContext: ModelContext(container))
        service.noteScanned(region: region(lat: 47.6, lon: -122.2, span: 0.2))

        // Nudged a little, well inside the ground already covered.
        let nudged = region(lat: 47.605, lon: -122.205, span: 0.05)
        XCTAssertTrue(service.isLargelySwept(region: nudged))
    }

    func testGroundStraddlingTwoScansCounts() {
        let service = ParkDiscoveryService(modelContext: ModelContext(container))
        service.noteScanned(region: region(lat: 47.60, lon: -122.20, span: 0.2))
        service.noteScanned(region: region(lat: 47.60, lon: -122.05, span: 0.2))

        // Sits across the seam between the two, inside neither alone.
        let straddling = region(lat: 47.60, lon: -122.125, span: 0.04)
        XCTAssertTrue(service.isLargelySwept(region: straddling), "Adjacent passes should cover the seam between them")
    }

    func testUnsearchedGroundStillNeedsAScan() {
        let service = ParkDiscoveryService(modelContext: ModelContext(container))
        service.noteScanned(region: region(lat: 47.6, lon: -122.2, span: 0.1))
        XCTAssertFalse(service.isLargelySwept(region: region(lat: 45.5, lon: -122.6, span: 0.1)))
    }
}
