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

    /// The account half of the answer, as CloudKit last reported it.
    ///
    /// Optimistic before anyone has asked. `accountStatus` is asynchronous and the screens
    /// want an answer while they are rendering, so the gap is filled by assuming an account
    /// exists — the honest direction to be wrong in, because a real request then fails with
    /// a real message instead of the app quietly deciding for itself that sharing is off.
    @MainActor private static var accountLooksUsable = true

    @MainActor static var status: Status {
        guard hasICloudEntitlement else { return .notEntitled }
        return accountLooksUsable ? .live : .notSignedIn
    }

    /// Asks CloudKit itself whether there is an account, and caches the answer.
    ///
    /// This used to be `FileManager.ubiquityIdentityToken`, which is a different question:
    /// that token is iCloud *Drive's* identity, and it is nil on a phone that is signed into
    /// iCloud perfectly well but has iCloud Drive turned off — or has it on and simply has
    /// not been asked about this app. CloudKit needs neither. The result was a build that
    /// worked on one tester's phone and served invented friends on the next one, under a
    /// banner blaming the build, for a difference in a Settings toggle that has nothing to
    /// do with any of this.
    ///
    /// `.couldNotDetermine` and `.temporarilyUnavailable` are treated as usable: both are
    /// transient, and a request made anyway fails with a message that says so.
    @discardableResult
    @MainActor static func refreshAccountStatus() async -> Status {
        guard hasICloudEntitlement else { return .notEntitled }
        let account = try? await CKContainer.default().accountStatus()
        switch account {
        case .noAccount, .restricted:
            accountLooksUsable = false
        default:
            accountLooksUsable = true
        }
        return status
    }

    /// Whether this build carries the iCloud container entitlement.
    ///
    /// Read from the embedded provisioning profile, which is the only copy of the
    /// entitlements a process can inspect without private API — and which is *absent from
    /// App Store builds*. Apple strips the profile when it re-signs for distribution, so a
    /// TestFlight build has no file to read and the old version of this concluded it was
    /// unentitled. Friends silently fell back to invented sample data on every build that
    /// left this machine, while working perfectly in Xcode, and the upload progress came
    /// from the mock reporting fake steps.
    ///
    /// So a missing profile is now read the other way round. Three cases, and only one of
    /// them is ambiguous:
    ///
    /// - **Simulator:** never has a profile and never has real entitlements. Unentitled.
    /// - **Profile present:** a development or ad-hoc build. Believe what it says, which is
    ///   what makes deliberately building without entitlements still work.
    /// - **Profile absent on a device:** only reachable by an App Store-signed build, and
    ///   the app is signed with the entitlements file every time it is built for
    ///   distribution. Entitled.
    static let hasICloudEntitlement: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        guard Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil else {
            // Distribution build: the profile was stripped, not missing.
            return true
        }
        return profileGrantsICloud
        #endif
    }()

    /// What the embedded provisioning profile says, for the builds that have one.
    private static let profileGrantsICloud: Bool = {
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

    /// One page, not a ceiling. Pulling continues until CloudKit says there is no more.
    ///
    /// There used to be a ceiling as well, and it could only ever be wrong: whatever number
    /// it held, the person whose history was longer than it had the remainder silently
    /// dropped, while the cursor moved on as though everything had arrived. Paging costs one
    /// extra request per hundred records and cannot do that.
    private static let visitPageSize = 100
    /// Identifier pages carry no bodies, so they can be far larger.
    private static let identifierPageSize = 400
    /// Small on purpose. 150 was one request for any realistic library, so a progress
    /// callback fired once, at the end — a bar that sat empty and then vanished. It also
    /// meant a single request carrying every attachment at once, which is not a shape
    /// CloudKit enjoys.
    private static let saveBatchSize = 15

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

    /// `since` is when we last pulled from this friend, and it is matched against when each
    /// record was last *written* — not against the day of the visit it describes.
    ///
    /// Those are different clocks, and using the visit's own date meant anything logged for
    /// a day earlier than your last refresh could never arrive. A park a friend marked
    /// visited carries the moment they tapped it, and publishing happens later — the next
    /// time they open the Friends tab, which after a format bump is a re-upload of their
    /// whole library and takes minutes. Refresh once during that window and their new visit
    /// is already behind your cursor, permanently. The same held for any trip logged for
    /// last Tuesday, and for every corrected copy of a visit already published, since a
    /// correction does not move the day it happened.
    ///
    /// Needs `modifiedTimestamp` marked queryable on the `FriendVisit` record type. Without
    /// it the query fails outright rather than quietly returning less, which is the right
    /// way round for something this easy to miss.
    func fetchVisits(code: String, since: Date?) async throws -> [FriendVisitPayload] {
        let predicate: NSPredicate
        if let since {
            predicate = NSPredicate(format: "code == %@ AND modificationDate > %@", code, since as NSDate)
        } else {
            predicate = NSPredicate(format: "code == %@", code)
        }

        let query = CKQuery(recordType: RecordType.visit, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

        do {
            var payloads: [FriendVisitPayload] = []
            var cursor: CKQueryOperation.Cursor?

            // Paged rather than one capped request.
            //
            // The cursor used to be discarded, so a pull was the first two hundred records
            // and nothing else — and the caller then stepped its sync cursor forward as
            // though it had everything, which put the remainder permanently out of reach.
            // Anyone sharing a real backlog had most of it silently dropped on arrival.
            repeat {
                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
                if let cursor {
                    page = try await database.records(continuingMatchFrom: cursor, resultsLimit: Self.visitPageSize)
                } else {
                    page = try await database.records(matching: query, resultsLimit: Self.visitPageSize)
                }
                for (_, result) in page.matchResults {
                    guard let record = try? result.get() else { continue }
                    payloads.append(Self.payload(from: record))
                }
                cursor = page.queryCursor
            } while cursor != nil

            return payloads
        } catch {
            throw Self.socialError(from: error)
        }
    }

    /// Identifiers only — no notes, no attachments — so reconciling what a friend has
    /// deleted costs a query rather than their whole feed.
    ///
    /// Reads every page before answering. Nil is reserved for a backend that cannot
    /// enumerate at all, because the caller deletes anything missing from the set it gets —
    /// a partial list read as authoritative would wipe most of a friend's history.
    func visitIdentifiers(code: String) async throws -> Set<String>? {
        let query = CKQuery(recordType: RecordType.visit, predicate: NSPredicate(format: "code == %@", code))

        do {
            var identifiers: Set<String> = []
            var cursor: CKQueryOperation.Cursor?

            repeat {
                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
                if let cursor {
                    page = try await database.records(
                        continuingMatchFrom: cursor,
                        desiredKeys: ["identifier"],
                        resultsLimit: Self.identifierPageSize
                    )
                } else {
                    page = try await database.records(
                        matching: query,
                        desiredKeys: ["identifier"],
                        resultsLimit: Self.identifierPageSize
                    )
                }
                for (recordID, result) in page.matchResults {
                    guard let record = try? result.get() else { continue }
                    identifiers.insert(record["identifier"] as? String ?? recordID.recordName)
                }
                cursor = page.queryCursor
            } while cursor != nil

            return identifiers
        } catch {
            throw Self.socialError(from: error)
        }
    }

    func deleteVisits(identifiers: [String]) async throws {
        let ids = identifiers.map { CKRecord.ID(recordName: $0) }
        do {
            for batch in stride(from: 0, to: ids.count, by: Self.saveBatchSize) {
                let end = min(batch + Self.saveBatchSize, ids.count)
                _ = try await database.modifyRecords(
                    saving: [],
                    deleting: Array(ids[batch..<end]),
                    savePolicy: .allKeys,
                    atomically: false
                )
            }
        } catch {
            throw Self.socialError(from: error)
        }
    }

    // MARK: - Publishing

    func publish(
        profile: FriendProfilePayload,
        visits: [FriendVisitPayload],
        progress: @Sendable @MainActor (Double) -> Void
    ) async throws {
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
                let end = min(batch + Self.saveBatchSize, records.count)
                let (saved, _) = try await database.modifyRecords(
                    saving: Array(records[batch..<end]),
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: false
                )

                // Every result is inspected, because `atomically: false` reports a failed
                // record in this dictionary rather than by throwing. Discarding it meant a
                // batch could fail in its entirety while publishing returned as though it
                // had worked — and the caller would then record those visits as shared and
                // never send them again. Which is the exact thing recording-after-success
                // was there to prevent.
                //
                // Failing on the first one is deliberate: the causes are all wholesale
                // rather than per-record — no schema in this environment, no account, no
                // network — so the second failure says nothing the first did not.
                for result in saved.values {
                    if case .failure(let error) = result {
                        throw Self.socialError(from: error)
                    }
                }

                let done = Double(end) / Double(records.count)
                await MainActor.run { progress(done) }
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
        record["isUndated"] = visit.isUndated ? 1 : 0

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
            mediaIsVideo: (record["mediaIsVideo"] as? Int ?? 0) == 1,
            // Absent from anything published before the field existed, and from any
            // environment where the schema has not been deployed yet. Both read as dated,
            // which is exactly how those visits behaved before.
            isUndated: (record["isUndated"] as? Int ?? 0) == 1
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
        // Told apart from the entitlement failures below, because this is the one a
        // *correct* build hits: a field the app writes that the container's production
        // schema has never been told about. Nothing on the phone can fix it and nothing
        // about the message below would send anyone to the right place.
        case .invalidArguments, .serverRejectedRequest:
            // Carries CloudKit's own sentence, which names the field or the index that is
            // missing. Without it the message says only that something is wrong with a
            // setup the person reading it cannot see, which is where this spent a day.
            return .unavailable("iCloud rejected this request — the app's iCloud setup needs updating. \(ckError.localizedDescription)")
        case .zoneNotFound, .badContainer, .missingEntitlement:
            return .unavailable("iCloud sharing isn't set up in this build.")
        default:
            return .failed(ckError.localizedDescription)
        }
    }
}
