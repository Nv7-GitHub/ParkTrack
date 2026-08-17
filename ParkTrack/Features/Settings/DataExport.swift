import Foundation
import CoreLocation
import SwiftData

/// One park in a backup file, flattened so the JSON is readable by a human and
/// survives model changes better than an archive of the store would.
struct BackupPark: Codable {
    var identifier: String
    var name: String
    var latitude: Double
    var longitude: Double
    var category: String?
    var locality: String?
    var subAdministrativeArea: String?
    var administrativeArea: String?
    var country: String?
    var postalAddress: String?
    var isWishlisted: Bool
    var discoveredAt: Date
    var visits: [BackupVisit]
}

/// One logged visit. Media is deliberately absent: photos and video would balloon a
/// backup from kilobytes to gigabytes, and they are already carried by iCloud when
/// sync is on.
struct BackupVisit: Codable {
    var identifier: UUID
    var date: Date
    var durationMinutes: Int?
    var notes: String
    var rating: Int
    var companions: String
    var weatherSummary: String?
    var createdAt: Date
}

/// The whole file. `formatVersion` is what lets a future release recognise and upgrade
/// an old backup instead of rejecting it.
struct BackupPayload: Codable {
    var formatVersion: Int
    var exportedAt: Date
    var displayName: String
    var friendCode: String
    var homeLatitude: Double?
    var homeLongitude: Double?
    var homeLabel: String
    var customRadiusMiles: Double
    var parks: [BackupPark]
}

/// What an import actually changed, so the UI can say something specific.
struct BackupMergeSummary: Equatable {
    var parksAdded: Int = 0
    var parksUpdated: Int = 0
    var visitsAdded: Int = 0

    var isEmpty: Bool { parksAdded == 0 && parksUpdated == 0 && visitsAdded == 0 }

    var sentence: String {
        guard !isEmpty else { return "Everything in that file was already here." }
        var parts: [String] = []
        if parksAdded > 0 { parts.append("\(parksAdded) new \(parksAdded == 1 ? "park" : "parks")") }
        if visitsAdded > 0 { parts.append("\(visitsAdded) new \(visitsAdded == 1 ? "visit" : "visits")") }
        if parksUpdated > 0 { parts.append("\(parksUpdated) updated") }
        return "Imported " + parts.formatted(.list(type: .and)) + "."
    }
}

enum BackupError: LocalizedError {
    case unreadableFile
    case notABackup
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableFile: "That file couldn't be opened."
        case .notABackup: "That doesn't look like a ParkTrack backup."
        case .unsupportedVersion(let version): "That backup was made by a newer version of ParkTrack (format \(version))."
        }
    }
}

/// Reading and writing the JSON backup.
///
/// Every function here is pure apart from `merge`, which is the only one that needs a
/// store: encoding, decoding and payload construction take plain values so they can be
/// exercised without a `ModelContainer`.
enum DataExport {
    static let formatVersion = 1

    // MARK: - Building

    static func makeBackup(
        parks: [Park],
        displayName: String,
        friendCode: String,
        home: CLLocationCoordinate2D?,
        homeLabel: String,
        customRadiusMiles: Double,
        exportedAt: Date = Date()
    ) -> BackupPayload {
        BackupPayload(
            formatVersion: formatVersion,
            exportedAt: exportedAt,
            displayName: displayName,
            friendCode: friendCode,
            homeLatitude: home?.latitude,
            homeLongitude: home?.longitude,
            homeLabel: homeLabel,
            customRadiusMiles: customRadiusMiles,
            parks: parks
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(backupPark(from:))
        )
    }

    static func backupPark(from park: Park) -> BackupPark {
        BackupPark(
            identifier: park.identifier.isEmpty
                ? Park.identity(name: park.name, coordinate: park.coordinate)
                : park.identifier,
            name: park.name,
            latitude: park.latitude,
            longitude: park.longitude,
            category: park.categoryRaw,
            locality: park.locality,
            subAdministrativeArea: park.subAdministrativeArea,
            administrativeArea: park.administrativeArea,
            country: park.country,
            postalAddress: park.postalAddress,
            isWishlisted: park.isWishlisted,
            discoveredAt: park.discoveredAt,
            visits: park.sortedVisits.map { visit in
                BackupVisit(
                    identifier: visit.identifier,
                    date: visit.date,
                    durationMinutes: visit.durationMinutes,
                    notes: visit.notes,
                    rating: visit.rating,
                    companions: visit.companions,
                    weatherSummary: visit.weatherSummary,
                    createdAt: visit.createdAt
                )
            }
        )
    }

    // MARK: - Coding

    static func encode(_ payload: BackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> BackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(BackupPayload.self, from: data) else {
            throw BackupError.notABackup
        }
        guard payload.formatVersion <= formatVersion else {
            throw BackupError.unsupportedVersion(payload.formatVersion)
        }
        return payload
    }

    /// Writes the backup somewhere `ShareLink` can hand it to another app.
    static func writeTemporaryFile(_ payload: BackupPayload, named name: String = defaultFileName()) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try encode(payload).write(to: url, options: .atomic)
        return url
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "ParkTrack-Backup-\(stamp).json"
    }

    // MARK: - Merging

    /// Folds a backup into the store without ever creating a second copy of anything.
    ///
    /// Parks match on `Park.identifier`, which is a name-plus-coordinate hash rather than
    /// a device-local row id, so a file exported on one phone lands correctly on another.
    /// Visits match on their UUID. Existing local values win for anything the user can
    /// edit; the import only fills in blanks, and wishlisting is unioned rather than
    /// overwritten so restoring an old backup can't quietly un-star a park.
    @discardableResult
    static func merge(_ payload: BackupPayload, into context: ModelContext) throws -> BackupMergeSummary {
        let existingParks = try context.fetch(FetchDescriptor<Park>())
        var parksByIdentifier: [String: Park] = [:]
        for park in existingParks {
            let key = park.identifier.isEmpty
                ? Park.identity(name: park.name, coordinate: park.coordinate)
                : park.identifier
            parksByIdentifier[key] = park
        }

        var knownVisitIDs = Set(try context.fetch(FetchDescriptor<Visit>()).map(\.identifier))
        var summary = BackupMergeSummary()

        for incoming in payload.parks {
            let key = incoming.identifier.isEmpty
                ? Park.identity(
                    name: incoming.name,
                    coordinate: CLLocationCoordinate2D(latitude: incoming.latitude, longitude: incoming.longitude)
                )
                : incoming.identifier

            let park: Park
            var didChangePark = false
            var isNewPark = false

            if let match = parksByIdentifier[key] {
                park = match
                if apply(incoming, to: park) { didChangePark = true }
            } else {
                isNewPark = true
                park = Park(
                    identifier: key,
                    name: incoming.name,
                    latitude: incoming.latitude,
                    longitude: incoming.longitude,
                    categoryRaw: incoming.category
                )
                _ = apply(incoming, to: park)
                park.discoveredAt = incoming.discoveredAt
                context.insert(park)
                parksByIdentifier[key] = park
                summary.parksAdded += 1
            }

            for incomingVisit in incoming.visits where !knownVisitIDs.contains(incomingVisit.identifier) {
                let visit = Visit(
                    date: incomingVisit.date,
                    durationMinutes: incomingVisit.durationMinutes,
                    notes: incomingVisit.notes,
                    rating: incomingVisit.rating,
                    companions: incomingVisit.companions,
                    park: park
                )
                visit.identifier = incomingVisit.identifier
                visit.weatherSummary = incomingVisit.weatherSummary
                visit.createdAt = incomingVisit.createdAt
                context.insert(visit)
                knownVisitIDs.insert(incomingVisit.identifier)
                summary.visitsAdded += 1
                didChangePark = true
            }

            if didChangePark && !isNewPark {
                summary.parksUpdated += 1
            }
        }

        try context.save()
        return summary
    }

    /// Fills in fields the local park is missing. Returns whether anything changed.
    private static func apply(_ incoming: BackupPark, to park: Park) -> Bool {
        var changed = false

        func fill(_ current: String?, _ incomingValue: String?) -> String? {
            guard current == nil || current?.isEmpty == true, let incomingValue, !incomingValue.isEmpty else { return current }
            changed = true
            return incomingValue
        }

        park.categoryRaw = fill(park.categoryRaw, incoming.category)
        park.locality = fill(park.locality, incoming.locality)
        park.subAdministrativeArea = fill(park.subAdministrativeArea, incoming.subAdministrativeArea)
        park.administrativeArea = fill(park.administrativeArea, incoming.administrativeArea)
        park.country = fill(park.country, incoming.country)
        park.postalAddress = fill(park.postalAddress, incoming.postalAddress)

        if park.locality != nil || park.administrativeArea != nil || park.country != nil, park.regionResolvedAt == nil {
            park.regionResolvedAt = Date()
        }
        if incoming.isWishlisted && !park.isWishlisted {
            park.isWishlisted = true
            changed = true
        }
        if park.name.isEmpty && !incoming.name.isEmpty {
            park.name = incoming.name
            changed = true
        }
        if incoming.discoveredAt < park.discoveredAt {
            park.discoveredAt = incoming.discoveredAt
            changed = true
        }
        return changed
    }

    // MARK: - Footprint

    /// Bytes that photos and video actually occupy.
    ///
    /// `@Attribute(.externalStorage)` writes large blobs to files beside the store, so the
    /// honest measure is the size of those files. Small attachments stay inline in the
    /// store instead, and for those we fall back to adding up the models.
    static func mediaBytesOnDisk(context: ModelContext) -> Int64 {
        let external = externalStorageBytes()
        if external > 0 { return external }
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        return items.reduce(Int64(0)) { total, item in
            total + Int64(item.data?.count ?? 0) + Int64(item.thumbnailData?.count ?? 0)
        }
    }

    private static func externalStorageBytes() -> Int64 {
        let manager = FileManager.default
        guard let support = try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return 0 }
        guard let walker = manager.enumerator(
            at: support,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in walker where url.pathComponents.contains("_EXTERNAL_DATA") {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false))
    }
}
