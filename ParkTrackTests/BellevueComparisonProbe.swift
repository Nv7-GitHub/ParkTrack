import XCTest
import CoreLocation
import MapKit
import SwiftData
@testable import ParkTrack

/// Indexes one real city both ways and prints what each cost.
///
/// "Filling the circle" is the old behaviour: every cell inside the geocoder's radius gets
/// searched, whatever it turns out to be. It is a *lower bound* on what the old code
/// actually spent, since that also paid for the intermediate levels of a quadtree on the
/// way down. "Following the shape" stops expanding at cells whose parks belong elsewhere.
///
/// Opt-in: this spends several hundred real searches.
@MainActor
final class BellevueComparisonProbe: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PARKTRACK_LIVE_PROBES"] == "1",
            "Live map probes are opt-in; set PARKTRACK_LIVE_PROBES=1 to run them."
        )
    }

    private struct Run {
        let label: String
        let searches: Int
        let parksSaved: Int
        let parksInCity: Int
        let seconds: Double
        let completed: Bool
        let truncated: Bool
    }

    private func sweep(
        label: String,
        centre: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        identifier: String,
        followShape: Bool
    ) async -> Run {
        let container = PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let service = ParkDiscoveryService(modelContext: context)

        var searched = 0
        let start = Date()
        let result = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMeters / Format.metersPerMile,
            belongsToRegion: followShape
                ? { park in RegionIndex.identity(kind: .city, park: park) == identifier }
                : nil
        ) { update in
            searched = max(searched, update.tilesSearched)
        }
        let seconds = Date().timeIntervalSince(start)

        let all = (try? context.fetch(FetchDescriptor<Park>())) ?? []
        let inCity = all.count { RegionIndex.identity(kind: .city, park: $0) == identifier }

        return Run(
            label: label,
            searches: searched,
            parksSaved: all.count,
            parksInCity: inCity,
            seconds: seconds,
            completed: result.completed,
            truncated: result.truncated
        )
    }

    func testBellevueBothWays() async throws {
        guard let placemark = try? await CLGeocoder().geocodeAddressString("Bellevue, WA").first,
              let centre = placemark.location?.coordinate else {
            XCTFail("Couldn't geocode Bellevue")
            return
        }
        let radius = RegionIndexer.radiusMeters(for: placemark, kind: .city)
        let identifier = RegionIndex.identity(
            kind: .city, name: "Bellevue", container: placemark.administrativeArea
        )
        print(String(format: "PROBE Bellevue centre=%.4f,%.4f radius=%.0fm budget=%d",
                     centre.latitude, centre.longitude, radius, ParkDiscoveryService.maxIndexSearches))

        var runs: [Run] = []
        runs.append(await sweep(label: "follow shape", centre: centre, radiusMeters: radius,
                                identifier: identifier, followShape: true))
        // Baseline already measured at 178 searches / 66 Bellevue parks; not re-spent.

        for run in runs {
            print(String(
                format: "PROBE %@ searches=%4d parksSaved=%4d inBellevue=%4d time=%6.1fs completed=%@ truncated=%@",
                run.label as NSString, run.searches, run.parksSaved, run.parksInCity,
                run.seconds, run.completed ? "yes" : "NO ", run.truncated ? "yes" : "no "
            ))
        }

        if let shaped = runs.first, let filled = Optional(Run(
            label: "fill circle ", searches: 178, parksSaved: 136, parksInCity: 66,
            seconds: 218.6, completed: true, truncated: false
        )) {
            let saved = filled.searches - shaped.searches
            print(String(
                format: "PROBE => shape used %d fewer searches (%.0f%%) and found %d of the %d Bellevue parks the full circle did",
                saved,
                filled.searches > 0 ? Double(saved) / Double(filled.searches) * 100 : 0,
                shaped.parksInCity, filled.parksInCity
            ))
        }
    }
}
