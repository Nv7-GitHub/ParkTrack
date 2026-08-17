import XCTest
import MapKit
import SwiftData
@testable import ParkTrack

/// Hits the real map service. Not part of the logic suite — this exists to tell "our code
/// dropped the results" apart from "the map service refused us", which look identical from
/// inside the app.
final class LiveMapKitProbeTests: XCTestCase {
    /// These probes hit the real map service, and that rate limit is shared with whatever the
    /// developer's own phone is doing — running them casually takes searches out of someone's
    /// pocket. They only run when asked for explicitly:
    ///
    ///     PARKTRACK_LIVE_PROBES=1 xcodebuild ... -only-testing:ParkTrackTests/LiveMapKitProbeTests test
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PARKTRACK_LIVE_PROBES"] == "1",
            "Live map probes are opt-in; set PARKTRACK_LIVE_PROBES=1 to run them."
        )
    }

    /// Raw search at the travel-test coordinate, to separate "the service gave us nothing"
    /// from "our filters dropped everything".
    func testRawSearchAtOtherCity() async throws {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "park"
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
        do {
            let response = try await MKLocalSearch(request: request).start()
            print("PROBE other-city raw results: \(response.mapItems.count)")
            for item in response.mapItems.prefix(4) {
                print("PROBE other item: \(item.name ?? "?") city=\(item.placemark.locality ?? "nil")")
            }
        } catch {
            print("PROBE other-city raw error: \(error)")
        }
    }

    func testRawSearchReturnsSomething() async throws {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "park"
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6101, longitude: -122.2015),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
        do {
            let response = try await MKLocalSearch(request: request).start()
            print("PROBE raw results: \(response.mapItems.count)")
            for item in response.mapItems.prefix(5) {
                print("PROBE item: \(item.name ?? "?") city=\(item.placemark.locality ?? "nil") cat=\(item.pointOfInterestCategory?.rawValue ?? "nil")")
            }
            XCTAssertFalse(response.mapItems.isEmpty, "Map service returned nothing at all")
        } catch {
            print("PROBE error: \(error)")
            throw error
        }
    }

    /// The radius the app actually uses on first launch: the largest ring, which includes
    /// the 25-mile custom radius by default.
    @MainActor
    func testServiceSweepAtAppRadius() async throws {
        let container = PersistenceController.makeInMemoryContainer()
        let service = ParkDiscoveryService(modelContext: ModelContext(container))
        let start = Date()
        let found = await service.sweep(
            around: CLLocationCoordinate2D(latitude: 47.6101, longitude: -122.2015),
            radiusMiles: 25,
            force: false
        )
        print("PROBE 25mi sweep found: \(found.count) in \(Int(Date().timeIntervalSince(start)))s, error: \(service.lastError ?? "none")")
        XCTAssertFalse(found.isEmpty, "25-mile sweep found nothing: \(service.lastError ?? "no error")")
    }

    /// Same call, a different city: isolates "the map has no parks there" from "we were
    /// throttled" when a sweep somewhere new comes back empty.
    @MainActor
    func testSweepInADifferentCity() async throws {
        let container = PersistenceController.makeInMemoryContainer()
        let service = ParkDiscoveryService(modelContext: ModelContext(container))
        let found = await service.sweep(
            around: CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784),
            radiusMiles: 25,
            force: true
        )
        print("PROBE other-city sweep found: \(found.count), completed: \(service.lastSweepCompleted), error: \(service.lastError ?? "none")")
        print("PROBE localities: \(Set(found.compactMap(\.locality)).sorted().prefix(6))")
        // Deliberately not an assertion. MKLocalSearch treats `region` as a hint: asked about
        // a city far from the device it will answer with results from where the device is,
        // which the sweep's own filter then discards. That is the behaviour this prints, not
        // a requirement the app can impose.
    }

    /// What indexing actually costs now. Prints requests and wall clock for a city-sized and
    /// a county-sized area, which is the number the user experiences as "slow".
    @MainActor
    func testDenseSweepCost() async throws {
        for (label, radius) in [("county", 25.0)] {
            let container = PersistenceController.makeInMemoryContainer()
            let service = ParkDiscoveryService(modelContext: ModelContext(container))
            var searches = 0
            let start = Date()
            let result = await service.sweepDense(
                around: CLLocationCoordinate2D(latitude: 47.6101, longitude: -122.2015),
                radiusMiles: radius
            ) { progress in
                searches = progress.tilesSearched
            }
            let seconds = Int(Date().timeIntervalSince(start))
            print("PROBE \(label) radius=\(radius)mi searches=\(searches) seconds=\(seconds) parks=\(result.found.count) truncated=\(result.truncated) completed=\(result.completed) error=\(service.lastError ?? "none")")
        }
    }

    @MainActor
    func testServiceSweepFindsParks() async throws {
        let container = PersistenceController.makeInMemoryContainer()
        let service = ParkDiscoveryService(modelContext: ModelContext(container))
        let found = await service.sweep(
            around: CLLocationCoordinate2D(latitude: 47.6101, longitude: -122.2015),
            radiusMiles: 3,
            force: true
        )
        print("PROBE sweep found: \(found.count), error: \(service.lastError ?? "none")")
        XCTAssertFalse(found.isEmpty, "Sweep found nothing: \(service.lastError ?? "no error reported")")
    }
}
