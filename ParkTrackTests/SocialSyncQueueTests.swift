import XCTest
import SwiftData
@testable import ParkTrack

/// Pulling to refresh has to refresh, even when something else is already talking to
/// CloudKit.
///
/// The bug: `refreshAll` and `publishMyData` both began with `guard !isSyncing`, so either
/// one silently did nothing while the other ran. The first launch after a format bump
/// re-publishes an entire library — minutes — and every pull-to-refresh during it returned
/// instantly, having fetched nothing, looking exactly like a friend with nothing new. The
/// only way to see their latest was to quit the app and reopen it.
@MainActor
final class SocialSyncQueueTests: XCTestCase {

    /// Holds `publish` open until the test lets go, so a refresh can be attempted while a
    /// publish is genuinely in flight rather than in a timing window that may not exist.
    private final class GatedBackend: SocialBackend, @unchecked Sendable {
        var onPublishStarted: (@Sendable () -> Void)?
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var profileFetches = 0

        func openGate() { gate?.resume(); gate = nil }

        func fetchProfile(code: String) async throws -> FriendProfilePayload {
            profileFetches += 1
            return FriendProfilePayload(
                code: code,
                displayName: "Sam",
                totalParks: 1,
                totalVisits: 1,
                citiesCount: 1,
                currentStreakWeeks: 0,
                parksThisMonth: 0
            )
        }

        func fetchVisits(code: String, since: Date?) async throws -> [FriendVisitPayload] { [] }

        func publish(
            profile: FriendProfilePayload,
            visits: [FriendVisitPayload],
            progress: @Sendable @MainActor (Double) -> Void
        ) async throws {
            onPublishStarted?()
            await withCheckedContinuation { gate = $0 }
        }
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

    func testRefreshDuringAPublishIsQueuedRatherThanDropped() async throws {
        let friend = Friend(friendCode: "ABC234", displayName: "Sam")
        context.insert(friend)
        try context.save()

        let backend = GatedBackend()
        let service = SocialService(backend: backend, modelContext: context)

        let started = expectation(description: "publish started")
        backend.onPublishStarted = { started.fulfill() }
        let publishing = Task { await service.publishMyData(parks: [], profile: profile) }
        await fulfillment(of: [started], timeout: 2)

        let refreshing = Task { await service.refreshAll() }
        // Long enough for a dropped refresh to have returned and a queued one not to have.
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            backend.profileFetches, 0,
            "the refresh overlapped the publish; the two are supposed to take turns"
        )

        backend.openGate()
        await publishing.value
        await refreshing.value

        XCTAssertEqual(
            backend.profileFetches, 1,
            "pull-to-refresh was dropped because a publish was running, so a friend's latest "
                + "only appeared after quitting and reopening the app"
        )
    }

    /// Pulling repeatedly during a long publish should not queue a fetch per pull.
    func testRepeatedPullsJoinTheSameQueuedRefresh() async throws {
        let friend = Friend(friendCode: "ABC234", displayName: "Sam")
        context.insert(friend)
        try context.save()

        let backend = GatedBackend()
        let service = SocialService(backend: backend, modelContext: context)

        let started = expectation(description: "publish started")
        backend.onPublishStarted = { started.fulfill() }
        let publishing = Task { await service.publishMyData(parks: [], profile: profile) }
        await fulfillment(of: [started], timeout: 2)

        let pulls = (0..<4).map { _ in Task { await service.refreshAll() } }
        try await Task.sleep(for: .milliseconds(80))

        backend.openGate()
        await publishing.value
        for pull in pulls { await pull.value }

        XCTAssertEqual(
            backend.profileFetches, 1,
            "each pull queued its own fetch, so an impatient user multiplies the network work"
        )
    }
}
