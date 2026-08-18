import XCTest
import CoreLocation
import MapKit
@testable import ParkTrack

/// How much a search actually gives you, per request, at different region sizes.
///
/// The index cuts the world into 1.5 km cells and throws away any result that lands outside
/// the cell it asked about. Browsing the map asks about whole screens. If `MKLocalSearch`
/// treats the region as a hint — biasing towards it rather than bounding by it — then a tiny
/// region gets the same wide answer as a large one, and confining it discards nearly all of
/// it. That would make small cells strictly worse per request, which is the opposite of what
/// the index assumes.
final class CellSizeProbe: XCTestCase {

    private let centre = CLLocationCoordinate2D(latitude: 47.6139, longitude: -122.2017)

    private func region(_ centre: CLLocationCoordinate2D, spanDegrees: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: centre,
            span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
        )
    }

    private func search(_ region: MKCoordinateRegion, filtered: Bool) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "park"
        request.region = region
        request.resultTypes = .pointOfInterest
        if filtered {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .nationalPark])
        }
        return (try? await SearchThrottle.shared.run(request))?.mapItems ?? []
    }

    private func isInside(_ coordinate: CLLocationCoordinate2D, _ region: MKCoordinateRegion) -> Bool {
        abs(coordinate.latitude - region.center.latitude) <= region.span.latitudeDelta / 2
            && abs(coordinate.longitude - region.center.longitude) <= region.span.longitudeDelta / 2
    }

    /// Covers one fixed patch of Bellevue at several cell sizes and compares the yield.
    func testYieldPerRequestByCellSize() async throws {
        // About 6 km square, so every size below covers exactly the same ground.
        let patch = region(centre, spanDegrees: 0.054)

        for side in [4, 2, 1] {
            let step = patch.span.latitudeDelta / Double(side)
            var requests = 0
            var rawItems = 0
            var insideKept: Set<String> = []
            var droppedOutside: Set<String> = []

            for tile in ParkDiscoveryService.tiles(for: patch, side: side) {
                for filtered in [true, false] {
                    let items = await search(tile, filtered: filtered)
                    requests += 1
                    rawItems += items.count
                    for item in items {
                        guard let name = item.name,
                              ParkDiscoveryService.isParkLike(name: name, category: item.pointOfInterestCategory)
                        else { continue }
                        let coordinate = item.placemark.coordinate
                        guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
                        let key = Park.identity(name: name, coordinate: coordinate)
                        // The sweep keeps only what lands in the cell it asked about.
                        if isInside(coordinate, tile) {
                            insideKept.insert(key)
                        } else if isInside(coordinate, patch) {
                            droppedOutside.insert(key)
                        }
                    }
                }
            }

            let kept = insideKept.count
            print(String(
                format: "PROBE cell=%5.2fkm tiles=%2d requests=%3d rawItems=%4d kept=%3d droppedButInPatch=%3d perRequest=%.2f",
                step * 111.0, side * side, requests, rawItems, kept,
                droppedOutside.subtracting(insideKept).count,
                requests > 0 ? Double(kept) / Double(requests) : 0
            ))
        }
    }
}
