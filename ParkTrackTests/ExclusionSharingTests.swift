import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

/// Matching a friend's rejections onto the local catalogue, and keeping a race fair while
/// the two catalogues disagree.
///
/// The stakes are asymmetric, which is why these are picky. Failing to match costs the user
/// a little convenience. Matching the wrong park deletes a park, its visits and its photos,
/// with no undo.
@MainActor
final class ExclusionSharingTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    /// Boston Common, near enough. Two parks of this name sit about 150 m apart.
    private let bostonLat = 42.3550
    private let bostonLon = -71.0656

    override func setUp() {
        super.setUp()
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func makePark(_ name: String, lat: Double, lon: Double) -> Park {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let park = Park(
            identifier: Park.identity(name: name, coordinate: coordinate),
            name: name,
            latitude: lat,
            longitude: lon
        )
        context.insert(park)
        return park
    }

    private func friendExclusion(_ name: String, lat: Double, lon: Double) -> FriendExclusion {
        FriendExclusion(
            identifier: Park.identity(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)),
            name: name,
            latitude: lat,
            longitude: lon
        )
    }

    private func parks() throws -> [Park] {
        try context.fetch(FetchDescriptor<Park>())
    }

    // MARK: - Matching

    func testIdenticalCoordinatesMatchExactly() throws {
        let park = makePark("Riverside Parcel", lat: bostonLat, lon: bostonLon)
        try context.save()

        let (match, matched) = ExclusionMatcher.match(
            identifier: park.identifier,
            name: park.name,
            coordinate: park.coordinate,
            among: try parks()
        )
        XCTAssertEqual(match, .exact)
        XCTAssertEqual(matched?.identifier, park.identifier)
    }

    /// The failure the whole proximity fallback exists for: the same place, found a
    /// fraction of a metre apart, straddling a grid boundary. `ParkIdentityProbe` measures
    /// this happening for about 9% of one-metre re-finds.
    func testGridDriftStillMatches() throws {
        let below = 42.354949
        let above = 42.354951
        let local = makePark("Riverside Parcel", lat: below, lon: bostonLon)
        try context.save()

        let drifted = friendExclusion("Riverside Parcel", lat: above, lon: bostonLon)
        XCTAssertNotEqual(drifted.identifier, local.identifier, "this test is pointless if the identifiers agree")

        let (match, matched) = ExclusionMatcher.match(
            identifier: drifted.identifier,
            name: drifted.name,
            coordinate: drifted.coordinate,
            among: try parks()
        )
        guard case .nearby = match else {
            return XCTFail("drifted coordinates failed to match the local park: \(match)")
        }
        XCTAssertEqual(matched?.identifier, local.identifier)
    }

    /// Two same-name parks closer together than the match radius. Neither can be ruled out,
    /// so the matcher must refuse to pick and hand the choice to the person.
    func testTwoParksSharingANameAreAmbiguous() throws {
        makePark("Boston Common", lat: bostonLat, lon: bostonLon)
        makePark("Boston Common", lat: bostonLat + 0.00036, lon: bostonLon) // ~40 m north
        try context.save()

        // A rejection between the two, within reach of both.
        let (match, matched) = ExclusionMatcher.match(
            identifier: "boston common|42.3552|-71.0656",
            name: "Boston Common",
            coordinate: CLLocationCoordinate2D(latitude: bostonLat + 0.00018, longitude: bostonLon),
            among: try parks()
        )
        XCTAssertEqual(match, .ambiguous(count: 2))
        XCTAssertNil(matched, "an ambiguous rejection must not choose a park to delete")
    }

    /// The real Boston Common case, 150 m apart. A rejection stranded between them is ~75 m
    /// from each — beyond the drift the fallback exists to absorb — so it matches neither
    /// and deletes nothing. Landing on "adopt the rejection, touch no park" is the right
    /// answer here: the alternative is guessing which of two parks to destroy.
    func testAStrandedRejectionBetweenDistantNamesakesDeletesNothing() throws {
        makePark("Boston Common", lat: bostonLat, lon: bostonLon)
        makePark("Boston Common", lat: bostonLat + 0.00135, lon: bostonLon)
        try context.save()

        let (match, matched) = ExclusionMatcher.match(
            identifier: "boston common|42.3556|-71.0656",
            name: "Boston Common",
            coordinate: CLLocationCoordinate2D(latitude: bostonLat + 0.0006, longitude: bostonLon),
            among: try parks()
        )
        XCTAssertEqual(match, .undiscovered)
        XCTAssertNil(matched)
        XCTAssertEqual(try parks().count, 2, "both namesakes must survive")
    }

    /// The radius must be tight enough that a rejection sitting on one Boston Common cannot
    /// reach the other — otherwise every such pair would be permanently ambiguous.
    func testRadiusSeparatesTheTwoBostonCommons() throws {
        let first = makePark("Boston Common", lat: bostonLat, lon: bostonLon)
        makePark("Boston Common", lat: bostonLat + 0.00135, lon: bostonLon)
        try context.save()

        let (match, matched) = ExclusionMatcher.match(
            identifier: first.identifier,
            name: "Boston Common",
            coordinate: first.coordinate,
            among: try parks()
        )
        XCTAssertEqual(match, .exact)
        XCTAssertEqual(matched?.identifier, first.identifier)
    }

    func testUnknownPlaceIsStillWorthAdopting() throws {
        makePark("Somewhere Else", lat: bostonLat, lon: bostonLon)
        try context.save()

        let (match, matched) = ExclusionMatcher.match(
            identifier: "old depot lot|1.0|2.0",
            name: "Old Depot Lot",
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
            among: try parks()
        )
        XCTAssertEqual(match, .undiscovered)
        XCTAssertNil(matched)
    }

    // MARK: - Building the list

    func testAlreadyExcludedPlacesAreNotOffered() throws {
        let exclusion = friendExclusion("Old Depot Lot", lat: bostonLat, lon: bostonLon)
        let mine = ExcludedPlace(
            identifier: exclusion.identifier,
            name: "Old Depot Lot",
            latitude: bostonLat,
            longitude: bostonLon
        )

        let rows = AdoptableExclusion.list(from: [exclusion], parks: [], alreadyExcluded: [mine])
        XCTAssertTrue(rows.isEmpty, "the list offered back work the user had already done")
    }

    /// The same suppression has to survive coordinate drift, or a rejection the user already
    /// made comes back as a row that would do nothing.
    func testAlreadyExcludedSurvivesDrift() throws {
        let exclusion = friendExclusion("Old Depot Lot", lat: 42.354951, lon: bostonLon)
        let mine = ExcludedPlace(
            identifier: "old depot lot|42.3549|-71.0656",
            name: "Old Depot Lot",
            latitude: 42.354949,
            longitude: bostonLon
        )
        XCTAssertNotEqual(mine.identifier, exclusion.identifier)

        let rows = AdoptableExclusion.list(from: [exclusion], parks: [], alreadyExcluded: [mine])
        XCTAssertTrue(rows.isEmpty)
    }

    func testUnvisitedParkIsTickedByDefault() throws {
        let park = makePark("Riverside Parcel", lat: bostonLat, lon: bostonLon)
        try context.save()

        let rows = AdoptableExclusion.list(
            from: [friendExclusion("Riverside Parcel", lat: bostonLat, lon: bostonLon)],
            parks: try parks(),
            alreadyExcluded: []
        )
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.park?.identifier, park.identifier)
        XCTAssertTrue(row.isSelectedByDefault)
        XCTAssertNil(row.costDescription)
    }

    /// A place the user has actually been must never be ticked for them, and the row has to
    /// say what pressing apply would destroy.
    func testVisitedParkIsOfferedUntickedWithItsCost() throws {
        let park = makePark("Riverside Parcel", lat: bostonLat, lon: bostonLon)
        let visit = Visit(date: Date(), park: park)
        context.insert(visit)
        let photo = MediaItem(data: Data(repeating: 3, count: 32), isVideo: false)
        photo.visit = visit
        context.insert(photo)
        try context.save()

        let rows = AdoptableExclusion.list(
            from: [friendExclusion("Riverside Parcel", lat: bostonLat, lon: bostonLon)],
            parks: try parks(),
            alreadyExcluded: []
        )
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.canBeSelected, "it should still be possible to choose this deliberately")
        XCTAssertFalse(row.isSelectedByDefault, "a visited park was ticked for the user")
        XCTAssertEqual(row.visitCount, 1)
        XCTAssertEqual(row.mediaCount, 1)
        let cost = try XCTUnwrap(row.costDescription)
        XCTAssertTrue(cost.contains("1 visit"), cost)
        XCTAssertTrue(cost.contains("photo"), cost)
    }

    func testAmbiguousRowCannotBeSelected() throws {
        makePark("Boston Common", lat: bostonLat, lon: bostonLon)
        makePark("Boston Common", lat: bostonLat + 0.00036, lon: bostonLon)
        try context.save()

        let rows = AdoptableExclusion.list(
            from: [friendExclusion("Boston Common", lat: bostonLat + 0.00018, lon: bostonLon)],
            parks: try parks(),
            alreadyExcluded: []
        )
        let row = try XCTUnwrap(rows.first)
        XCTAssertFalse(row.canBeSelected)
        XCTAssertFalse(row.isSelectedByDefault)
        XCTAssertNil(row.park, "an ambiguous row must not carry a park that Apply could delete")
    }

    // MARK: - Fair denominators

    private func region(parkCount: Int) -> RegionIndex {
        let index = RegionIndex(
            identifier: "city|boston|ma",
            kind: .city,
            name: "Boston",
            container: "MA",
            country: "United States",
            center: CLLocationCoordinate2D(latitude: bostonLat, longitude: bostonLon),
            radiusMeters: 10_000
        )
        index.parkCount = parkCount
        index.indexedAt = Date()
        index.indexerVersion = RegionIndex.currentIndexerVersion
        return index
    }

    private func point(_ name: String, lat: Double, lon: Double) -> ExclusionPoint {
        ExclusionPoint(
            identifier: Park.identity(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)),
            name: name,
            latitude: lat,
            longitude: lon
        )
    }

    /// The same place rejected by both people, with different identifiers because of grid
    /// drift, must count once. Counting it twice shrinks the denominator below the truth.
    func testUnionTreatsTheSamePlaceAsOne() {
        let mine = [point("Old Depot Lot", lat: 42.354949, lon: bostonLon)]
        let theirs = [point("Old Depot Lot", lat: 42.354951, lon: bostonLon)]
        XCTAssertNotEqual(mine[0].identifier, theirs[0].identifier)

        XCTAssertEqual(RegionFairness.union(mine, theirs).count, 1)
    }

    func testUnionKeepsGenuinelyDifferentPlaces() {
        let mine = [point("Old Depot Lot", lat: bostonLat, lon: bostonLon)]
        let theirs = [point("Riverside Parcel", lat: bostonLat, lon: bostonLon)]
        XCTAssertEqual(RegionFairness.union(mine, theirs).count, 2)
    }

    func testExclusionsOutsideTheRegionDoNotCount() {
        let boston = region(parkCount: 100)
        let faraway = point("Somewhere", lat: 47.6, lon: -122.3) // Seattle
        XCTAssertEqual(RegionFairness.count([faraway], inside: boston), 0)
    }

    /// The whole point: two people who have rejected different places end up counting
    /// against one number rather than two.
    func testBothSidesCountAgainstTheSameTotal() {
        let boston = region(parkCount: 98) // already net of my two rejections
        let mine = [
            point("Old Depot Lot", lat: bostonLat + 0.001, lon: bostonLon),
            point("Riverside Parcel", lat: bostonLat + 0.002, lon: bostonLon)
        ]
        let theirs = [
            point("Hillside Verge", lat: bostonLat + 0.003, lon: bostonLon)
        ]

        let raw = RegionFairness.rawTotal(for: boston, localCount: 98, myExclusions: mine)
        XCTAssertEqual(raw, 100, "the pre-rejection total was not recovered")

        let union = RegionFairness.union(mine, theirs)
        let fair = RegionFairness.fairTotal(rawTotal: raw, region: boston, union: union)
        XCTAssertEqual(fair, 97, "three distinct rejections should leave 97 of 100")
    }

    /// With nobody rejecting anything, the denominator must be exactly what it was before
    /// any of this existed.
    func testNoExclusionsLeavesTheTotalUnchanged() {
        let boston = region(parkCount: 100)
        let raw = RegionFairness.rawTotal(for: boston, localCount: 40, myExclusions: [])
        XCTAssertEqual(raw, 100)
        XCTAssertEqual(RegionFairness.fairTotal(rawTotal: raw, region: boston, union: []), 100)
    }

    // MARK: - The wire

    /// Both list fields have to survive encoding, since neither used to be written at all —
    /// `regions` was silently dropped on the CloudKit path, which emptied the race.
    func testProfilePayloadCarriesRegionsAndExclusions() throws {
        let profile = FriendProfilePayload(
            code: "ABC234",
            displayName: "Sam",
            totalParks: 10,
            totalVisits: 20,
            citiesCount: 3,
            currentStreakWeeks: 4,
            parksThisMonth: 5,
            regions: [RegionProgressPayload(identifier: "city|boston|ma", name: "Boston", kind: "city", visited: 7, total: 100)],
            excludedPlaces: [ExcludedPlacePayload(
                identifier: "old depot lot|42.3549|-71.0656",
                name: "Old Depot Lot",
                latitude: 42.3549,
                longitude: -71.0656,
                excludedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(FriendProfilePayload.self, from: try encoder.encode(profile))

        XCTAssertEqual(restored.regions.count, 1)
        XCTAssertEqual(restored.regions.first?.total, 100)
        XCTAssertEqual(restored.excludedPlaces.count, 1)
        XCTAssertEqual(restored.excludedPlaces.first?.name, "Old Depot Lot")
    }
}
