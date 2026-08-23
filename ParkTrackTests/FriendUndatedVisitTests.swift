import XCTest
import SwiftData
@testable import ParkTrack

/// The friend-facing half of `UndatedVisitTests`: a park somebody merely marked has to
/// travel as a mark, and read as one on the other end.
///
/// The bug: `FriendVisit` carried only a date, and an undated visit's date is the moment
/// its owner tapped. So clearing a backlog put a hundred parks at the very top of a
/// friend's feed, dated this afternoon, above every trip that actually happened — the same
/// failure the local app had already been fixed for, reproduced across the wire.
@MainActor
final class FriendUndatedVisitTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

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

    private func makeVisit(_ name: String, daysAgo: Double, isUndated: Bool) -> FriendVisit {
        let visit = FriendVisit(
            identifier: name,
            parkName: name,
            latitude: 0,
            longitude: 0,
            date: Date().addingTimeInterval(-daysAgo * 86_400)
        )
        visit.isUndated = isUndated
        context.insert(visit)
        return visit
    }

    /// A mark tapped seconds ago must not outrank a trip logged yesterday.
    func testMarkedVisitsSortBelowDatedOnesHoweverRecent() {
        let markedNow = makeVisit("Marked today", daysAgo: 0, isUndated: true)
        let tripYesterday = makeVisit("Trip yesterday", daysAgo: 1, isUndated: false)
        let tripLastYear = makeVisit("Trip last year", daysAgo: 365, isUndated: false)

        let ordered = [markedNow, tripYesterday, tripLastYear].orderedByRecency()

        XCTAssertEqual(
            ordered.map(\.parkName),
            ["Trip yesterday", "Trip last year", "Marked today"],
            "a marked park sorted above real trips on the strength of a timestamp that means nothing"
        )
    }

    /// Among themselves the marked ones keep their only ordering.
    func testMarkedVisitsKeepNewestFirstAmongThemselves() {
        let older = makeVisit("Marked first", daysAgo: 10, isUndated: true)
        let newer = makeVisit("Marked second", daysAgo: 2, isUndated: true)

        XCTAssertEqual(
            [older, newer].orderedByRecency().map(\.parkName),
            ["Marked second", "Marked first"]
        )
    }

    /// Everything mirrored before the flag existed decodes as a dated trip, which is
    /// exactly how it behaved — the upgrade must not silently reclassify anyone's history.
    func testVisitsDefaultToDated() {
        let visit = makeVisit("No flag set", daysAgo: 3, isUndated: false)
        XCTAssertFalse(visit.isUndated)
        XCTAssertFalse(
            FriendVisitPayload(
                identifier: "x",
                parkName: "x",
                latitude: 0,
                longitude: 0,
                regionLabel: nil,
                date: Date(),
                note: "",
                rating: 0,
                mediaData: nil,
                mediaIsVideo: false
            ).isUndated,
            "the payload's default changed; a build that predates the field would start "
                + "publishing every visit as a mark"
        )
    }
}

/// The upgrade that repairs what is already out there.
///
/// Both halves are needed and neither is obvious. Publishing skips visits whose signature
/// has not moved, and nothing about an old visit moves when the *format* changes — so the
/// sender has to be told to disbelieve its record once. Pulling asks for `date > lastSynced`
/// and a corrected visit keeps its date, so the receiver has to be told to forget its cursor
/// once. Miss either and the backlog stays wrong on the far end forever.
@MainActor
final class SocialMirrorUpgradeTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "social.mirror.upgrade.tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testUpgradeIsClaimedOnceAndOnlyOnce() {
        XCTAssertTrue(
            SocialService.claimMirrorUpgrade(defaults: defaults),
            "an install that has never seen this format version must re-pull"
        )
        XCTAssertFalse(
            SocialService.claimMirrorUpgrade(defaults: defaults),
            "the claim was not recorded, so every refresh would drag the whole mirror down again"
        )
    }

    func testAnInstallAlreadyAtTheCurrentVersionDoesNotRePull() {
        defaults.set(SocialService.mirrorFormatVersion, forKey: "social.mirrorFormatVersion")
        XCTAssertFalse(SocialService.claimMirrorUpgrade(defaults: defaults))
    }

    /// The key the sending half reads. Bumping one without the other leaves the two ends
    /// disagreeing about what has been exchanged, which is invisible until a friend's feed
    /// is quietly missing a month.
    func testAnOlderVersionStillTriggersTheUpgrade() {
        defaults.set(SocialService.mirrorFormatVersion - 1, forKey: "social.mirrorFormatVersion")
        XCTAssertTrue(SocialService.claimMirrorUpgrade(defaults: defaults))
    }
}
