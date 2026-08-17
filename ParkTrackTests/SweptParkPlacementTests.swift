import XCTest
import CoreLocation
import MapKit
import SwiftData
@testable import ParkTrack

/// A park found by a sweep has to know where it is straight away.
///
/// The search result already names the city; the geocoder is a fallback for the results
/// that don't. Discarding what the map said meant a freshly indexed park belonged to no
/// city until a rate-limited lookup reached it, about one a second — so indexing could
/// report ninety parks found while the city it had just indexed still read "1 of 2".
@MainActor
final class SweptParkPlacementTests: XCTestCase {

    private var container: ModelContainer!
    private var service: ParkDiscoveryService!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
        service = ParkDiscoveryService(modelContext: context)
    }

    override func tearDown() {
        service = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func candidate(
        _ name: String,
        lat: Double = 37.77,
        lon: Double = -122.42,
        city: String? = "San Francisco",
        state: String? = "CA"
    ) -> ParkCandidate {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return ParkCandidate(
            id: Park.identity(name: name, coordinate: coordinate),
            name: name,
            coordinate: coordinate,
            category: MKPointOfInterestCategory.park.rawValue,
            addressLine: "\(name), \(city ?? "")",
            isParkLike: true,
            locality: city,
            subAdministrativeArea: city.map { _ in "San Francisco County" },
            administrativeArea: state,
            country: "United States"
        )
    }

    func testASweptParkKnowsItsCityImmediately() {
        let parks = service.persist([candidate("Dolores Park")])

        XCTAssertEqual(parks.first?.locality, "San Francisco")
        XCTAssertEqual(parks.first?.administrativeArea, "CA")
        XCTAssertNotNil(parks.first?.regionResolvedAt, "…so the geocoder never has to look at it")
    }

    /// The symptom exactly: an index finds a pile of parks, and the city's completion row
    /// has to grow as they arrive rather than after a geocoder crawls through them.
    func testAnIndexedCityCountsItsParksAsTheyArrive() {
        var found: [Park] = []
        for index in 0..<40 {
            found += service.persist([candidate("Park \(index)", lat: 37.77 + Double(index) * 0.001)])
        }
        XCTAssertEqual(found.count, 40)

        let all = (try? context.fetch(FetchDescriptor<Park>())) ?? []
        let completions = StatsEngine.completionByCity(parks: all)

        XCTAssertEqual(completions.first?.name, "San Francisco")
        XCTAssertEqual(completions.first?.total, 40, "Every park found is already counted in its city")
    }

    /// A park saved before this worked is repaired the next time a sweep passes over it,
    /// rather than waiting on the geocoder forever.
    func testAnAlreadyStoredParkPicksUpARegionItWasMissing() {
        let unplaced = candidate("Dolores Park", city: nil, state: nil)
        let before = service.persist([unplaced])
        XCTAssertNil(before.first?.locality)

        let placed = service.persist([candidate("Dolores Park")])

        XCTAssertEqual(placed.first?.identifier, before.first?.identifier, "Still the same park")
        XCTAssertEqual(placed.first?.locality, "San Francisco")
    }

    /// A result the map itself could not place is left for the geocoder, not invented.
    func testAResultWithNoRegionIsLeftForTheGeocoder() {
        let parks = service.persist([candidate("Mystery Green", city: nil, state: nil)])

        XCTAssertNil(parks.first?.locality)
        XCTAssertNil(parks.first?.regionResolvedAt)
    }

    /// Region completion skips parks with no city at all, which is why the placement matters.
    func testAnUnplacedParkIsInNoCitysTotal() {
        service.persist([candidate("Mystery Green", city: nil, state: nil)])
        let all = (try? context.fetch(FetchDescriptor<Park>())) ?? []
        XCTAssertTrue(StatsEngine.completionByCity(parks: all).isEmpty)
    }
}
