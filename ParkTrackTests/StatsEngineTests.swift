import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

@MainActor
final class StatsEngineTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    /// Fixed calendar and reference moment: every fixture date is built from these, so no
    /// assertion can drift when the suite happens to run near a month or year boundary.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }()

    private var now: Date { date(2026, 1, 15) }

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

    // MARK: - Fixtures

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @discardableResult
    private func makePark(
        _ name: String,
        lat: Double = 0,
        lon: Double = 0,
        city: String? = nil,
        county: String? = nil,
        state: String? = nil,
        visits: [Date] = [],
        rating: Int = 0
    ) -> Park {
        let park = Park(
            identifier: Park.identity(name: name, coordinate: .init(latitude: lat, longitude: lon)),
            name: name,
            latitude: lat,
            longitude: lon
        )
        park.locality = city
        park.subAdministrativeArea = county
        park.administrativeArea = state
        context.insert(park)

        for date in visits {
            let visit = Visit(date: date, rating: rating, park: park)
            context.insert(visit)
        }
        try? context.save()
        return park
    }

    private func allParks() -> [Park] {
        (try? context.fetch(FetchDescriptor<Park>())) ?? []
    }

    private var origin: CLLocationCoordinate2D { .init(latitude: 0, longitude: 0) }

    // MARK: - Fixture sanity

    func testVisitsAreAttachedToTheirPark() {
        let park = makePark("Alpha", visits: [date(2026, 1, 2), date(2026, 1, 3)])
        XCTAssertEqual(park.visitCount, 2)
        XCTAssertTrue(park.isVisited)
        XCTAssertEqual(park.firstVisitDate, date(2026, 1, 2))
    }

    // MARK: - Empty input

    func testEmptyInputProducesZeroedResults() {
        let completion = StatsEngine.radiusCompletion(parks: [], center: origin, radiusMiles: 5)
        XCTAssertEqual(completion.total, 0)
        XCTAssertEqual(completion.visited, 0)
        XCTAssertEqual(completion.fraction, 0)
        XCTAssertTrue(completion.remaining.isEmpty)

        XCTAssertTrue(StatsEngine.completionByCity(parks: []).isEmpty)
        XCTAssertTrue(StatsEngine.completionByCounty(parks: []).isEmpty)
        XCTAssertTrue(StatsEngine.completionByState(parks: []).isEmpty)

        let streaks = StatsEngine.streaks(parks: [], now: now, calendar: calendar)
        XCTAssertEqual(streaks.currentWeeks, 0)
        XCTAssertEqual(streaks.longestWeeks, 0)
        XCTAssertEqual(streaks.longestGapDays, 0)
        XCTAssertNil(streaks.lastVisitDate)

        let records = StatsEngine.records(parks: [], origin: nil, now: now, calendar: calendar)
        XCTAssertEqual(records.totalParks, 0)
        XCTAssertEqual(records.totalVisits, 0)
        XCTAssertEqual(records.biggestDayCount, 0)
        XCTAssertNil(records.biggestDayDate)
        XCTAssertNil(records.mostVisitedPark)
        XCTAssertNil(records.averageRating)
        XCTAssertNil(records.firstVisitDate)
    }

    func testTimelinesStillReturnBucketsForEmptyInput() {
        let months = StatsEngine.monthlyTimeline(parks: [], monthsBack: 3, now: now, calendar: calendar)
        XCTAssertEqual(months.count, 3)
        XCTAssertEqual(months.map(\.count), [0, 0, 0])
        XCTAssertEqual(months.map(\.cumulative), [0, 0, 0])

        let heatmap = StatsEngine.calendarHeatmap(parks: [], daysBack: 7, now: now, calendar: calendar)
        XCTAssertEqual(heatmap.count, 7)
        XCTAssertEqual(Set(heatmap.values), [0])
    }

    func testZeroOrNegativeWindowsReturnNothing() {
        XCTAssertTrue(StatsEngine.monthlyTimeline(parks: [], monthsBack: 0, now: now, calendar: calendar).isEmpty)
        XCTAssertTrue(StatsEngine.calendarHeatmap(parks: [], daysBack: 0, now: now, calendar: calendar).isEmpty)
    }

    // MARK: - Radius completion

    func testRadiusCompletionCountsVisitedAndSortsRemainingByDistance() {
        makePark("Near visited", lat: 0.01, visits: [date(2026, 1, 2)])
        let far = makePark("Far unvisited", lat: 0.03)
        let mid = makePark("Mid unvisited", lat: 0.02)
        makePark("Outside", lat: 5)

        let completion = StatsEngine.radiusCompletion(parks: allParks(), center: origin, radiusMiles: 10)
        XCTAssertEqual(completion.total, 3)
        XCTAssertEqual(completion.visited, 1)
        XCTAssertEqual(completion.fraction, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(completion.remaining.map(\.name), [mid.name, far.name])
    }

    func testRadiusBoundaryParkIsIncludedAndJustOutsideIsNot() {
        let onRing = makePark("On the ring", lat: 0.05)
        makePark("Past the ring", lat: 0.0502)

        let center = CLLocation(latitude: 0, longitude: 0)
        let exactMiles = onRing.distance(from: center) / Format.metersPerMile

        let completion = StatsEngine.radiusCompletion(parks: allParks(), center: origin, radiusMiles: exactMiles)
        XCTAssertEqual(completion.total, 1)
        XCTAssertEqual(completion.remaining.map(\.name), ["On the ring"])
    }

    func testRadiusCompletionsMapEveryRequestedRadius() {
        makePark("Close", lat: 0.01, visits: [date(2026, 1, 2)])
        makePark("Distant", lat: 0.1)

        let rings = StatsEngine.radiusCompletions(parks: allParks(), center: origin, radiiMiles: [2.5, 5, 10, 25])
        XCTAssertEqual(rings.map(\.radiusMiles), [2.5, 5, 10, 25])
        XCTAssertEqual(rings[0].total, 1)
        XCTAssertEqual(rings[0].fraction, 1)
        XCTAssertEqual(rings[3].total, 2)
        XCTAssertEqual(rings[3].fraction, 0.5)
        XCTAssertEqual(rings.map(\.id), rings.map(\.radiusMiles))
    }

    func testRadiusFractionIsZeroWhenNoParksAreInRange() {
        makePark("Somewhere else", lat: 10)
        let completion = StatsEngine.radiusCompletion(parks: allParks(), center: origin, radiusMiles: 1)
        XCTAssertEqual(completion.total, 0)
        XCTAssertEqual(completion.fraction, 0)
    }

    // MARK: - Region completion

    /// Ungeocoded parks are excluded outright, and the list leads with the place the user is
    /// furthest through rather than the one that happens to be largest.
    func testCompletionByCityExcludesUngeocodedParksAndSortsByProgress() {
        makePark("A", city: "Riverton", state: "ST", visits: [date(2026, 1, 2)])
        makePark("B", city: "Riverton", state: "ST")
        makePark("C", city: "Riverton", state: "ST")
        makePark("D", city: "Hillside", state: "ST", visits: [date(2026, 1, 3)])
        makePark("E")

        let cities = StatsEngine.completionByCity(parks: allParks())
        XCTAssertEqual(cities.map(\.name), ["Hillside", "Riverton"], "Finished Hillside outranks a third-done Riverton")

        let riverton = try! XCTUnwrap(cities.first { $0.name == "Riverton" })
        XCTAssertEqual(riverton.total, 3)
        XCTAssertEqual(riverton.visited, 1)
        XCTAssertEqual(riverton.fraction, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(riverton.remaining.map(\.name), ["B", "C"])

        let hillside = try! XCTUnwrap(cities.first { $0.name == "Hillside" })
        XCTAssertEqual(hillside.fraction, 1)
        XCTAssertTrue(hillside.remaining.isEmpty)
    }

    func testEqualTotalsAreOrderedByName() {
        makePark("A", city: "Zephyr")
        makePark("B", city: "Ashford")

        let cities = StatsEngine.completionByCity(parks: allParks())
        XCTAssertEqual(cities.map(\.name), ["Ashford", "Zephyr"])
    }

    func testCountyAndStateGroupingUseTheirOwnKeys() {
        makePark("A", city: "Riverton", county: "North County", state: "ST", visits: [date(2026, 1, 2)])
        makePark("B", city: "Hillside", county: "North County", state: "ST")
        makePark("C", city: "Elsewhere", county: nil, state: "XX")

        let counties = StatsEngine.completionByCounty(parks: allParks())
        XCTAssertEqual(counties.map(\.name), ["North County"])
        XCTAssertEqual(counties[0].total, 2)

        let states = StatsEngine.completionByState(parks: allParks())
        XCTAssertEqual(states.map(\.name), ["ST", "XX"])
        XCTAssertEqual(states[0].visited, 1)
        XCTAssertEqual(states[1].visited, 0)
    }

    // MARK: - Timelines

    func testMonthlyTimelineBucketsAcrossAYearBoundaryAndKeepsEmptyMonths() {
        makePark("Old", visits: [date(2025, 6, 1)])
        makePark("November", visits: [date(2025, 11, 4)])
        makePark("January", visits: [date(2026, 1, 5), date(2026, 1, 9)])

        let points = StatsEngine.monthlyTimeline(parks: allParks(), monthsBack: 3, now: now, calendar: calendar)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.date), [date(2025, 11, 1, hour: 0), date(2025, 12, 1, hour: 0), date(2026, 1, 1, hour: 0)])
        XCTAssertEqual(points.map(\.count), [1, 0, 1])
        XCTAssertEqual(points.map(\.cumulative), [2, 2, 3])
    }

    func testMonthlyTimelineCountsOnlyFirstVisits() {
        makePark("Repeat", visits: [date(2025, 12, 3), date(2026, 1, 4), date(2026, 1, 20)])

        let points = StatsEngine.monthlyTimeline(parks: allParks(), monthsBack: 2, now: now, calendar: calendar)
        XCTAssertEqual(points.map(\.count), [1, 0])
        XCTAssertEqual(points.map(\.cumulative), [1, 1])
    }

    func testVisitTimelineCountsEveryVisit() {
        makePark("Repeat", visits: [date(2025, 12, 3), date(2026, 1, 4), date(2026, 1, 20)])
        makePark("Other", visits: [date(2026, 1, 6)])

        let points = StatsEngine.visitTimeline(parks: allParks(), monthsBack: 2, now: now, calendar: calendar)
        XCTAssertEqual(points.map(\.count), [1, 3])
        XCTAssertEqual(points.map(\.cumulative), [1, 4])
    }

    func testCalendarHeatmapKeysAreDayStartsWithinTheWindow() {
        makePark("Today", visits: [date(2026, 1, 15, hour: 8), date(2026, 1, 15, hour: 19)])
        makePark("Yesterday", visits: [date(2026, 1, 14, hour: 6)])
        makePark("Ancient", visits: [date(2025, 1, 1)])

        let heatmap = StatsEngine.calendarHeatmap(parks: allParks(), daysBack: 7, now: now, calendar: calendar)
        XCTAssertEqual(heatmap.count, 7)
        XCTAssertEqual(heatmap[date(2026, 1, 15, hour: 0)], 2)
        XCTAssertEqual(heatmap[date(2026, 1, 14, hour: 0)], 1)
        XCTAssertEqual(heatmap[date(2026, 1, 13, hour: 0)], 0)
        XCTAssertNil(heatmap[date(2025, 1, 1, hour: 0)])
    }

    // MARK: - Streaks

    func testCurrentStreakSurvivesAWeekThatHasNotHappenedYet() {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let lastWeek = calendar.date(byAdding: .day, value: -1, to: thisWeek)!
        let weekBefore = calendar.date(byAdding: .day, value: -8, to: thisWeek)!
        makePark("A", visits: [lastWeek, weekBefore])

        let streaks = StatsEngine.streaks(parks: allParks(), now: now, calendar: calendar)
        XCTAssertEqual(streaks.currentWeeks, 2)
        XCTAssertEqual(streaks.longestWeeks, 2)
        XCTAssertEqual(streaks.lastVisitDate, lastWeek)
    }

    func testCurrentStreakIncludesTheLiveWeekWhenItAlreadyHasAVisit() {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let lastWeek = calendar.date(byAdding: .day, value: -1, to: thisWeek)!
        makePark("A", visits: [now, lastWeek])

        let streaks = StatsEngine.streaks(parks: allParks(), now: now, calendar: calendar)
        XCTAssertEqual(streaks.currentWeeks, 2)
    }

    func testCurrentStreakIsZeroOnceTwoWeeksPassWithoutAVisit() {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let threeWeeksBack = calendar.date(byAdding: .day, value: -15, to: thisWeek)!
        makePark("A", visits: [threeWeeksBack])

        let streaks = StatsEngine.streaks(parks: allParks(), now: now, calendar: calendar)
        XCTAssertEqual(streaks.currentWeeks, 0)
        XCTAssertEqual(streaks.longestWeeks, 1)
    }

    func testLongestStreakAndGapAreMeasuredAcrossAllVisits() {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let recent = calendar.date(byAdding: .day, value: -1, to: thisWeek)!
        let isolated = calendar.date(byAdding: .day, value: -50, to: thisWeek)!
        makePark("A", visits: [isolated, recent])

        let streaks = StatsEngine.streaks(parks: allParks(), now: now, calendar: calendar)
        XCTAssertEqual(streaks.currentWeeks, 1)
        XCTAssertEqual(streaks.longestWeeks, 1)
        XCTAssertEqual(streaks.longestGapDays, 49)
    }

    func testSingleVisitHasNoGap() {
        makePark("A", visits: [date(2026, 1, 5)])
        let streaks = StatsEngine.streaks(parks: allParks(), now: now, calendar: calendar)
        XCTAssertEqual(streaks.longestGapDays, 0)
        XCTAssertEqual(streaks.longestWeeks, 1)
    }

    // MARK: - Records

    func testRecordsSummarizeVisitedParksOnly() {
        makePark("Alpha", lat: 0.1, city: "Riverton", state: "ST",
                 visits: [date(2026, 1, 5), date(2026, 1, 6)], rating: 4)
        makePark("Beta", lat: 0.5, city: "Hillside", state: "XX",
                 visits: [date(2025, 12, 20)], rating: 2)
        makePark("Unvisited", lat: 9, city: "Nowhere", state: "ZZ")

        let records = StatsEngine.records(
            parks: allParks(),
            origin: CLLocation(latitude: 0, longitude: 0),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(records.totalParks, 2)
        XCTAssertEqual(records.totalVisits, 3)
        XCTAssertEqual(records.parksThisMonth, 1)
        XCTAssertEqual(records.parksThisYear, 1)
        XCTAssertEqual(records.distinctCities, 2)
        XCTAssertEqual(records.distinctStates, 2)
        XCTAssertEqual(records.mostVisitedPark?.name, "Alpha")
        XCTAssertEqual(records.farthestPark?.name, "Beta")
        XCTAssertEqual(records.farthestDistanceMeters ?? 0, 55_000, accuracy: 2_000)
        XCTAssertEqual(records.averageRating ?? 0, 10.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(records.firstVisitDate, date(2025, 12, 20))
    }

    func testRecordsHaveNoFarthestParkWithoutAnOrigin() {
        makePark("Alpha", lat: 0.1, visits: [date(2026, 1, 5)])
        let records = StatsEngine.records(parks: allParks(), origin: nil, now: now, calendar: calendar)
        XCTAssertNil(records.farthestPark)
        XCTAssertNil(records.farthestDistanceMeters)
    }

    func testBiggestDayCountsDistinctParksAndBreaksTiesOnTheEarlierDay() {
        makePark("Alpha", visits: [date(2026, 1, 5), date(2026, 1, 9)])
        makePark("Beta", visits: [date(2026, 1, 5), date(2026, 1, 9)])
        // Three visits, one park: a busy day for one park is not a bigger day out.
        makePark("Gamma", visits: [date(2026, 1, 11, hour: 9), date(2026, 1, 11, hour: 13), date(2026, 1, 11, hour: 17)])

        let records = StatsEngine.records(parks: allParks(), origin: nil, now: now, calendar: calendar)
        XCTAssertEqual(records.biggestDayCount, 2)
        XCTAssertEqual(records.biggestDayDate, date(2026, 1, 5, hour: 0))
    }

    func testAverageRatingIgnoresUnratedVisits() {
        makePark("Rated", visits: [date(2026, 1, 5)], rating: 5)
        makePark("Unrated", visits: [date(2026, 1, 6)], rating: 0)

        let records = StatsEngine.records(parks: allParks(), origin: nil, now: now, calendar: calendar)
        XCTAssertEqual(records.averageRating ?? 0, 5, accuracy: 0.0001)
    }

    // MARK: - Filters

    func testVisitedAndUnvisitedPartitionTheInput() {
        makePark("Alpha", visits: [date(2026, 1, 5)])
        makePark("Beta")

        let parks = allParks()
        XCTAssertEqual(StatsEngine.visitedParks(parks).map(\.name), ["Alpha"])
        XCTAssertEqual(StatsEngine.unvisitedParks(parks).map(\.name), ["Beta"])
    }
}
