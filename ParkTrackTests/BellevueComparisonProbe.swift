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

    /// Does the category filter miss parks that a plain text search finds?
    ///
    /// Every cell of a dense sweep runs one query: "park", filtered to Apple's park
    /// categories. Anything Apple never categorised is left to a single wide text pass over
    /// the whole region, which comes back capped at 25 results for an entire city.
    func testCategoryFilterVersusTextSearch() async throws {
        guard let placemark = try? await CLGeocoder().geocodeAddressString("Bellevue, WA").first,
              let centre = placemark.location?.coordinate else { return XCTFail("geocode") }
        let identifier = RegionIndex.identity(kind: .city, name: "Bellevue", container: placemark.administrativeArea)

        var byCategory: Set<String> = []
        var byText: Set<String> = []

        // A line of cells straight through the city.
        for step in -3...3 {
            for lonStep in -2...2 {
                let cell = ParkDiscoveryService.latticeCell(containing: CLLocationCoordinate2D(
                    latitude: centre.latitude + Double(step) * ParkDiscoveryService.minimumTileSpanDegrees,
                    longitude: centre.longitude + Double(lonStep) * ParkDiscoveryService.minimumTileSpanDegrees
                ))
                for filtered in [true, false] {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = "park"
                    request.region = cell
                    request.resultTypes = .pointOfInterest
                    if filtered {
                        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .nationalPark])
                    }
                    guard let response = try? await SearchThrottle.shared.run(request) else { continue }
                    for item in response.mapItems {
                        guard let name = item.name,
                              ParkDiscoveryService.isParkLike(name: name, category: item.pointOfInterestCategory),
                              item.placemark.locality == "Bellevue"
                        else { continue }
                        let key = Park.identity(name: name, coordinate: item.placemark.coordinate)
                        if filtered { byCategory.insert(key) } else { byText.insert(key) }
                    }
                }
            }
        }
        _ = identifier
        print("PROBE byCategory=\(byCategory.count) byText=\(byText.count) union=\(byCategory.union(byText).count)")
        print("PROBE text-only finds \(byText.subtracting(byCategory).count) the category filter missed")
        print("PROBE category-only finds \(byCategory.subtracting(byText).count) the text search missed")
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
        runs.append(await sweep(label: "both queries", centre: centre, radiusMeters: radius,
                                identifier: identifier, followShape: true))

        for run in runs {
            print(String(
                format: "PROBE %@ searches=%4d parksSaved=%4d inBellevue=%4d time=%6.1fs completed=%@ truncated=%@",
                run.label as NSString, run.searches, run.parksSaved, run.parksInCity,
                run.seconds, run.completed ? "yes" : "NO ", run.truncated ? "yes" : "no "
            ))
        }

        if false, let shaped = runs.first, let filled = Optional(Run(
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
