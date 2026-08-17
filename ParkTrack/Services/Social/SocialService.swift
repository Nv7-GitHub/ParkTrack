import Foundation
import CoreLocation
import SwiftData
import Observation

/// The public shape of a person, as friends see it. Deliberately tiny: friends get
/// summary numbers, never the underlying parks database.
struct FriendProfilePayload: Codable {
    let code: String
    let displayName: String
    let totalParks: Int
    let totalVisits: Int
    let citiesCount: Int
    let currentStreakWeeks: Int
    let parksThisMonth: Int
}

/// One shared visit. Carries at most a single media attachment so a friend's whole
/// feed stays small enough to pull over cellular in one go.
struct FriendVisitPayload: Codable {
    let identifier: String
    let parkName: String
    let latitude: Double
    let longitude: Double
    let regionLabel: String?
    let date: Date
    let note: String
    let rating: Int
    let mediaData: Data?
    let mediaIsVideo: Bool
}

/// Where shared data actually lives. Two implementations ship: CloudKit for signed
/// builds, and an in-memory mock so the Friends UI is explorable everywhere else.
protocol SocialBackend: Sendable {
    func fetchProfile(code: String) async throws -> FriendProfilePayload
    func fetchVisits(code: String, since: Date?) async throws -> [FriendVisitPayload]
    func publish(profile: FriendProfilePayload, visits: [FriendVisitPayload]) async throws
}

/// Errors phrased for a person, not a log file. Anything a backend throws ends up
/// rendered verbatim in the Friends screen, so it has to read like a sentence.
enum SocialError: LocalizedError {
    case notFound
    case invalidCode
    case ownCode
    case alreadyAdded(String)
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "No one found with that code."
        case .invalidCode: "Friend codes are 6 characters, like AB3XY9."
        case .ownCode: "That's your own code. Share it with a friend instead."
        case .alreadyAdded(let name): "\(name) is already in your friends list."
        case .unavailable(let reason): reason
        case .failed(let reason): reason
        }
    }
}

/// Keeps the local `Friend` / `FriendVisit` mirror in step with whatever backend is
/// active.
///
/// The whole social layer is trust-based by design: there are no accounts and no
/// verification, just a 6-character code you hand to someone. Everything a friend
/// shares is mirrored into SwiftData on arrival so the feed and leaderboard render
/// instantly and keep working with no network.
@Observable
@MainActor
final class SocialService {
    /// Which backend is live. Surfaced so Settings can tell the truth about whether
    /// sharing actually reaches anyone.
    enum BackendKind {
        case cloudKit
        case mock

        var label: String {
            switch self {
            case .cloudKit: "iCloud"
            case .mock: "Sample data"
            }
        }

        /// False when friend data is local make-believe.
        var isLive: Bool { self == .cloudKit }
    }

    private let backend: SocialBackend
    private let modelContext: ModelContext

    let backendKind: BackendKind

    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var lastSyncedAt: Date?

    init(backend: SocialBackend, modelContext: ModelContext) {
        self.backend = backend
        self.modelContext = modelContext
        self.backendKind = backend is MockSocialBackend ? .mock : .cloudKit
    }

    /// CloudKit only when the build is genuinely entitled and signed into iCloud;
    /// the mock otherwise, so the simulator still has a populated Friends tab.
    static func makeDefault(modelContext: ModelContext) -> SocialService {
        if CloudKitAvailability.isUsable {
            return SocialService(backend: CloudKitSocialBackend(), modelContext: modelContext)
        }
        return SocialService(
            backend: MockSocialBackend(anchor: AppSettings().homeCoordinate),
            modelContext: modelContext
        )
    }

    // MARK: - Friends

    @discardableResult
    func addFriend(code rawCode: String) async -> Bool {
        lastError = nil
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard code.count == 6, code.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            lastError = SocialError.invalidCode.localizedDescription
            return false
        }
        guard code != ownFriendCode.uppercased() else {
            lastError = SocialError.ownCode.localizedDescription
            return false
        }
        if let existing = friend(withCode: code) {
            lastError = SocialError.alreadyAdded(existing.displayName).localizedDescription
            return false
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let profile = try await backend.fetchProfile(code: code)
            let friend = Friend(friendCode: code, displayName: displayName(for: profile))
            apply(profile, to: friend)
            modelContext.insert(friend)

            let visits = try await backend.fetchVisits(code: code, since: nil)
            merge(visits, into: friend)
            friend.lastSyncedAt = Date()

            save()
            lastSyncedAt = Date()
            return true
        } catch {
            lastError = message(for: error)
            return false
        }
    }

    func removeFriend(_ friend: Friend) {
        modelContext.delete(friend)
        save()
    }

    /// Re-pulls every friend's profile and any visits logged since we last heard from
    /// them. One friend failing never stops the rest.
    func refreshAll() async {
        guard !isSyncing else { return }
        let friends = allFriends()
        guard !friends.isEmpty else { return }

        isSyncing = true
        defer { isSyncing = false }
        lastError = nil

        var failures: [String] = []
        for friend in friends {
            do {
                let profile = try await backend.fetchProfile(code: friend.friendCode)
                apply(profile, to: friend)
                let visits = try await backend.fetchVisits(code: friend.friendCode, since: friend.lastSyncedAt)
                merge(visits, into: friend)
                friend.lastSyncedAt = Date()
            } catch {
                failures.append("\(friend.displayName): \(message(for: error))")
            }
        }

        save()
        lastSyncedAt = Date()
        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        }
    }

    // MARK: - Publishing

    /// Uploads the user's summary plus their visits. Only the most recent slice is
    /// shared, and each visit carries at most one attachment, so a friend pulling the
    /// feed downloads kilobytes rather than megabytes.
    func publishMyData(parks: [Park], profile: FriendProfilePayload) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        lastError = nil

        let payloads = visitPayloads(from: parks)
        do {
            try await backend.publish(profile: profile, visits: payloads)
            lastSyncedAt = Date()
        } catch {
            lastError = message(for: error)
        }
    }

    // MARK: - Local mirror

    private func allFriends() -> [Friend] {
        let descriptor = FetchDescriptor<Friend>(sortBy: [SortDescriptor(\.addedAt)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func friend(withCode code: String) -> Friend? {
        var descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.friendCode == code })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func apply(_ profile: FriendProfilePayload, to friend: Friend) {
        friend.displayName = displayName(for: profile)
        friend.totalParks = profile.totalParks
        friend.totalVisits = profile.totalVisits
        friend.citiesCount = profile.citiesCount
        friend.currentStreakWeeks = profile.currentStreakWeeks
        friend.parksThisMonth = profile.parksThisMonth
    }

    private func displayName(for profile: FriendProfilePayload) -> String {
        let trimmed = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? profile.code : trimmed
    }

    /// Upsert by identifier: incremental pulls overlap at the boundary, and a friend
    /// can edit a visit after sharing it, so the feed must never double up.
    private func merge(_ payloads: [FriendVisitPayload], into friend: Friend) {
        var existing: [String: FriendVisit] = [:]
        for visit in friend.visits ?? [] {
            existing[visit.identifier] = visit
        }

        for payload in payloads {
            let visit: FriendVisit
            if let known = existing[payload.identifier] {
                visit = known
            } else {
                visit = FriendVisit(
                    identifier: payload.identifier,
                    parkName: payload.parkName,
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    date: payload.date
                )
                visit.friend = friend
                modelContext.insert(visit)
                existing[payload.identifier] = visit
            }

            visit.parkName = payload.parkName
            visit.latitude = payload.latitude
            visit.longitude = payload.longitude
            visit.regionLabel = payload.regionLabel
            visit.date = payload.date
            visit.note = payload.note
            visit.rating = payload.rating
            visit.mediaData = payload.mediaData
            visit.mediaIsVideo = payload.mediaIsVideo
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            lastError = "Couldn't save friend data: \(error.localizedDescription)"
        }
    }

    // MARK: - Payload building

    private static let maxPublishedVisits = 200
    /// Above this, a video ships as its poster frame instead of the video itself.
    private static let maxAttachmentBytes = 5 * 1_024 * 1_024

    private func visitPayloads(from parks: [Park]) -> [FriendVisitPayload] {
        var payloads: [FriendVisitPayload] = []
        for park in parks {
            for visit in park.visits ?? [] {
                let shared = attachment(for: visit)
                payloads.append(
                    FriendVisitPayload(
                        identifier: visit.identifier.uuidString,
                        parkName: park.name,
                        latitude: park.latitude,
                        longitude: park.longitude,
                        regionLabel: park.regionLabel,
                        date: visit.date,
                        note: visit.notes,
                        rating: visit.rating,
                        mediaData: shared.data,
                        mediaIsVideo: shared.isVideo
                    )
                )
            }
        }
        return payloads
            .sorted { $0.date > $1.date }
            .prefix(Self.maxPublishedVisits)
            .map { $0 }
    }

    /// Photos win over video because they're already small; a heavy video degrades to
    /// its thumbnail rather than being dropped, so the feed still shows something.
    private func attachment(for visit: Visit) -> (data: Data?, isVideo: Bool) {
        let media = visit.sortedMedia

        if let photo = media.first(where: { !$0.isVideo }),
           let data = photo.data,
           data.count <= Self.maxAttachmentBytes {
            return (data, false)
        }

        if let video = media.first(where: { $0.isVideo }) {
            if let data = video.data, data.count <= Self.maxAttachmentBytes {
                return (data, true)
            }
            if let thumbnail = video.thumbnailData {
                return (thumbnail, false)
            }
        }

        return (nil, false)
    }

    // MARK: - Identity

    /// Read from the same defaults `AppSettings` writes to, so the service doesn't
    /// need the settings object injected just to know who "I" am.
    private var ownFriendCode: String {
        AppSettings().friendCode
    }

    private func message(for error: Error) -> String {
        if let social = error as? SocialError {
            return social.localizedDescription
        }
        return (error as NSError).localizedDescription
    }
}
