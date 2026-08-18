import XCTest
import CoreLocation
import MapKit
import SwiftData
@testable import ParkTrack

/// Indexes one real city end to end and prints what it cost and what it found.
///
/// This is the reproduction for "indexing Sammamish doesn't work". Before the per-cell
/// search was bounded to the cell it asks about, this searched seventy-six cells, saved zero
/// parks and reported that the map could not find the place.
///
/// Opt-in, because it spends a couple of hundred real searches against a rate limit shared
/// with whatever the developer's own phone is doing:
///
///     TEST_RUNNER_PARKTRACK_LIVE_PROBES=1 xcodebuild ... -only-testing:ParkTrackTests/CityIndexProbe test
@MainActor
final class CityIndexProbe: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PARKTRACK_LIVE_PROBES"] == "1", "opt-in")
    }

    /// Sammamish's own numbers, as the geocoder gives them.
    func testRealSammamishSweep() async throws {
        let centre = CLLocationCoordinate2D(latitude: 47.6017576, longitude: -122.0356084)
        let radiusMeters: CLLocationDistance = 7662.4

        let container = PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let service = ParkDiscoveryService(modelContext: context)

        let cells = CellCounter()
        let start = Date()
        let result = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMeters / Format.metersPerMile,
            belongsToRegion: { RegionIndex.place(kind: .city, park: $0, isNamed: "Sammamish") },
            searchCell: { cell in
                await cells.bump()
                return await ParkDiscoveryService.indexCandidates(in: cell)
            }
        )
        let searched = await cells.value
        let all = (try? context.fetch(FetchDescriptor<Park>())) ?? []
        let inCity = all.filter { RegionIndex.place(kind: .city, park: $0, isNamed: "Sammamish") }
        print("VERIFY requests=\(searched) seconds=\(Int(Date().timeIntervalSince(start))) completed=\(result.completed) truncated=\(result.truncated) saved=\(all.count) inSammamish=\(inCity.count) error=\(service.lastError ?? "none")")
        for park in inCity.sorted(by: { $0.name < $1.name }) {
            print("VERIFY   \(park.name) [\(park.locality ?? "nil")]")
        }
        let others = Set(all.compactMap(\.locality)).sorted()
        print("VERIFY otherLocalities=\(others.joined(separator: ", "))")
    }
}
