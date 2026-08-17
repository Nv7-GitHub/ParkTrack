import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

/// Marking a park visited and logging a visit are different claims, and only the second
/// one is about a day. These pin down which figures each may move.
///
/// The bug this guards against: before undated visits existed, clearing a backlog of a
/// hundred parks wrote a hundred visits dated that afternoon, so every timeline, streak
/// and heatmap in the app described the day the app was installed.
@MainActor
final class UndatedVisitTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }()

    private var now: Date { date(2026, 6, 15) }

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

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @discardableResult
    private func makePark(_ name: String, lat: Double = 0, lon: Double = 0) -> Park {
        let park = Park(
            identifier: Park.identity(name: name, coordinate: .init(latitude: lat, longitude: lon)),
            name: name,
            latitude: lat,
            longitude: lon
        )
        park.locality = "Testville"
        park.administrativeArea = "TS"
        context.insert(park)
        try? context.save()
        return park
    }

    @discardableResult
    private func log(_ park: Park, on date: Date) -> Visit {
        let visit = Visit(date: date, park: park)
        context.insert(visit)
        try? context.save()
        return visit
    }

    @discardableResult
    private func mark(_ park: Park) -> Visit {
        let visit = Visit.undated(park: park)
        context.insert(visit)
        try? context.save()
        return visit
    }

    private func allParks() -> [Park] {
        (try? context.fetch(FetchDescriptor<Park>())) ?? []
    }

    // MARK: - What a mark does count towards

    func testAMarkedParkIsVisited() {
        let park = makePark("Alpha")
        mark(park)

        XCTAssertTrue(park.isVisited)
        XCTAssertEqual(park.visitCount, 1)
        XCTAssertTrue(park.isVisitedWithoutADate)
    }

    func testAMarkedParkCountsTowardsCompletion() {
        let park = makePark("Alpha")
        makePark("Beta", lat: 0.001)
        mark(park)

        let completion = StatsEngine.radiusCompletion(
            parks: allParks(),
            center: .init(latitude: 0, longitude: 0),
            radiusMiles: 5
        )
        XCTAssertEqual(completion.total, 2)
        XCTAssertEqual(completion.visited, 1)
    }

    func testAMarkedParkCountsTowardsTheHeadlineTotals() {
        let park = makePark("Alpha")
        mark(park)

        let records = StatsEngine.records(parks: allParks(), origin: nil, now: now, calendar: calendar)
        XCTAssertEqual(records.totalParks, 1)
        XCTAssertEqual(records.totalVisits, 1)
        XCTAssertEqual(records.distinctCities, 1)
    }

    // MARK: - What a mark must not count towards

    func testAMarkHasNoFirstOrLastVisitDate() {
        let park = makePark("Alpha")
        mark(park)

        XCTAssertNil(park.firstVisitDate)
        XCTAssertNil(park.lastVisitDate)
        XCTAssertTrue(park.datedVisits.isEmpty)
    }

    func testAMarkDoesNotLandOnTheTimeline() {
        let park = makePark("Alpha")
        mark(park)

        let points = StatsEngine.monthlyTimeline(parks: allParks(), monthsBack: 12, now: now, calendar: calendar)
        XCTAssertEqual(points.reduce(0) { $0 + $1.count }, 0)
        XCTAssertEqual(points.last?.cumulative, 0)

        let visitPoints = StatsEngine.visitTimeline(parks: allParks(), monthsBack: 12, now: now, calendar: calendar)
        XCTAssertEqual(visitPoints.reduce(0) { $0 + $1.count }, 0)
    }

    func testAMarkDoesNotStartAStreak() {
        let park = makePark("Alpha")
        mark(park)

        let streaks = StatsEngine.streaks(parks: allParks(), now: now, calendar: calendar)
        XCTAssertEqual(streaks.currentWeeks, 0)
        XCTAssertEqual(streaks.longestWeeks, 0)
        XCTAssertNil(streaks.lastVisitDate)
    }

    func testAMarkDoesNotLightUpTheHeatmapOrTheRhythmCharts() {
        let park = makePark("Alpha")
        mark(park)

        let heatmap = StatsEngine.calendarHeatmap(parks: allParks(), daysBack: 364, now: now, calendar: calendar)
        XCTAssertEqual(heatmap.values.reduce(0, +), 0)

        let weekdays = StatsBreakdown.byWeekday(parks: allParks(), calendar: calendar)
        XCTAssertEqual(weekdays.reduce(0) { $0 + $1.count }, 0)

        let months = StatsBreakdown.byMonthOfYear(parks: allParks(), calendar: calendar)
        XCTAssertEqual(months.reduce(0) { $0 + $1.count }, 0)
    }

    func testAMarkIsNotThisMonthsOrThisYearsDiscovery() {
        let park = makePark("Alpha")
        mark(park)

        let records = StatsEngine.records(parks: allParks(), origin: nil, now: now, calendar: calendar)
        XCTAssertEqual(records.parksThisMonth, 0)
        XCTAssertEqual(records.parksThisYear, 0)
        XCTAssertNil(records.firstVisitDate)
        XCTAssertNil(records.biggestDayDate)
        XCTAssertEqual(records.biggestDayCount, 0)
    }

    func testAMarkIsNotAYearInReviewDiscovery() {
        let park = makePark("Alpha")
        mark(park)

        let summary = YearInReviewSummary.make(
            parks: allParks(), year: 2026, streakWeeks: 0, displayName: "", calendar: calendar
        )
        XCTAssertEqual(summary.parksDiscovered, 0)
        XCTAssertEqual(summary.visits, 0)
        XCTAssertTrue(summary.isEmpty)
    }

    // MARK: - A backlog next to a real log

    /// The shape of the user's actual store: a pile of marks cleared in one sitting, plus a
    /// handful of visits genuinely logged on the day they happened.
    func testABacklogOfMarksLeavesARealLogsTimelineIntact() {
        for index in 0..<50 {
            mark(makePark("Marked \(index)", lat: Double(index) * 0.0001))
        }
        let logged = makePark("Logged", lat: 0.9)
        log(logged, on: date(2026, 3, 4))

        let points = StatsEngine.monthlyTimeline(parks: allParks(), monthsBack: 12, now: now, calendar: calendar)
        XCTAssertEqual(points.reduce(0) { $0 + $1.count }, 1, "Only the genuinely dated visit belongs on the curve")
        XCTAssertEqual(points.last?.cumulative, 1)

        let records = StatsEngine.records(parks: allParks(), origin: nil, now: now, calendar: calendar)
        XCTAssertEqual(records.totalParks, 51, "Every marked park is still in the collection")
        XCTAssertEqual(records.parksThisYear, 1, "But only one of them was discovered on a known day")
    }

    // MARK: - Repairing an existing history

    func testABareDatedVisitIsRecognisedAsRepairable() {
        let park = makePark("Alpha")
        let bare = log(park, on: date(2026, 3, 4))
        XCTAssertTrue(bare.hasNoDetails)
    }

    func testAVisitWithAnyDetailIsNeverTreatedAsAMark() {
        let park = makePark("Alpha")

        let rated = log(park, on: date(2026, 3, 4))
        rated.rating = 4
        XCTAssertFalse(rated.hasNoDetails)

        let noted = log(park, on: date(2026, 3, 5))
        noted.notes = "Lovely"
        XCTAssertFalse(noted.hasNoDetails)

        let timed = log(park, on: date(2026, 3, 6))
        timed.durationMinutes = 45
        XCTAssertFalse(timed.hasNoDetails)

        let accompanied = log(park, on: date(2026, 3, 7))
        accompanied.companions = "Sam"
        XCTAssertFalse(accompanied.hasNoDetails)

        let photographed = log(park, on: date(2026, 3, 8))
        let media = MediaItem(data: Data([0x01]), isVideo: false)
        context.insert(media)
        media.visit = photographed
        try? context.save()
        XCTAssertFalse(photographed.hasNoDetails)
    }

    /// Whitespace-only text is not a detail: a visit whose notes are a stray space was still
    /// only ever a mark.
    func testWhitespaceOnlyDetailsStillCountAsBare() {
        let park = makePark("Alpha")
        let visit = log(park, on: date(2026, 3, 4))
        visit.notes = "   "
        visit.companions = "\n"
        visit.weatherSummary = " "
        XCTAssertTrue(visit.hasNoDetails)
    }

    func testClearingADateTakesTheVisitOffTheTimelineButLeavesTheParkVisited() {
        let park = makePark("Alpha")
        let visit = log(park, on: date(2026, 3, 4))

        XCTAssertEqual(
            StatsEngine.monthlyTimeline(parks: allParks(), monthsBack: 12, now: now, calendar: calendar)
                .reduce(0) { $0 + $1.count },
            1
        )

        visit.isUndated = true
        try? context.save()

        XCTAssertTrue(park.isVisited)
        XCTAssertEqual(park.visitCount, 1)
        XCTAssertEqual(
            StatsEngine.monthlyTimeline(parks: allParks(), monthsBack: 12, now: now, calendar: calendar)
                .reduce(0) { $0 + $1.count },
            0
        )
    }

    func testRestoringADatePutsTheVisitBack() {
        let park = makePark("Alpha")
        let visit = mark(park)
        visit.isUndated = false
        visit.date = date(2026, 3, 4)
        try? context.save()

        XCTAssertEqual(park.firstVisitDate, date(2026, 3, 4))
        XCTAssertEqual(
            StatsEngine.monthlyTimeline(parks: allParks(), monthsBack: 12, now: now, calendar: calendar)
                .reduce(0) { $0 + $1.count },
            1
        )
    }

    /// Visits already in the store predate the flag entirely, so they must keep their dates.
    func testAnOrdinaryVisitIsDatedByDefault() {
        let park = makePark("Alpha")
        let visit = Visit(date: date(2026, 3, 4), park: park)
        context.insert(visit)
        try? context.save()

        XCTAssertFalse(visit.isUndated)
        XCTAssertEqual(visit.knownDate, date(2026, 3, 4))
        XCTAssertEqual(park.firstVisitDate, date(2026, 3, 4))
    }
}
