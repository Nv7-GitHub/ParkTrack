import XCTest
import SwiftData
@testable import ParkTrack

/// Each list held against the figure that opens it.
///
/// The same rule the user's own breakdowns are tested by: a list that disagrees with its
/// headline is worse than no list, because it invites the reader to trust the smaller
/// number. Where the two genuinely cannot agree — a friend's numbers cover their whole
/// library, and only what they have shared can be listed — the sheet has to say so rather
/// than quietly showing the shorter answer.
@MainActor
final class FriendStatBreakdownTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var friend: Friend!

    override func setUp() {
        super.setUp()
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
        friend = Friend(friendCode: "ABC234", displayName: "Sam")
        context.insert(friend)
    }

    override func tearDown() {
        friend = nil
        context = nil
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func share(
        _ name: String,
        daysAgo: Double,
        place: String? = "Bellevue, WA",
        isUndated: Bool = false,
        latitude: Double = 47.6
    ) -> FriendVisit {
        let visit = FriendVisit(
            identifier: "\(name)-\(daysAgo)",
            parkName: name,
            latitude: latitude,
            longitude: -122.2,
            date: Date().addingTimeInterval(-daysAgo * 86_400)
        )
        visit.regionLabel = place
        visit.isUndated = isUndated
        visit.friend = friend
        context.insert(visit)
        return visit
    }

    private func rows(_ kind: FriendStatBreakdownSheet.Kind) -> [BreakdownRow.Model] {
        FriendStatBreakdownSheet(kind: kind, friend: friend).rows()
    }

    /// Two visits to one park are one park, and a park they only marked still counts as one.
    func testParksVisitedListsEachParkOnce() {
        share("Downtown", daysAgo: 1)
        share("Downtown", daysAgo: 8)
        share("Marked one", daysAgo: 0, isUndated: true)

        XCTAssertEqual(rows(.parksVisited).count, 2)
        XCTAssertEqual(
            rows(.parksVisited).last?.trailing, "No date",
            "the park they only marked should sit last, with no date claimed for it"
        )
    }

    /// Same name, different place, is not the same park.
    func testTwoParksSharingANameStayApart() {
        share("Memorial Park", daysAgo: 1, place: "Bellevue, WA", latitude: 47.6)
        share("Memorial Park", daysAgo: 2, place: "Austin, TX", latitude: 30.2)

        XCTAssertEqual(rows(.parksVisited).count, 2)
    }

    /// Matching the headline, which counts logged trips and not marks.
    func testTotalVisitsCountsDatedVisitsOnly() {
        share("Downtown", daysAgo: 1)
        share("Downtown", daysAgo: 8)
        share("Marked one", daysAgo: 0, isUndated: true)

        XCTAssertEqual(rows(.allVisits).count, 2)
    }

    func testCitiesCountParksNotVisits() {
        share("Downtown", daysAgo: 1, place: "Bellevue, WA")
        share("Downtown", daysAgo: 8, place: "Bellevue, WA")
        share("Zilker", daysAgo: 3, place: "Austin, TX")
        share("Unplaced", daysAgo: 4, place: nil)

        let cities = rows(.cities)
        XCTAssertEqual(cities.count, 2, "a visit with no place label is not a city")
        XCTAssertEqual(
            cities.first { $0.title == "Bellevue, WA" }?.trailing, Format.parkCount(1),
            "two visits to one park counted as two parks"
        )
    }

    func testStreakListsTheWeeksBehindIt() {
        share("This week", daysAgo: 1)
        share("Last week", daysAgo: 8)

        XCTAssertEqual(rows(.currentStreak).count, 2)
    }

    /// The honest case: they have shared less than their numbers describe.
    func testTheSheetSaysSoWhenTheListIsShorterThanTheFigure() {
        share("Downtown", daysAgo: 1)
        friend.totalParks = 40

        let sheet = FriendStatBreakdownSheet(kind: .parksVisited, friend: friend)
        let note = sheet.shortfallNote(rows: sheet.rows())

        XCTAssertNotNil(note, "40 parks and one row, with nothing said about the difference")
        XCTAssertEqual(note?.contains("40"), true)
    }

    /// And the ordinary case, where saying it would be noise.
    func testNothingIsSaidWhenTheListMatchesTheFigure() {
        share("Downtown", daysAgo: 1)
        friend.totalParks = 1

        let sheet = FriendStatBreakdownSheet(kind: .parksVisited, friend: friend)
        XCTAssertNil(sheet.shortfallNote(rows: sheet.rows()))
    }

    /// A friend's streak has to be the same arithmetic as your own, or two phones will
    /// disagree about one person with no way to tell which is right.
    func testAFriendsStreakUsesTheSameRuleAsYourOwn() {
        let calendar = Calendar.current
        let dates = [1.0, 8.0, 15.0].map { Date().addingTimeInterval(-$0 * 86_400) }
        for (index, date) in dates.enumerated() {
            let visit = share("Park \(index)", daysAgo: 0)
            visit.date = date
        }

        let mine = StatsEngine.streakWeeks(
            visits: dates.enumerated().map { (date: $0.element, parkKey: "Park \($0.offset)") },
            now: Date(),
            calendar: calendar
        ).current

        XCTAssertEqual(rows(.currentStreak).count, mine.count)
    }
}
