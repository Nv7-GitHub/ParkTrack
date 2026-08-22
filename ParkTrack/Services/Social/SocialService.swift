import Foundation
import CoreLocation
import SwiftData
import Observation
#if canImport(UIKit)
import UIKit
import ImageIO
#endif

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
    /// Per-place standings. Both sides of a race count against the same `total`, which comes
    /// from whoever indexed the region — without that the comparison would just reflect who
    /// had wandered across more ground.
    var regions: [RegionProgressPayload] = []
    /// Places this person has struck off.
    ///
    /// Published so a race can subtract the union of both sides' rejections and leave the
    /// two percentages describing the same thing. Two people who have rejected different
    /// places are otherwise counting against different totals without either of them being
    /// told. Nothing is applied to anybody's catalogue on the strength of this — adopting a
    /// friend's rejections is a separate, deliberate act.
    var excludedPlaces: [ExcludedPlacePayload] = []
}

/// One place a person says is not a park, as it travels between friends.
struct ExcludedPlacePayload: Codable {
    let identifier: String
    let name: String
    let latitude: Double
    let longitude: Double
    let excludedAt: Date
}

struct RegionProgressPayload: Codable {
    let identifier: String
    let name: String
    let kind: String
    let visited: Int
    let total: Int
}

extension SocialBackend {
    func updateIndexedRegions(_ regions: [RegionProgressPayload]) async {}
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
    /// Lets a backend know which places the user has indexed. Only the mock uses it — it has
    /// no other way to invent a plausible opponent for a race — and the default is a no-op.
    func updateIndexedRegions(_ regions: [RegionProgressPayload]) async
    func fetchProfile(code: String) async throws -> FriendProfilePayload
    func fetchVisits(code: String, since: Date?) async throws -> [FriendVisitPayload]
    /// `progress` is called as batches land, from 0 to 1, so a screen can say how far in it
    /// is. A first share of a whole library is minutes of uploading, and an app that shows
    /// nothing for minutes looks broken rather than busy.
    func publish(
        profile: FriendProfilePayload,
        visits: [FriendVisitPayload],
        progress: @Sendable @MainActor (Double) -> Void
    ) async throws
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

    /// Sharing is two pieces of work, and they take about as long as each other.
    ///
    /// Reported apart because reporting them together was worse than reporting nothing: the
    /// bar sat at zero through the whole of the first phase — which is CPU-bound and silent
    /// — and then jumped to done. It looked broken, and it was describing the wrong work.
    enum PublishPhase: Equatable {
        case preparing
        case uploading

        var label: String {
            switch self {
            case .preparing: "Preparing photos"
            case .uploading: "Sharing your visits"
            }
        }
    }

    private(set) var isSyncing = false
    private(set) var publishPhase: PublishPhase?
    /// 0 to 1 within the current phase, nil when nothing is being shared.
    private(set) var publishProgress: Double?
    /// Roughly how much is going up, so the screen can say more than a percentage.
    private(set) var publishBytes: Int64 = 0
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
    /// Tells the backend what the user has indexed before pulling, so a race has the same
    /// denominator on both sides.
    private func shareIndexedRegions() async {
        let indexes = ((try? modelContext.fetch(FetchDescriptor<RegionIndex>())) ?? []).filter(\.isIndexed)
        guard !indexes.isEmpty else { return }
        let payloads = indexes.map {
            RegionProgressPayload(
                identifier: $0.identifier,
                name: $0.displayName,
                kind: $0.kind.rawValue,
                visited: 0,
                total: $0.parkCount
            )
        }
        await backend.updateIndexedRegions(payloads)
    }

    func refreshAll() async {
        await shareIndexedRegions()
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

        defer {
            publishPhase = nil
            publishProgress = nil
            publishBytes = 0
        }

        publishPhase = .preparing
        publishProgress = 0
        let payloads = await visitPayloads(from: parks) { [weak self] fraction in
            self?.publishProgress = fraction
        }

        publishPhase = .uploading
        publishProgress = 0
        publishBytes = payloads.reduce(Int64(0)) { $0 + Int64($1.mediaData?.count ?? 0) }

        do {
            try await backend.publish(profile: profile, visits: payloads) { [weak self] fraction in
                self?.publishProgress = fraction
            }
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
        applyRegions(profile.regions, to: friend)
        applyExclusions(profile.excludedPlaces, to: friend)
    }

    /// Upsert by identifier, so a friend who changes their mind about a place and readmits
    /// it stops it being offered here too.
    private func applyExclusions(_ payloads: [ExcludedPlacePayload], to friend: Friend) {
        var existing: [String: FriendExclusion] = [:]
        for exclusion in friend.exclusions ?? [] {
            existing[exclusion.identifier] = exclusion
        }

        for payload in payloads {
            if let current = existing.removeValue(forKey: payload.identifier) {
                current.name = payload.name
                current.latitude = payload.latitude
                current.longitude = payload.longitude
                current.excludedAt = payload.excludedAt
            } else {
                let exclusion = FriendExclusion(
                    identifier: payload.identifier,
                    name: payload.name,
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    excludedAt: payload.excludedAt
                )
                exclusion.friend = friend
                modelContext.insert(exclusion)
            }
        }

        for stale in existing.values {
            modelContext.delete(stale)
        }
    }

    /// Upsert by region identifier so a friend's standing in a place is replaced, not
    /// appended to, and places they no longer report drop away.
    private func applyRegions(_ payloads: [RegionProgressPayload], to friend: Friend) {
        var existing: [String: FriendRegionProgress] = [:]
        for progress in friend.regions ?? [] {
            existing[progress.regionIdentifier] = progress
        }

        for payload in payloads {
            let kind = RegionKind(rawValue: payload.kind) ?? .city
            if let current = existing.removeValue(forKey: payload.identifier) {
                current.regionName = payload.name
                current.kindRaw = kind.rawValue
                current.visited = payload.visited
                current.total = payload.total
                current.updatedAt = Date()
            } else {
                let progress = FriendRegionProgress(
                    regionIdentifier: payload.identifier,
                    regionName: payload.name,
                    kind: kind,
                    visited: payload.visited,
                    total: payload.total
                )
                progress.friend = friend
                modelContext.insert(progress)
            }
        }

        for stale in existing.values {
            modelContext.delete(stale)
        }
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

    /// The longest edge a shared photo is reduced to before it leaves the device.
    ///
    /// A feed draws these a few hundred points across at most, so the original is orders of
    /// magnitude more than anyone sees. Sharing it anyway cost three times over: the upload,
    /// the copy CloudKit stages on this device to make that upload, and the download for
    /// every friend who scrolls past. A library of a hundred megabytes was publishing most
    /// of itself the moment the Friends tab appeared.
    ///
    /// It is also the more careful thing to do. These go to the public database, where the
    /// only key is a six-character code, and a full-resolution original carries rather more
    /// than a picture of a park — including, in its metadata, where it was taken.
    private static let sharedImageMaxPixels = 1_400

    /// Builds what will be shared, re-encoding each photo off the main thread.
    ///
    /// One attachment at a time rather than all of them: the originals are the largest thing
    /// the app owns, and gathering a whole library before starting would pull every
    /// photograph through memory at once. Reading a blob has to happen here, on the actor
    /// that owns the store, but the decode-scale-encode after it does not — and that is the
    /// part that costs tenths of a second each and used to freeze the tab.
    private func visitPayloads(
        from parks: [Park],
        progress: @MainActor (Double) -> Void
    ) async -> [FriendVisitPayload] {
        let candidates = parks.flatMap { park in (park.visits ?? []).map { (park, $0) } }
        var payloads: [FriendVisitPayload] = []

        for (index, pair) in candidates.enumerated() {
            let (park, visit) = pair
            let shared = await attachment(for: visit)
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
            progress(Double(index + 1) / Double(max(candidates.count, 1)))
        }
        return payloads
            .sorted { $0.date > $1.date }
            .prefix(Self.maxPublishedVisits)
            .map { $0 }
    }

    /// Photos win over video because they're already small; a heavy video degrades to
    /// its thumbnail rather than being dropped, so the feed still shows something.
    private func attachment(for visit: Visit) async -> (data: Data?, isVideo: Bool) {
        let media = visit.sortedMedia

        if let photo = media.first(where: { !$0.isVideo }), let data = photo.data {
            let scaled = await Task.detached(priority: .userInitiated) {
                Self.feedSized(data)
            }.value
            return (scaled ?? (data.count <= Self.maxAttachmentBytes ? data : nil), false)
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

    /// Re-encodes a photo at feed size, dropping its metadata with it.
    ///
    /// Returns nil if the image cannot be read, which leaves the caller to decide whether the
    /// original is small enough to send as it is.
    private nonisolated static func feedSized(_ data: Data) -> Data? {
        #if canImport(UIKit)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sharedImageMaxPixels
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: scaled).jpegData(compressionQuality: 0.8)
        #else
        return nil
        #endif
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
