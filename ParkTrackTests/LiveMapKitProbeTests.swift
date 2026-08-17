import XCTest
import MapKit
import SwiftData
@testable import ParkTrack

/// Hits the real map service. Not part of the logic suite — this exists to tell "our code
/// dropped the results" apart from "the map service refused us", which look identical from
/// inside the app.
final class LiveMapKitProbeTests: XCTestCase {
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
