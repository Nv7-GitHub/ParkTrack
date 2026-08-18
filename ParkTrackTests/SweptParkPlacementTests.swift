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

    /// Indexing a city re-finds everything already in it, and that is the moment to correct
    /// a park that was filed wrongly — the search result carries the map's own placemark,
    /// which outranks a city guessed from the parks nearby.
    func testRefindingAParkCorrectsARegionThatWasGuessed() {
        let park = service.persist([candidate("Commonwealth Avenue Mall", city: nil, state: nil)]).first!
        // Placed by inference from its neighbours, wrongly.
        park.locality = "Cambridge"
        park.subAdministrativeArea = "Middlesex County"
        park.administrativeArea = "MA"
        park.regionResolvedAt = Date()
        park.regionInferredAt = Date()
        try? context.save()

        let refound = service.persist([
            candidate("Commonwealth Avenue Mall", city: "Boston", state: "MA")
        ]).first!

        XCTAssertEqual(refound.identifier, park.identifier, "Still the same park")
        XCTAssertEqual(refound.locality, "Boston", "…moved to where the map says it is")
        XCTAssertNil(refound.regionInferredAt, "…and no longer a guess")
        XCTAssertNotNil(refound.regionVerifiedAt, "…so nothing is left for a recheck to do")
    }

    /// A park the geocoder has already confirmed is not overwritten by a re-find, and a
    /// result carrying no city of its own never overwrites anything.
    func testAConfirmedRegionAndAPlacelessResultAreBothLeftAlone() {
        let park = service.persist([candidate("Dolores Park")]).first!
        park.locality = "San Francisco"
        park.regionVerifiedAt = Date()
        try? context.save()

        service.persist([candidate("Dolores Park", city: nil, state: nil)])
        XCTAssertEqual(park.locality, "San Francisco", "A result with no city says nothing")
    }

    /// A park placed from a search result needs no recheck — only guesses do.
    func testAParkPlacedFromItsOwnResultIsAlreadyConfirmed() {
        let park = service.persist([candidate("Dolores Park")]).first!
        XCTAssertNotNil(park.regionVerifiedAt)
        XCTAssertNil(park.regionInferredAt)
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

/// Whether a park counts as being in a place.
///
/// The strict key pairs a place with its container, and both sides get that container from
/// different MapKit calls. One answering "WA" where the other says "Washington" made every
/// park in a city fail to belong to it — which reads exactly like a city that is not there.
final class RegionMembershipTests: XCTestCase {

    private func park(city: String?, state: String?) -> Park {
        let park = Park(identifier: "p", name: "A Park", latitude: 47.6, longitude: -122.0)
        park.locality = city
        park.administrativeArea = state
        return park
    }

    func testAParkBelongsToItsCityWhateverTheStateIsCalled() {
        XCTAssertTrue(RegionIndex.place(kind: .city, park: park(city: "Sammamish", state: "WA"), isNamed: "Sammamish"))
        XCTAssertTrue(RegionIndex.place(kind: .city, park: park(city: "Sammamish", state: "Washington"), isNamed: "Sammamish"))
        XCTAssertTrue(RegionIndex.place(kind: .city, park: park(city: "Sammamish", state: nil), isNamed: "Sammamish"))
    }

    /// The strict key disagrees in exactly the case that broke, which is why the looser test
    /// exists alongside it.
    func testTheStrictKeyIsWhatFailed() {
        let abbreviated = RegionIndex.identity(kind: .city, park: park(city: "Sammamish", state: "WA"))
        let spelledOut = RegionIndex.identity(kind: .city, name: "Sammamish", container: "Washington")
        XCTAssertNotEqual(abbreviated, spelledOut)
    }

    func testCaseAndAccentsDoNotMatter() {
        XCTAssertTrue(RegionIndex.place(kind: .city, park: park(city: "sammamish", state: "WA"), isNamed: "SAMMAMISH"))
        XCTAssertTrue(RegionIndex.place(kind: .city, park: park(city: "Montréal", state: "QC"), isNamed: "Montreal"))
    }

    func testADifferentPlaceStillDoesNotBelong() {
        XCTAssertFalse(RegionIndex.place(kind: .city, park: park(city: "Redmond", state: "WA"), isNamed: "Sammamish"))
        XCTAssertFalse(RegionIndex.place(kind: .city, park: park(city: nil, state: "WA"), isNamed: "Sammamish"))
    }

    func testCountiesAndStatesUseTheirOwnField() {
        let p = Park(identifier: "q", name: "B Park", latitude: 47.6, longitude: -122.0)
        p.subAdministrativeArea = "King County"
        p.administrativeArea = "WA"
        XCTAssertTrue(RegionIndex.place(kind: .county, park: p, isNamed: "King County"))
        XCTAssertTrue(RegionIndex.place(kind: .state, park: p, isNamed: "WA"))
        XCTAssertFalse(RegionIndex.place(kind: .city, park: p, isNamed: "King County"))
    }
}
