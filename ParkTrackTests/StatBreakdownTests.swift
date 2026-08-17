import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

/// Each headline figure on the Stats tab opens the set it counted. The one thing that must
/// never happen is the list disagreeing with the number that opened it, so every case is
/// held against the figure it belongs to.
@MainActor
final class StatBreakdownTests: XCTestCase {

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

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @discardableResult
    private func makePark(
        _ name: String,
        city: String? = nil,
        state: String? = nil,
        visits: [Date] = [],
        marked: Bool = false
    ) -> Park {
        let park = Park(
            identifier: Park.identity(name: name, coordinate: .init(latitude: 0, longitude: 0)),
            name: name,
            latitude: 0,
            longitude: 0
        )
        park.locality = city
        park.administrativeArea = state
        context.insert(park)
        for date in visits {
            context.insert(Visit(date: date, park: park))
        }
        if marked {
            context.insert(Visit.undated(park: park))
        }
        try? context.save()
        return park
    }

    private func allParks() -> [Park] {
        (try? context.fetch(FetchDescriptor<Park>())) ?? []
    }

    private func rows(_ kind: StatBreakdownSheet.Kind, records: Records) -> [BreakdownRow.Model] {
        _ = records
        return StatBreakdownSheet(kind: kind, parks: allParks(), origin: nil).rows()
    }

    /// A collection with a bit of everything: several cities, two states, parks discovered
    /// in different months and years, a park marked visited without a date, and one never
    /// visited at all.
    private func makeCollection(now: Date) {
        makePark("Alpha", city: "Redmond", state: "WA", visits: [date(2026, 6, 2), date(2026, 6, 9)])
        makePark("Beta", city: "Redmond", state: "WA", visits: [date(2026, 6, 16)])
        makePark("Gamma", city: "Bellevue", state: "WA", visits: [date(2026, 3, 4)])
        makePark("Delta", city: "Portland", state: "OR", visits: [date(2025, 8, 1)])
        makePark("Epsilon", city: "Redmond", state: "WA", marked: true)
        makePark("Zeta", city: "Seattle", state: "WA")
    }

    private var now: Date { date(2026, 6, 20) }

    private func records() -> Records {
        StatsEngine.records(parks: allParks(), origin: nil, now: now, calendar: calendar)
    }

    // MARK: - Every list matches its figure

    func testVisitedParksMatchesTheHeadline() {
        makeCollection(now: now)
        let records = records()
        XCTAssertEqual(rows(.visitedParks, records: records).count, records.totalParks)
        XCTAssertEqual(records.totalParks, 5, "Four dated, one marked; the unvisited one is out")
    }

    func testTotalVisitsMatchesTheHeadline() {
        makeCollection(now: now)
        let records = records()
        XCTAssertEqual(rows(.allVisits, records: records).count, records.totalVisits)
    }

    func testCitiesMatchesTheHeadline() {
        makeCollection(now: now)
        let records = records()
        let cities = rows(.cities, records: records)
        XCTAssertEqual(cities.count, records.distinctCities)
        XCTAssertEqual(Set(cities.map(\.title)), ["Redmond", "Bellevue", "Portland"])
        XCTAssertFalse(cities.contains { $0.title == "Seattle" }, "Somewhere never visited is not a city you've been to")
    }

    func testStatesMatchesTheHeadline() {
        makeCollection(now: now)
        let records = records()
        let states = rows(.states, records: records)
        XCTAssertEqual(states.count, records.distinctStates)
        XCTAssertEqual(Set(states.map(\.title)), ["WA", "OR"])
    }

    /// The busiest place leads, which is the order that makes a list of seventeen readable.
    func testCitiesAreOrderedByHowManyParksAreInThem() {
        makeCollection(now: now)
        XCTAssertEqual(rows(.cities, records: records()).first?.title, "Redmond")
    }

    // MARK: - Month and year

    func testNewThisMonthMatchesTheHeadline() {
        makeCollection(now: now)
        let records = records()
        // The sheet reads the real clock, so this only holds when the fixture's "now" is
        // today. Assert the rule instead: everything listed is a first visit in the month.
        let calendar = Calendar.current
        let listed = rows(.newThisMonth, records: records)
        for row in listed {
            let park = allParks().first { $0.identifier == row.id }
            XCTAssertNotNil(park?.firstVisitDate)
            XCTAssertTrue(calendar.isDate(park!.firstVisitDate!, equalTo: Date(), toGranularity: .month))
        }
    }

    func testAParkMarkedVisitedIsNeverANewDiscovery() {
        makePark("Marked", city: "Redmond", state: "WA", marked: true)
        let records = records()
        XCTAssertTrue(rows(.newThisMonth, records: records).isEmpty)
        XCTAssertTrue(rows(.newThisYear, records: records).isEmpty)
        XCTAssertEqual(rows(.visitedParks, records: records).count, 1, "…but it is still a park you've been to")
    }

    /// It has no day, so it cannot be sorted by one — it belongs after everything that can.
    func testAParkMarkedVisitedSortsLastAndSaysSo() {
        makePark("Dated", city: "Redmond", state: "WA", visits: [date(2026, 6, 2)])
        makePark("Marked", city: "Redmond", state: "WA", marked: true)

        let listed = rows(.visitedParks, records: records())
        XCTAssertEqual(listed.last?.title, "Marked")
        XCTAssertEqual(listed.last?.trailing, "No date")
    }

    func testUndatedVisitsSortToTheEndOfTheVisitList() {
        makePark("Dated", city: "Redmond", state: "WA", visits: [date(2026, 6, 2)])
        makePark("Marked", city: "Redmond", state: "WA", marked: true)

        let listed = rows(.allVisits, records: records())
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.last?.trailing, "No date")
    }

    // MARK: - Streaks

    func testStreakWeeksMatchTheStreakCounts() {
        // Three consecutive weeks, a gap, then two more ending in the current week.
        makePark("Alpha", city: "Redmond", state: "WA", visits: [
            date(2026, 4, 6), date(2026, 4, 13), date(2026, 4, 20),
            date(2026, 6, 8), date(2026, 6, 15)
        ])

        let counted = StatsEngine.streaks(parks: allParks(), now: now, calendar: calendar)
        let runs = StatsEngine.streakWeeks(parks: allParks(), now: now, calendar: calendar)

        XCTAssertEqual(runs.current.count, counted.currentWeeks, "The list has to be as long as the number")
        XCTAssertEqual(runs.longest.count, counted.longestWeeks)
        XCTAssertEqual(counted.longestWeeks, 3)
    }

    func testStreakWeeksAreConsecutiveAndCarryTheirCounts() {
        makePark("Alpha", city: "Redmond", state: "WA", visits: [
            date(2026, 6, 8), date(2026, 6, 9), date(2026, 6, 15)
        ])

        let runs = StatsEngine.streakWeeks(parks: allParks(), now: now, calendar: calendar)
        XCTAssertEqual(runs.longest.count, 2)
        XCTAssertEqual(runs.longest.first?.visits, 2, "Two visits in the first week")
        XCTAssertEqual(runs.longest.last?.visits, 1)

        for (earlier, later) in zip(runs.longest, runs.longest.dropFirst()) {
            let gap = calendar.dateComponents([.weekOfYear], from: earlier.start, to: later.start).weekOfYear
            XCTAssertEqual(gap, 1, "A streak's weeks have to actually be consecutive")
        }
    }

    func testAMarkedVisitDoesNotAppearInAStreak() {
        makePark("Marked", city: "Redmond", state: "WA", marked: true)
        let runs = StatsEngine.streakWeeks(parks: allParks(), now: now, calendar: calendar)
        XCTAssertTrue(runs.current.isEmpty)
        XCTAssertTrue(runs.longest.isEmpty)
    }

    // MARK: - Recency ordering, shared with Home's full visit list

    func testVisitsAreOrderedNewestFirstWithUndatedLast() {
        let park = makePark("Alpha", city: "Redmond", state: "WA", visits: [
            date(2026, 1, 5), date(2026, 6, 2), date(2025, 9, 9)
        ], marked: true)

        let ordered = (park.visits ?? []).orderedByRecency()
        XCTAssertEqual(ordered.count, 4)
        XCTAssertEqual(ordered.compactMap(\.knownDate), [date(2026, 6, 2), date(2026, 1, 5), date(2025, 9, 9)])
        XCTAssertTrue(ordered.last?.isUndated == true, "A visit nobody dated has no claim on being recent")
    }

    /// The stored `date` on an undated visit is the moment it was tapped, which is usually
    /// *now* — so ordering on it alone would put a decade-old park at the very top.
    func testAJustMarkedVisitDoesNotOutrankATodayLog() {
        let park = makePark("Alpha", city: "Redmond", state: "WA", visits: [Date()], marked: true)

        let ordered = (park.visits ?? []).orderedByRecency()
        XCTAssertFalse(ordered.first?.isUndated == true)
        XCTAssertTrue(ordered.last?.isUndated == true)
    }

    func testOrderingIsStableWhenNothingIsDated() {
        let park = makePark("Alpha", city: "Redmond", state: "WA")
        for _ in 0..<3 {
            context.insert(Visit.undated(park: park))
        }
        try? context.save()

        let ordered = (park.visits ?? []).orderedByRecency()
        XCTAssertEqual(ordered.count, 3)
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            XCTAssertGreaterThanOrEqual(earlier.createdAt, later.createdAt)
        }
    }

    // MARK: - Home's "Recently visited"

    /// Home cannot ask one sorted query for this, and a backlog is what proves it.
    ///
    /// A marked visit carries the moment it was tapped as its date, so a hundred parks
    /// ticked off this afternoon are the hundred newest rows by date — and with a fetch
    /// window they fill it completely, pushing every visit that actually happened off the
    /// front page.
    func testABacklogOfMarkedParksDoesNotCrowdOutRealVisitsOnHome() {
        let logged = makePark("Logged", city: "Redmond", state: "WA", visits: [date(2026, 6, 2)])
        for index in 0..<60 {
            makePark("Marked \(index)", city: "Redmond", state: "WA", marked: true)
        }

        let dated = (try? context.fetch(HomeView.datedVisitsDescriptor)) ?? []
        let marked = (try? context.fetch(HomeView.markedVisitsDescriptor)) ?? []
        let shown = Array((dated + marked).prefix(5))

        XCTAssertEqual(shown.first?.park?.identifier, logged.identifier, "A real visit leads")
        XCTAssertFalse(shown.first?.isUndated == true)
        XCTAssertEqual(shown.count, 5, "…and the marked ones still fill the space left over")
    }

    /// The window is a limit, not a filter: with plenty of real visits, none of the marked
    /// ones make the cut at all.
    func testMarkedParksOnlyFillSpaceLeftOver() {
        for index in 0..<8 {
            makePark("Logged \(index)", city: "Redmond", state: "WA", visits: [date(2026, 6, 1 + index)])
        }
        for index in 0..<8 {
            makePark("Marked \(index)", city: "Redmond", state: "WA", marked: true)
        }

        let dated = (try? context.fetch(HomeView.datedVisitsDescriptor)) ?? []
        let marked = (try? context.fetch(HomeView.markedVisitsDescriptor)) ?? []
        let shown = Array((dated + marked).prefix(5))

        XCTAssertTrue(shown.allSatisfy { !$0.isUndated })
        XCTAssertEqual(shown.map { $0.park?.name }, ["Logged 7", "Logged 6", "Logged 5", "Logged 4", "Logged 3"])
    }

    /// A user who has only ever marked parks still gets a section rather than an empty one.
    func testAMarkedOnlyCollectionStillFillsTheSection() {
        for index in 0..<3 {
            makePark("Marked \(index)", city: "Redmond", state: "WA", marked: true)
        }

        let dated = (try? context.fetch(HomeView.datedVisitsDescriptor)) ?? []
        let marked = (try? context.fetch(HomeView.markedVisitsDescriptor)) ?? []

        XCTAssertTrue(dated.isEmpty)
        XCTAssertEqual(marked.count, 3)
    }

    // MARK: - Empty

    func testEveryBreakdownIsEmptyForAnEmptyCollection() {
        let records = records()
        for kind in StatBreakdownSheet.Kind.allCases {
            XCTAssertTrue(rows(kind, records: records).isEmpty, "\(kind.title) should have nothing to show")
        }
    }
}
