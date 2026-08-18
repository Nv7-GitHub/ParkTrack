import XCTest
import CoreLocation
import MapKit
import SwiftData
@testable import ParkTrack

/// What happens to something the map calls a park and the user says isn't one.
@MainActor
final class NotAParkTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: ParkDiscoveryService!

    override func setUp() {
        super.setUp()
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
        service = ParkDiscoveryService(modelContext: context)
    }

    private func candidate(_ name: String, latitude: Double = 47.60, longitude: Double = -122.15) -> ParkCandidate {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return ParkCandidate(
            id: Park.identity(name: name, coordinate: coordinate),
            name: name,
            coordinate: coordinate,
            category: MKPointOfInterestCategory.park.rawValue,
            addressLine: "Bellevue, WA, United States",
            isParkLike: true,
            locality: "Bellevue"
        )
    }

    /// The bug this exists for: the map has not changed its mind, so a plain delete lasts
    /// only until the next sweep passes over the same ground.
    func testAnExcludedPlaceIsNotSavedAgainByALaterSweep() {
        let sunich = candidate("Sunich Property")
        XCTAssertEqual(service.persist([sunich]).count, 1)

        let saved = try! context.fetch(FetchDescriptor<Park>()).first!
        service.exclude(saved)
        XCTAssertTrue(try! context.fetch(FetchDescriptor<Park>()).isEmpty)

        XCTAssertTrue(service.persist([sunich]).isEmpty, "a sweep re-filed an excluded place")
        XCTAssertTrue(try! context.fetch(FetchDescriptor<Park>()).isEmpty)
    }

    func testDeletingWithoutExcludingIsNotEnough() {
        let sunich = candidate("Sunich Property")
        let park = service.persist([sunich])[0]
        context.delete(park)
        try? context.save()

        XCTAssertEqual(service.persist([sunich]).count, 1, "this is the behaviour exclusion exists to change")
    }

    func testLettingAPlaceBackInAllowsItToBeFoundAgain() {
        let sunich = candidate("Sunich Property")
        service.exclude(service.persist([sunich])[0])
        XCTAssertEqual(service.excludedPlaces().count, 1)

        service.readmit(service.excludedPlaces()[0])
        XCTAssertEqual(service.persist([sunich]).count, 1)
    }

    /// Adding one back by hand is the user changing their mind, and it has to stick.
    func testAddingAnExcludedPlaceByHandLiftsTheExclusion() {
        let sunich = candidate("Sunich Property")
        service.exclude(service.persist([sunich])[0])

        _ = service.park(for: sunich)
        try? context.save()
        XCTAssertTrue(service.excludedPlaces().isEmpty)
        XCTAssertEqual(service.persist([sunich]).count, 1, "the next sweep dropped it again")
    }

    func testExcludingOneDoesNotExcludeAnother() {
        let sunich = candidate("Sunich Property")
        let real = candidate("Wilburton Hill Park", latitude: 47.61, longitude: -122.16)
        _ = service.persist([sunich, real])
        let parks = try! context.fetch(FetchDescriptor<Park>())
        service.exclude(parks.first { $0.name == "Sunich Property" }!)

        let after = service.persist([sunich, real])
        XCTAssertEqual(after.map(\.name), ["Wilburton Hill Park"])
    }

    // MARK: - What the tidy-up sheet offers

    private func park(name: String, category: String?, address: String?) -> Park {
        let park = Park(
            identifier: name,
            name: name,
            latitude: 47.6,
            longitude: -122.15,
            categoryRaw: category
        )
        park.postalAddress = address
        return park
    }

    /// The Esterra Park flats: a map result with an address and no category, which the old
    /// audit read as hand-placed and never offered for review.
    func testUncategorisedMapResultsAreOfferedForReview() {
        let flats = park(
            name: "Parkside Esterra Park",
            category: nil,
            address: "15551 NE Turing St, Redmond, WA 98052, United States"
        )
        XCTAssertTrue(ParkAudit.isSuspicious(flats))
        XCTAssertEqual(ParkAudit.reason(for: flats), "The map doesn't list this as a park")
    }

    /// A pin the user dropped has neither, and is nobody's business but theirs.
    func testHandPlacedPinsAreLeftAlone() {
        XCTAssertFalse(ParkAudit.isSuspicious(park(name: "The spot by the creek", category: nil, address: nil)))
    }

    func testCategorisedParksAreLeftAlone() {
        XCTAssertFalse(ParkAudit.isSuspicious(park(
            name: "Sunich Property",
            category: MKPointOfInterestCategory.park.rawValue,
            address: "Bellevue, WA 98008, United States"
        )))
    }

    func testCafesAreStillFlagged() {
        let cafe = park(
            name: "Park Avenue Coffee",
            category: MKPointOfInterestCategory.cafe.rawValue,
            address: "1 Park Ave, Bellevue, WA, United States"
        )
        XCTAssertTrue(ParkAudit.isSuspicious(cafe))
        XCTAssertEqual(ParkAudit.reason(for: cafe), "The map calls this a cafe")
    }
}
