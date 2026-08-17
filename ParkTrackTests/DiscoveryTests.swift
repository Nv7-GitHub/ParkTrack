import XCTest
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
