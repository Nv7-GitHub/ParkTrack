import Foundation
import CloudKit

/// Whether this build can talk to CloudKit at all.
///
/// `CKContainer.default()` traps when the app isn't signed with an iCloud container
/// entitlement, so the entitlement has to be confirmed *before* touching CloudKit —
/// hence reading it out of the embedded provisioning profile. Anything ambiguous
/// (simulator, unsigned build, unparsable profile) counts as unavailable, which is
/// the safe answer: the mock backend still gives a working Friends tab.
enum CloudKitAvailability {
    /// Why sharing is or isn't live.
    ///
    /// Worth separating, because the two ways of being unavailable have nothing in common.
    /// A missing entitlement is a mistake in the build and every single person running it is
    /// affected; a missing iCloud account is one person's Settings app. Reporting both as
    /// "unavailable" turns a five-minute answer into an afternoon of guessing which one a
    /// tester has hit.
    enum Status: Equatable {
        case live
        /// The build itself cannot reach CloudKit. Nobody running it can share anything.
        case notEntitled
        /// The build is fine; this device has no iCloud account signed in.
        case notSignedIn

        var isLive: Bool { self == .live }
    }

    static var status: Status {
        guard hasICloudEntitlement else { return .notEntitled }
        guard FileManager.default.ubiquityIdentityToken != nil else { return .notSignedIn }
        return .live
    }

    static var isUsable: Bool { status.isLive }

    static let hasICloudEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<plist"),
              let end = raw.range(of: "</plist>"),
              let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        else { return false }
        return !containers.isEmpty
    }()
}

/// Sharing over the public CloudKit database.
///
/// The public database is the right fit for a trust-based, code-only friends model:
/// anyone holding a 6-character code can read that profile, and nobody needs to
/// accept an invitation or manage a share. Records are keyed so a re-publish
/// overwrites rather than accumulates — profiles by friend code, visits by the
/// visit's own identifier.
struct CloudKitSocialBackend: SocialBackend {
    private enum RecordType {
        static let profile = "Profile"
        static let visit = "FriendVisit"
    }

    /// CloudKit rejects oversized batches, and a feed pull that big isn't worth it.
    private static let visitFetchLimit = 200
    private static let saveBatchSize = 150

    private var database: CKDatabase {
        CKContainer.default().publicCloudDatabase
    }

    // MARK: - Fetching

    func fetchProfile(code: String) async throws -> FriendProfilePayload {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: code))
            return FriendProfilePayload(
                code: record["code"] as? String ?? code,
                displayName: record["displayName"] as? String ?? code,
                totalParks: record["totalParks"] as? Int ?? 0,
                totalVisits: record["totalVisits"] as? Int ?? 0,
                citiesCount: record["citiesCount"] as? Int ?? 0,
                currentStreakWeeks: record["currentStreakWeeks"] as? Int ?? 0,
                parksThisMonth: record["parksThisMonth"] as? Int ?? 0,
                regions: Self.decodeList(record["regions"], as: RegionProgressPayload.self),
                excludedPlaces: Self.decodeList(record["excludedPlaces"], as: ExcludedPlacePayload.self)
            )
        } catch {
            throw Self.socialError(from: error)
        }
    }

    func fetchVisits(code: String, since: Date?) async throws -> [FriendVisitPayload] {
        let predicate: NSPredicate
        if let since {
            predicate = NSPredicate(format: "code == %@ AND date > %@", code, since as NSDate)
        } else {
            predicate = NSPredicate(format: "code == %@", code)
        }

        let query = CKQuery(recordType: RecordType.visit, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

        do {
            let (matches, _) = try await database.records(
                matching: query,
                resultsLimit: Self.visitFetchLimit
            )
            return matches.compactMap { _, result in
                guard let record = try? result.get() else { return nil }
                return Self.payload(from: record)
            }
        } catch {
            throw Self.socialError(from: error)
        }
    }

    // MARK: - Publishing

    func publish(profile: FriendProfilePayload, visits: [FriendVisitPayload]) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parktrack-publish-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var records: [CKRecord] = [Self.record(from: profile)]
        for visit in visits {
            records.append(Self.record(from: visit, code: profile.code, scratch: scratch))
        }

        do {
            for batch in stride(from: 0, to: records.count, by: Self.saveBatchSize) {
                let slice = Array(records[batch..<min(batch + Self.saveBatchSize, records.count)])
                _ = try await database.modifyRecords(
                    saving: slice,
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: false
                )
            }
        } catch {
            throw Self.socialError(from: error)
        }
    }

    // MARK: - Record mapping

    private static func record(from profile: FriendProfilePayload) -> CKRecord {
        let record = CKRecord(
            recordType: RecordType.profile,
            recordID: CKRecord.ID(recordName: profile.code)
        )
        record["code"] = profile.code
        record["displayName"] = profile.displayName
        record["totalParks"] = profile.totalParks
        record["totalVisits"] = profile.totalVisits
        record["citiesCount"] = profile.citiesCount
        record["currentStreakWeeks"] = profile.currentStreakWeeks
        record["parksThisMonth"] = profile.parksThisMonth
        // Lists travel as JSON in a bytes field. CloudKit has no record type for an array
        // of structs, and splitting these into child records would mean a second query per
        // friend to render one row. Both lists are tens of entries at most.
        record["regions"] = Self.encodeList(profile.regions)
        record["excludedPlaces"] = Self.encodeList(profile.excludedPlaces)
        return record
    }

    // MARK: - List fields

    private static func encodeList<T: Encodable>(_ value: [T]) -> Data? {
        guard !value.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    private static func decodeList<Element: Decodable>(_ field: Any?, as type: Element.Type) -> [Element] {
        guard let data = field as? Data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Element].self, from: data)) ?? []
    }

    private static func record(
        from visit: FriendVisitPayload,
        code: String,
        scratch: URL
    ) -> CKRecord {
        let record = CKRecord(
            recordType: RecordType.visit,
            recordID: CKRecord.ID(recordName: visit.identifier)
        )
        record["code"] = code
        record["identifier"] = visit.identifier
        record["parkName"] = visit.parkName
        record["latitude"] = visit.latitude
        record["longitude"] = visit.longitude
        record["regionLabel"] = visit.regionLabel
        record["date"] = visit.date
        record["note"] = visit.note
        record["rating"] = visit.rating
        record["mediaIsVideo"] = visit.mediaIsVideo ? 1 : 0

        if let data = visit.mediaData {
            let url = scratch.appendingPathComponent("\(visit.identifier).bin")
            if (try? data.write(to: url)) != nil {
                record["media"] = CKAsset(fileURL: url)
            }
        }
        return record
    }

    private static func payload(from record: CKRecord) -> FriendVisitPayload {
        var mediaData: Data?
        if let asset = record["media"] as? CKAsset, let url = asset.fileURL {
            mediaData = try? Data(contentsOf: url)
        }
        return FriendVisitPayload(
            identifier: record["identifier"] as? String ?? record.recordID.recordName,
            parkName: record["parkName"] as? String ?? "",
            latitude: record["latitude"] as? Double ?? 0,
            longitude: record["longitude"] as? Double ?? 0,
            regionLabel: record["regionLabel"] as? String,
            date: record["date"] as? Date ?? record.creationDate ?? Date(),
            note: record["note"] as? String ?? "",
            rating: record["rating"] as? Int ?? 0,
            mediaData: mediaData,
            mediaIsVideo: (record["mediaIsVideo"] as? Int ?? 0) == 1
        )
    }

    // MARK: - Errors

    /// CloudKit's own messages are written for developers. Translate the handful that
    /// a TestFlight user can actually hit into something actionable.
    private static func socialError(from error: Error) -> SocialError {
        guard let ckError = error as? CKError else {
            return .failed((error as NSError).localizedDescription)
        }
        switch ckError.code {
        case .unknownItem:
            return .notFound
        case .notAuthenticated:
            return .unavailable("Sign in to iCloud in Settings to share with friends.")
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return .unavailable("Can't reach iCloud right now. Try again in a moment.")
        case .quotaExceeded:
            return .failed("Your iCloud storage is full, so sharing didn't go through.")
        case .permissionFailure:
            return .unavailable("This build doesn't have permission to use iCloud sharing.")
        case .zoneNotFound, .invalidArguments, .badContainer, .missingEntitlement:
            return .unavailable("iCloud sharing isn't set up in this build.")
        default:
            return .failed(ckError.localizedDescription)
        }
    }
}
