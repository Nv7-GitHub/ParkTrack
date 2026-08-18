import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

/// A region sheet left open across a sweep has to show what the sweep found.
@MainActor
final class RegionProgressLivenessTests: XCTestCase {

    private func park(_ name: String, city: String, visited: Bool = false) -> Park {
        let park = Park(identifier: name, name: name, latitude: 47.6, longitude: -122.0)
        park.locality = city
        park.administrativeArea = "WA"
        if visited { park.visits = [Visit(date: Date())] }
        return park
    }

    private func snapshot(of parks: [Park], name: String) -> RegionCompletion {
        let visited = parks.filter(\.isVisited)
        return RegionCompletion(
            name: name,
            visited: visited.count,
            total: parks.count,
            fraction: parks.isEmpty ? 0 : Double(visited.count) / Double(parks.count),
            remaining: parks.filter { !$0.isVisited },
            visitedParks: visited,
            identifier: RegionIndex.identity(kind: .city, name: name, container: "WA"),
            kind: .city
        )
    }

    /// The reported bug: the count came right when the sweep finished, and "Still to go"
    /// stayed exactly as it was when the sheet opened.
    func testParksFoundAfterTheSheetOpenedAppearInStillToGo() {
        let atOpen = [park("Pine Lake Park", city: "Sammamish")]
        let opened = snapshot(of: atOpen, name: "Sammamish")
        XCTAssertEqual(opened.remaining.count, 1)

        // The sweep runs and finds two more.
        let afterSweep = atOpen + [
            park("Beaver Lake Park", city: "Sammamish"),
            park("Klahanie Park", city: "Sammamish")
        ]

        let live = RegionCompletion.rebuilt(from: opened, parks: afterSweep, index: nil)
        XCTAssertEqual(live.remaining.count, 3, "the list the user is looking at never grew")
        XCTAssertEqual(live.remaining.map(\.name), ["Beaver Lake Park", "Klahanie Park", "Pine Lake Park"])
        XCTAssertEqual(live.total, 3)
    }

    /// Logging a visit while the sheet is open moves the park across, both ways.
    func testVisitingAParkMovesItOutOfStillToGo() {
        let unvisited = [park("Pine Lake Park", city: "Sammamish"), park("Dalton Park", city: "Sammamish")]
        let opened = snapshot(of: unvisited, name: "Sammamish")
        XCTAssertEqual(opened.visited, 0)

        let afterVisit = [park("Pine Lake Park", city: "Sammamish", visited: true),
                          park("Dalton Park", city: "Sammamish")]
        let live = RegionCompletion.rebuilt(from: opened, parks: afterVisit, index: nil)

        XCTAssertEqual(live.visited, 1)
        XCTAssertEqual(live.remaining.map(\.name), ["Dalton Park"])
        XCTAssertEqual(live.visitedParks.map(\.name), ["Pine Lake Park"])
        XCTAssertEqual(live.fraction, 0.5, accuracy: 0.001)
    }

    /// Parks in the town next door must not leak into this one's list.
    func testOnlyThisPlacesParksCount() {
        let opened = snapshot(of: [park("Pine Lake Park", city: "Sammamish")], name: "Sammamish")
        let mixed = [park("Pine Lake Park", city: "Sammamish"), park("Marymoor Park", city: "Redmond")]

        let live = RegionCompletion.rebuilt(from: opened, parks: mixed, index: nil)
        XCTAssertEqual(live.remaining.map(\.name), ["Pine Lake Park"])
    }

    /// The index's total still wins when it knows more than has been found.
    func testAnIndexedTotalOutranksWhatHasBeenFound() {
        let opened = snapshot(of: [park("Pine Lake Park", city: "Sammamish")], name: "Sammamish")
        let record = RegionIndex(
            identifier: opened.identifier, kind: .city, name: "Sammamish", container: "WA",
            country: "United States", center: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.0),
            radiusMeters: 7_662
        )
        record.parkCount = 12
        record.indexedAt = Date()
        record.indexerVersion = RegionIndex.currentIndexerVersion

        let live = RegionCompletion.rebuilt(
            from: opened,
            parks: [park("Pine Lake Park", city: "Sammamish")],
            index: record
        )
        XCTAssertEqual(live.total, 12)
        XCTAssertTrue(live.isIndexed)
    }

    /// If nothing matches, keep showing what the sheet was opened with rather than blanking.
    func testAnEmptyMatchFallsBackToTheSnapshot() {
        let opened = snapshot(of: [park("Pine Lake Park", city: "Sammamish")], name: "Sammamish")
        let live = RegionCompletion.rebuilt(from: opened, parks: [], index: nil)
        XCTAssertEqual(live.remaining.count, 1)
    }
}
