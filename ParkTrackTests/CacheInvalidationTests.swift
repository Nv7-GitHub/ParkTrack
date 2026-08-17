import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

/// Every screen caches its figures against a `StatsSignature`, and the signature is what
/// decides whether anything needs recomputing. These pin down the changes it has to notice.
///
/// The bug they guard against: the signature used to be built from a park count, a visit
/// count and a coordinate. Anything that changed the data without moving one of those
/// numbers — finishing a region index, clearing a visit's date, a geocoder naming a park's
/// city — left every cache in the app serving its old answer until the app was relaunched
/// and the caches happened to start empty.
@MainActor
final class CacheInvalidationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }()

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
    private func makePark(_ name: String, city: String = "Redmond", state: String = "WA") -> Park {
        let park = Park(
            identifier: Park.identity(name: name, coordinate: .init(latitude: 0, longitude: 0)),
            name: name,
            latitude: 0,
            longitude: 0
        )
        park.locality = city
        park.administrativeArea = state
        park.country = "United States"
        context.insert(park)
        try? context.save()
        return park
    }

    private func allParks() -> [Park] {
        (try? context.fetch(FetchDescriptor<Park>())) ?? []
    }

    private func allIndexes() -> [RegionIndex] {
        (try? context.fetch(FetchDescriptor<RegionIndex>())) ?? []
    }

    private func signature() -> StatsSignature {
        StatsSignature(parkCount: allParks().count, visitCount: context.visitCount())
    }

    // MARK: - The revision itself

    func testSavingMovesTheStoreRevision() {
        let before = StoreRevision.shared.value
        makePark("Alpha")
        XCTAssertNotEqual(StoreRevision.shared.value, before, "A save has to be visible to the caches")
    }

    func testTwoSignaturesTakenWithoutASaveAreEqual() {
        makePark("Alpha")
        XCTAssertEqual(signature(), signature(), "Nothing changed, so nothing should recompute")
    }

    func testASignatureTakenAfterASaveDiffers() {
        makePark("Alpha")
        let before = signature()
        let park = makePark("Beta")
        park.isWishlisted = true
        try? context.save()
        XCTAssertNotEqual(signature(), before)
    }

    /// The point of the whole caching layer: a body evaluated repeatedly with no write in
    /// between must not do the work again.
    func testADerivedCacheStillServesRepeatReadsWithoutASave() {
        makePark("Alpha")
        let cache = DerivedCache<Int>()
        var computations = 0

        for _ in 0..<10 {
            _ = cache.value(for: signature()) {
                computations += 1
                return computations
            }
        }
        XCTAssertEqual(computations, 1)
    }

    func testADerivedCacheRecomputesAfterASave() {
        makePark("Alpha")
        let cache = DerivedCache<Int>()
        var computations = 0

        _ = cache.value(for: signature()) { computations += 1; return computations }
        makePark("Beta")
        _ = cache.value(for: signature()) { computations += 1; return computations }

        XCTAssertEqual(computations, 2)
    }

    // MARK: - Finishing a region index

    /// Reported behaviour: indexing a city said "partial" until the app was reopened.
    func testAFinishedIndexIsReflectedWithoutRelaunching() async {
        makePark("Alpha")
        let cache = StatsCache()

        await cache.warm(
            parks: allParks(), signature: signature(), indexes: allIndexes(),
            origin: nil, anchor: nil, radiiMiles: [], timelineMonths: 12
        )
        XCTAssertEqual(cache.cityCompletions.first?.isIndexed, false, "Nothing has been indexed yet")

        let index = RegionIndex(
            identifier: RegionIndex.identity(kind: .city, name: "Redmond", container: "WA"),
            kind: .city,
            name: "Redmond",
            container: "WA",
            country: "United States",
            center: .init(latitude: 0, longitude: 0),
            radiusMeters: 10_000
        )
        index.parkCount = 40
        index.indexedAt = Date()
        index.indexerVersion = RegionIndex.currentIndexerVersion
        context.insert(index)
        try? context.save()

        await cache.warm(
            parks: allParks(), signature: signature(), indexes: allIndexes(),
            origin: nil, anchor: nil, radiiMiles: [], timelineMonths: 12
        )

        XCTAssertEqual(cache.cityCompletions.first?.isIndexed, true, "The finished index has to show up")
        XCTAssertEqual(cache.cityCompletions.first?.total, 40, "…and bring its real denominator with it")
    }

    // MARK: - Clearing a visit's date

    /// Reported behaviour: the stats did not move after the fix-up screen removed dates.
    /// Neither count changes — the visits are all still there — so only the revision can
    /// tell the cache that the timeline is now wrong.
    func testClearingADateIsReflectedWithoutRelaunching() async {
        let park = makePark("Alpha")
        let visit = Visit(date: Date(), park: park)
        context.insert(visit)
        try? context.save()

        let cache = StatsCache()
        let before = signature()
        await cache.warm(
            parks: allParks(), signature: before, indexes: allIndexes(),
            origin: nil, anchor: nil, radiiMiles: [], timelineMonths: 12
        )
        XCTAssertEqual(cache.visitTimeline.reduce(0) { $0 + $1.count }, 1)

        visit.isUndated = true
        try? context.save()

        let after = signature()
        XCTAssertEqual(after.visitCount, before.visitCount, "The visit still exists — no count moved")
        XCTAssertEqual(after.parkCount, before.parkCount)
        XCTAssertNotEqual(after, before, "…so the revision is the only thing that can catch this")

        await cache.warm(
            parks: allParks(), signature: after, indexes: allIndexes(),
            origin: nil, anchor: nil, radiiMiles: [], timelineMonths: 12
        )
        XCTAssertEqual(cache.visitTimeline.reduce(0) { $0 + $1.count }, 0)
        XCTAssertEqual(cache.records?.totalParks, 1, "The park is still visited")
    }

    // MARK: - A geocoder placing a park

    /// The same class of change, not yet reported: naming a park's city moves every region
    /// percentage without touching a single count.
    func testPlacingAParkInACityIsReflectedWithoutRelaunching() async {
        let park = makePark("Alpha")
        park.locality = nil
        try? context.save()

        let cache = StatsCache()
        await cache.warm(
            parks: allParks(), signature: signature(), indexes: allIndexes(),
            origin: nil, anchor: nil, radiiMiles: [], timelineMonths: 12
        )
        XCTAssertTrue(cache.cityCompletions.isEmpty, "Nothing is placed yet")

        park.locality = "Redmond"
        try? context.save()

        await cache.warm(
            parks: allParks(), signature: signature(), indexes: allIndexes(),
            origin: nil, anchor: nil, radiiMiles: [], timelineMonths: 12
        )
        XCTAssertEqual(cache.cityCompletions.first?.name, "Redmond")
    }
}
