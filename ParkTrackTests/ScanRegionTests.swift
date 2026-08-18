import XCTest
import MapKit
import CoreLocation
@testable import ParkTrack

/// The two ways a scan used to lie about ground it had not searched.
final class ScanRegionTests: XCTestCase {

    private func region(span: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6163, longitude: -122.0356),
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
    }

    /// A zoomed-in view is below the size the map will answer about, so asking about it
    /// returns the device's own surroundings and every result is then discarded.
    func testAZoomedInScanIsWidenedToSomethingTheMapWillAnswer() {
        for span in [0.004, 0.01, 0.03, 0.05] {
            let asked = ParkDiscoveryService.scannableRegion(region(span: span))
            XCTAssertGreaterThanOrEqual(asked.span.latitudeDelta, ParkDiscoveryService.wideTileSpanDegrees, "\(span)")
            XCTAssertGreaterThanOrEqual(asked.span.longitudeDelta, ParkDiscoveryService.wideTileSpanDegrees, "\(span)")
        }
    }

    /// …and a view already large enough is left exactly as it is.
    func testAWideScanIsNotTouched() {
        let wide = region(span: 0.4)
        let asked = ParkDiscoveryService.scannableRegion(wide)
        XCTAssertEqual(asked.span.latitudeDelta, 0.4, accuracy: 1e-12)
        XCTAssertEqual(asked.center.latitude, wide.center.latitude, accuracy: 1e-12)
    }

    /// Widening keeps the screen in view rather than sliding off it.
    func testWideningKeepsTheOriginalGroundInside() {
        let asked = ParkDiscoveryService.scannableRegion(region(span: 0.01))
        XCTAssertTrue(SweptCoverage.region(asked, covers: region(span: 0.01)))
    }

    /// The tiles the index's text pass uses are never below what the map will answer about.
    func testWideTilesAreNeverTooSmallToBeAnswered() {
        for span in [0.02, 0.06, 0.2, 1.0, 4.0] {
            let tiles = ParkDiscoveryService.wideTiles(covering: region(span: span))
            XCTAssertFalse(tiles.isEmpty, "\(span)")
            XCTAssertLessThanOrEqual(tiles.count, ParkDiscoveryService.maxWideTiles, "\(span)")
            for tile in tiles {
                XCTAssertGreaterThanOrEqual(
                    max(tile.span.latitudeDelta, tile.span.longitudeDelta),
                    ParkDiscoveryService.wideTileSpanDegrees * 0.999,
                    "a \(span)° region produced a tile the map will not answer about"
                )
            }
        }
    }

    /// A small region is one tile, not a grid of slivers.
    func testASmallRegionIsASingleWideTile() {
        XCTAssertEqual(ParkDiscoveryService.wideTiles(covering: region(span: 0.02)).count, 1)
    }

    /// A county gets a coarse grid rather than hundreds of requests.
    func testAHugeRegionIsCapped() {
        let tiles = ParkDiscoveryService.wideTiles(covering: region(span: 6.0))
        XCTAssertLessThanOrEqual(tiles.count, ParkDiscoveryService.maxWideTiles)
        XCTAssertGreaterThan(tiles.count, 1)
    }
}
