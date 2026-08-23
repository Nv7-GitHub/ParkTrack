import XCTest
import SwiftData
@testable import ParkTrack

/// What actually leaves the phone, and what the app then believes it has sent.
///
/// All of these were invisible from the inside: publishing reported success, the progress
/// bar filled, and the gap only existed on somebody else's phone.
@MainActor
final class SocialPublishTests: XCTestCase {

    /// Records what it was handed rather than doing anything with it.
    private final class RecordingBackend: SocialBackend, @unchecked Sendable {
        private(set) var publishedBatches: [[String]] = []
        private(set) var deleted: [String] = []
        private(set) var askedSince: [Date?] = []
        /// What the far end is pretending to hold, for deletion reconciliation.
        var remoteIdentifiers: Set<String>?
        var enumerationSupported = true
        var failNextPublish = false

        var publishedIdentifiers: [String] { publishedBatches.flatMap { $0 } }

        func fetchProfile(code: String) async throws -> FriendProfilePayload {
            FriendProfilePayload(
                code: code,
                displayName: "Sam",
                totalParks: 0,
                totalVisits: 0,
                citiesCount: 0,
                currentStreakWeeks: 0,
                parksThisMonth: 0
            )
        }

        func fetchVisits(code: String, since: Date?) async throws -> [FriendVisitPayload] {
            askedSince.append(since)
            return []
        }

        func visitIdentifiers(code: String) async throws -> Set<String>? {
            enumerationSupported ? (remoteIdentifiers ?? []) : nil
        }

        func deleteVisits(identifiers: [String]) async throws {
            deleted.append(contentsOf: identifiers)
        }

        func publish(
            profile: FriendProfilePayload,
            visits: [FriendVisitPayload],
            progress: @Sendable @MainActor (Double) -> Void
        ) async throws {
            publishedBatches.append(visits.map(\.identifier))
            if failNextPublish {
                failNextPublish = false
                throw SocialError.failed("no")
            }
        }
    }

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
        // Publishing bookkeeping lives in UserDefaults and outlives a test otherwise.
        SocialService(backend: RecordingBackend(), modelContext: context).forgetPublishedState()
    }

    override func tearDown() {
        SocialService(backend: RecordingBackend(), modelContext: context).forgetPublishedState()
        context = nil
        container = nil
        super.tearDown()
    }

    private var profile: FriendProfilePayload {
        FriendProfilePayload(
            code: "ME1234",
            displayName: "Me",
            totalParks: 0,
            totalVisits: 0,
            citiesCount: 0,
            currentStreakWeeks: 0,
            parksThisMonth: 0
        )
    }

    @discardableResult
    private func makeVisitedPark(_ index: Int) -> Park {
        let park = Park(
            identifier: "park-\(index)",
            name: "Park \(index)",
            latitude: Double(index) * 0.001,
            longitude: Double(index) * 0.001
        )
        context.insert(park)
        let visit = Visit(date: Date().addingTimeInterval(-Double(index) * 3_600), park: park)
        context.insert(visit)
        return park
    }

    private func allParks() -> [Park] {
        (try? context.fetch(FetchDescriptor<Park>())) ?? []
    }

    /// A whole library goes, however long it is.
    ///
    /// There used to be a cap of two hundred per publish, and — worse — every visit in the
    /// library was recorded as published whether or not it had been sent. The ones dropped
    /// past the cap then looked identical to visits that had genuinely landed, so nothing
    /// ever offered them again: a longer history shared its first slice and abandoned the
    /// rest for good. 201 because that is one more than the cap that used to be here.
    func testAnEntireLibraryIsPublishedHoweverLongItIs() async {
        for index in 0..<201 { makeVisitedPark(index) }
        try? context.save()

        let backend = RecordingBackend()
        let service = SocialService(backend: backend, modelContext: context)

        await service.publishMyData(parks: allParks(), profile: profile)

        XCTAssertEqual(
            Set(backend.publishedIdentifiers).count, 201,
            "some of the library was held back, and nothing records which"
        )
    }

    /// The guarantee that made the old cap survivable, and the one that keeps any future
    /// truncation — a failure partway, a batch rejected — from costing a visit permanently.
    func testOnlyVisitsThatWereSentAreRecordedAsPublished() async {
        for index in 0..<3 { makeVisitedPark(index) }
        try? context.save()

        let backend = RecordingBackend()
        backend.failNextPublish = true
        let service = SocialService(backend: backend, modelContext: context)

        await service.publishMyData(parks: allParks(), profile: profile)
        XCTAssertNotNil(service.lastError, "a failed publish reported success")

        await service.publishMyData(parks: allParks(), profile: profile)

        XCTAssertEqual(
            Set(backend.publishedBatches.last ?? []).count, 3,
            "a publish that failed still counted its visits as shared, so they would never be "
                + "offered again"
        )
    }

    /// Nothing unchanged goes up twice.
    func testASecondPublishOfAnUnchangedLibrarySendsNothing() async {
        for index in 0..<3 { makeVisitedPark(index) }
        try? context.save()

        let backend = RecordingBackend()
        let service = SocialService(backend: backend, modelContext: context)

        await service.publishMyData(parks: allParks(), profile: profile)
        await service.publishMyData(parks: allParks(), profile: profile)

        XCTAssertEqual(backend.publishedBatches.count, 2)
        XCTAssertEqual(backend.publishedBatches[0].count, 3)
        XCTAssertEqual(
            backend.publishedBatches[1], [],
            "unchanged visits were re-uploaded; a first share is minutes of someone's data plan"
        )
    }

    /// Deleting a visit has to withdraw it, or a photo cannot be taken back.
    func testDeletingAVisitWithdrawsItFromTheBackend() async {
        for index in 0..<3 { makeVisitedPark(index) }
        try? context.save()

        let backend = RecordingBackend()
        let service = SocialService(backend: backend, modelContext: context)
        await service.publishMyData(parks: allParks(), profile: profile)

        let doomed = allParks()[1]
        let identifier = (doomed.visits ?? []).first!.identifier.uuidString
        for visit in doomed.visits ?? [] { context.delete(visit) }
        context.delete(doomed)
        try? context.save()

        await service.publishMyData(parks: allParks(), profile: profile)

        XCTAssertEqual(
            backend.deleted, [identifier],
            "a deleted visit stayed published, so friends keep showing something the user "
                + "removed and nothing can ever take it down"
        )
    }
}

/// Reconciling what a friend has deleted, and the cursor the incremental pull asks with.
@MainActor
final class SocialRefreshTests: XCTestCase {

    private final class StubBackend: SocialBackend, @unchecked Sendable {
        var remoteIdentifiers: Set<String>?
        private(set) var askedSince: [Date?] = []

        func fetchProfile(code: String) async throws -> FriendProfilePayload {
            FriendProfilePayload(
                code: code,
                displayName: "Sam",
                totalParks: 0,
                totalVisits: 0,
                citiesCount: 0,
                currentStreakWeeks: 0,
                parksThisMonth: 0
            )
        }

        func fetchVisits(code: String, since: Date?) async throws -> [FriendVisitPayload] {
            askedSince.append(since)
            return []
        }

        func visitIdentifiers(code: String) async throws -> Set<String>? { remoteIdentifiers }

        func publish(
            profile: FriendProfilePayload,
            visits: [FriendVisitPayload],
            progress: @Sendable @MainActor (Double) -> Void
        ) async throws {}
    }

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

    @discardableResult
    private func makeFriend(withVisits identifiers: [String]) -> Friend {
        let friend = Friend(friendCode: "ABC234", displayName: "Sam")
        context.insert(friend)
        for identifier in identifiers {
            let visit = FriendVisit(
                identifier: identifier,
                parkName: identifier,
                latitude: 0,
                longitude: 0,
                date: Date()
            )
            visit.friend = friend
            context.insert(visit)
        }
        try? context.save()
        return friend
    }

    private func mirroredIdentifiers(_ friend: Friend) -> Set<String> {
        Set((friend.visits ?? []).map(\.identifier))
    }

    func testAVisitTheFriendDeletedStopsBeingMirrored() async {
        let friend = makeFriend(withVisits: ["kept", "withdrawn"])
        let backend = StubBackend()
        backend.remoteIdentifiers = ["kept"]

        await SocialService(backend: backend, modelContext: context).refreshAll()

        XCTAssertEqual(
            mirroredIdentifiers(friend), ["kept"],
            "a visit the friend deleted stayed on this phone forever; deletions cannot arrive "
                + "through an incremental pull, so nothing else would ever remove it"
        )
    }

    /// The dangerous direction: an answer that could not be given must delete nothing.
    func testAnUnknownAnswerDeletesNothing() async {
        let friend = makeFriend(withVisits: ["one", "two"])
        let backend = StubBackend()
        backend.remoteIdentifiers = nil

        await SocialService(backend: backend, modelContext: context).refreshAll()

        XCTAssertEqual(
            mirroredIdentifiers(friend), ["one", "two"],
            "a backend that could not enumerate was read as 'they have deleted everything'"
        )
    }

    /// The cursor reaches back, because the two clocks it spans were never synchronised.
    func testTheCursorReachesBackBeyondTheLastPull() {
        let lastSynced = Date()
        let cursor = SocialService.cursor(from: lastSynced)
        XCTAssertNotNil(cursor)
        XCTAssertLessThan(
            cursor ?? .distantFuture, lastSynced,
            "the pull asks for exactly what it has already seen, so a phone running fast steps "
                + "over records written while it was syncing and never asks again"
        )
        XCTAssertNil(SocialService.cursor(from: nil), "a first pull must stay a full one")
    }
}
