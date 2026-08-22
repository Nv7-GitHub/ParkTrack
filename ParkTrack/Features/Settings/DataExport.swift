import Foundation
import CoreLocation
import SwiftData

// MARK: - Manifest types

/// One photo or video. The bytes live beside the manifest in the archive, named by this
/// identifier, so the JSON stays small enough to parse whatever the library weighs.
struct BackupMedia: Codable {
    var identifier: UUID
    var isVideo: Bool
    var createdAt: Date
    /// False when the export deliberately left media out, in which case the archive
    /// carries no bytes for this item and the restore recreates nothing.
    var hasData: Bool
    var hasThumbnail: Bool
}

/// One logged visit.
struct BackupVisit: Codable {
    var identifier: UUID
    var date: Date
    var durationMinutes: Int?
    var notes: String
    var rating: Int
    var companions: String
    var weatherSummary: String?
    var createdAt: Date
    /// Whether the user ever claimed a day for this visit.
    ///
    /// Carried because `date` on an undated visit is only the moment the row was made.
    /// Dropping this promotes that bookkeeping timestamp into a claim about a day the user
    /// never made, which puts an entire imported backlog on the timeline as though it
    /// happened the afternoon of the restore — the exact failure undated visits exist to
    /// prevent, arriving at the worst possible moment.
    var isUndated: Bool
    var media: [BackupMedia]
}

/// One park, flattened so the manifest stays readable and survives model changes better
/// than an archive of the store would.
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

/// A place struck off by hand. Without these a restore re-discovers everything the user
/// rejected on the very next sweep.
struct BackupExcludedPlace: Codable {
    var identifier: String
    var name: String
    var latitude: Double
    var longitude: Double
    var excludedAt: Date
}

/// Ground already searched. Cheap to carry and expensive to rebuild — re-scanning costs
/// real requests against a rate limit shared with the user's own phone.
struct BackupScannedArea: Codable {
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double
    var scannedAt: Date
    var resolution: Double
    var searchGeneration: Int
}

/// A completed region index, which is the denominator behind every percentage.
struct BackupRegionIndex: Codable {
    var identifier: String
    var kindRaw: String
    var name: String
    var container: String?
    var country: String?
    var centerLatitude: Double
    var centerLongitude: Double
    var radiusMeters: Double
    var indexedAt: Date?
    var parkCount: Int
    var indexerVersion: Int
    var isApproximate: Bool
}

/// A friend, as identity only.
///
/// Their stats, feed and standings are deliberately absent: all of it re-pulls from
/// CloudKit on the next refresh, and carrying a stale copy would mean a restore showing
/// figures that were true weeks ago until the first sync corrected them.
struct BackupFriend: Codable {
    var friendCode: String
    var displayName: String
    var addedAt: Date
}

/// Preferences, which live in `UserDefaults` rather than the store.
struct BackupSettings: Codable {
    var displayName: String
    var friendCode: String
    /// `[SavedPlaceKind.rawValue: [latitude, longitude]]` — home, school and work alike,
    /// rather than home alone as an earlier version of this file carried.
    var placeCoordinates: [String: [Double]]
    var placeLabels: [String: String]
    var customRadiusMiles: Double
    var hasCompletedOnboarding: Bool
}

/// The manifest. Everything except the media bytes, which sit beside it in the archive.
struct BackupPayload: Codable {
    var formatVersion: Int
    var exportedAt: Date
    var settings: BackupSettings
    var parks: [BackupPark]
    var excludedPlaces: [BackupExcludedPlace]
    var scannedAreas: [BackupScannedArea]
    var regionIndexes: [BackupRegionIndex]
    var friends: [BackupFriend]
}

// MARK: - Summary

/// What an import actually changed, so the UI can say something specific.
struct BackupMergeSummary: Equatable {
    var parksAdded = 0
    var parksUpdated = 0
    var visitsAdded = 0
    var mediaAdded = 0
    var exclusionsAdded = 0
    var parksStruckOff = 0
    var scannedAreasAdded = 0
    var regionIndexesAdded = 0
    var friendsAdded = 0

    var isEmpty: Bool {
        parksAdded == 0 && parksUpdated == 0 && visitsAdded == 0 && mediaAdded == 0
            && exclusionsAdded == 0 && parksStruckOff == 0 && scannedAreasAdded == 0
            && regionIndexesAdded == 0 && friendsAdded == 0
    }

    var sentence: String {
        guard !isEmpty else { return "Everything in that file was already here." }
        var parts: [String] = []
        if parksAdded > 0 { parts.append("\(parksAdded) new \(parksAdded == 1 ? "park" : "parks")") }
        if visitsAdded > 0 { parts.append("\(visitsAdded) new \(visitsAdded == 1 ? "visit" : "visits")") }
        if mediaAdded > 0 { parts.append("\(mediaAdded) \(mediaAdded == 1 ? "photo or video" : "photos and videos")") }
        if exclusionsAdded > 0 { parts.append("\(exclusionsAdded) struck off") }
        if parksStruckOff > 0 { parts.append("removed \(parksStruckOff) that aren't parks") }
        if regionIndexesAdded > 0 { parts.append("\(regionIndexesAdded) indexed \(regionIndexesAdded == 1 ? "place" : "places")") }
        if scannedAreasAdded > 0 { parts.append("\(scannedAreasAdded) scanned \(scannedAreasAdded == 1 ? "area" : "areas")") }
        if friendsAdded > 0 { parts.append("\(friendsAdded) \(friendsAdded == 1 ? "friend" : "friends")") }
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

// MARK: - DataExport

/// Reading and writing the full backup.
///
/// Building the manifest and merging it are pure of the archive: `makeBackup` takes models
/// and returns values, `merge` takes values and a store. Only `writeArchive` and
/// `readArchive` touch a file, which keeps everything interesting testable without one.
enum DataExport {
    static let formatVersion = 1

    // MARK: - Naming

    static func mediaName(for identifier: UUID) -> String { "media/\(identifier.uuidString)" }
    static func thumbnailName(for identifier: UUID) -> String { "media/\(identifier.uuidString).thumb" }

    // MARK: - Building the manifest

    static func makeBackup(
        parks: [Park],
        excludedPlaces: [ExcludedPlace] = [],
        scannedAreas: [ScannedArea] = [],
        regionIndexes: [RegionIndex] = [],
        friends: [Friend] = [],
        settings: BackupSettings,
        includeMedia: Bool = true,
        exportedAt: Date = Date()
    ) -> BackupPayload {
        let sorted = parks.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return BackupPayload(
            formatVersion: formatVersion,
            exportedAt: exportedAt,
            settings: settings,
            parks: sorted.map { backupPark(from: $0, includeMedia: includeMedia) },
            excludedPlaces: excludedPlaces.map(backupExcludedPlace(from:)),
            scannedAreas: scannedAreas.map(backupScannedArea(from:)),
            regionIndexes: regionIndexes.map(backupRegionIndex(from:)),
            friends: friends.map(backupFriend(from:))
        )
    }

    static func backupExcludedPlace(from place: ExcludedPlace) -> BackupExcludedPlace {
        BackupExcludedPlace(
            identifier: place.identifier,
            name: place.name,
            latitude: place.latitude,
            longitude: place.longitude,
            excludedAt: place.excludedAt
        )
    }

    static func backupScannedArea(from area: ScannedArea) -> BackupScannedArea {
        BackupScannedArea(
            minLatitude: area.minLatitude,
            maxLatitude: area.maxLatitude,
            minLongitude: area.minLongitude,
            maxLongitude: area.maxLongitude,
            scannedAt: area.scannedAt,
            resolution: area.resolution,
            searchGeneration: area.searchGeneration
        )
    }

    static func backupRegionIndex(from index: RegionIndex) -> BackupRegionIndex {
        BackupRegionIndex(
            identifier: index.identifier,
            kindRaw: index.kindRaw,
            name: index.name,
            container: index.container,
            country: index.country,
            centerLatitude: index.centerLatitude,
            centerLongitude: index.centerLongitude,
            radiusMeters: index.radiusMeters,
            indexedAt: index.indexedAt,
            parkCount: index.parkCount,
            indexerVersion: index.indexerVersion,
            isApproximate: index.isApproximate
        )
    }

    static func backupFriend(from friend: Friend) -> BackupFriend {
        BackupFriend(
            friendCode: friend.friendCode,
            displayName: friend.displayName,
            addedAt: friend.addedAt
        )
    }

    static func backupPark(from park: Park, includeMedia: Bool = true) -> BackupPark {
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
            visits: park.sortedVisits.map { backupVisit(from: $0, includeMedia: includeMedia) }
        )
    }

    static func backupVisit(from visit: Visit, includeMedia: Bool = true) -> BackupVisit {
        BackupVisit(
            identifier: visit.identifier,
            date: visit.date,
            durationMinutes: visit.durationMinutes,
            notes: visit.notes,
            rating: visit.rating,
            companions: visit.companions,
            weatherSummary: visit.weatherSummary,
            createdAt: visit.createdAt,
            isUndated: visit.isUndated,
            media: includeMedia ? visit.sortedMedia.map(backupMedia(from:)) : []
        )
    }

    static func backupMedia(from item: MediaItem) -> BackupMedia {
        BackupMedia(
            identifier: item.identifier,
            isVideo: item.isVideo,
            createdAt: item.createdAt,
            hasData: item.data != nil,
            hasThumbnail: item.thumbnailData != nil
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

    // MARK: - Writing an archive

    /// Streams a full backup to `url`.
    ///
    /// `parks` is walked a second time here rather than the bytes being carried inside the
    /// payload: each attachment is fetched from external storage, written, and released
    /// before the next one is touched, so exporting a library of any size costs one
    /// attachment of memory rather than all of them.
    static func writeArchive(payload: BackupPayload, parks: [Park], to url: URL) throws {
        let writer = try BackupArchiveWriter(url: url)
        try writer.writeManifest(try encode(payload))

        if payload.parks.contains(where: { $0.visits.contains { !$0.media.isEmpty } }) {
            for park in parks {
                for visit in park.sortedVisits {
                    for item in visit.sortedMedia {
                        if let data = item.data {
                            try writer.append(name: mediaName(for: item.identifier), data: data)
                        }
                        if let thumbnail = item.thumbnailData {
                            try writer.append(name: thumbnailName(for: item.identifier), data: thumbnail)
                        }
                    }
                }
            }
        }

        try writer.finish()
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "ParkTrack-Backup-\(stamp).\(BackupArchive.fileExtension)"
    }

    // MARK: - Reading an archive

    /// What an import produced: what changed in the store, and the preferences the file
    /// carried. Preferences come back separately because they live in `UserDefaults`, which
    /// this layer deliberately does not reach into — the caller owns that decision.
    struct ImportResult {
        var summary: BackupMergeSummary
        var settings: BackupSettings
    }

    /// Opens a backup and folds it into the store, pulling each attachment only when the
    /// visit that owns it is being created.
    @discardableResult
    static func importArchive(at url: URL, into context: ModelContext) throws -> ImportResult {
        let reader: BackupArchiveReader
        do {
            reader = try BackupArchiveReader(url: url)
        } catch let error as BackupArchiveError {
            throw error
        } catch {
            throw BackupError.unreadableFile
        }
        defer { reader.close() }

        let payload = try decode(reader.manifest)
        let summary = try merge(payload, into: context, media: { name in try reader.data(for: name) })
        return ImportResult(summary: summary, settings: payload.settings)
    }

    // MARK: - Merging

    /// Folds a backup into the store without ever creating a second copy of anything.
    ///
    /// Every store merges on an identity that survives the trip between two installs, not
    /// on a device-local row id: parks and exclusions on `Park.identity`, visits and media
    /// on their own UUIDs, region indexes on their identifier, friends on their code, and
    /// scanned areas on the ground they cover. Existing local values win for anything the
    /// user can edit — the import fills blanks — and wishlisting is unioned rather than
    /// overwritten so restoring an old backup cannot quietly un-star a park.
    ///
    /// `media` is a lookup rather than a dictionary so the caller can stream blobs off disk
    /// one at a time; returning nil for a name simply means that attachment is not restored.
    @discardableResult
    static func merge(
        _ payload: BackupPayload,
        into context: ModelContext,
        media: (String) throws -> Data? = { _ in nil }
    ) throws -> BackupMergeSummary {
        var summary = BackupMergeSummary()

        // Exclusions first, and not merely for tidiness. They decide which parks may exist
        // at all, so anything that runs before them is working from an incomplete answer —
        // see `mergeExclusions` and the guard at the top of the park loop.
        try mergeExclusions(payload, into: context, summary: &summary)
        try mergeParks(payload, into: context, media: media, summary: &summary)
        try mergeScannedAreas(payload, into: context, summary: &summary)
        try mergeRegionIndexes(payload, into: context, summary: &summary)
        try mergeFriends(payload, into: context, summary: &summary)

        try context.save()
        return summary
    }

    // MARK: Parks and visits

    private static func mergeParks(
        _ payload: BackupPayload,
        into context: ModelContext,
        media: (String) throws -> Data?,
        summary: inout BackupMergeSummary
    ) throws {
        let existingParks = try context.fetch(FetchDescriptor<Park>())
        var parksByIdentifier: [String: Park] = [:]
        for park in existingParks {
            parksByIdentifier[key(for: park)] = park
        }

        var knownVisitIDs = Set(try context.fetch(FetchDescriptor<Visit>()).map(\.identifier))
        var knownMediaIDs = Set(try context.fetch(FetchDescriptor<MediaItem>()).map(\.identifier))

        // Rejections have already been merged, so this is the complete list.
        let excluded = ExclusionIndex(try context.fetch(FetchDescriptor<ExcludedPlace>()))

        for incoming in payload.parks {
            let key = incoming.identifier.isEmpty
                ? Park.identity(
                    name: incoming.name,
                    coordinate: CLLocationCoordinate2D(latitude: incoming.latitude, longitude: incoming.longitude)
                )
                : incoming.identifier

            // A backup can name the same place in both lists — a park recorded before it was
            // struck off, or re-found afterwards a metre away and so under a second
            // identifier. Creating it would restore something the same file says is not a
            // park, which is what left places showing up in the results and in the "not a
            // park" list at once.
            //
            // Unless it carries visits. Then the contradiction is resolved the other way:
            // dropping it would throw away logged visits and their photos to honour a
            // rejection that was probably never meant to cover this, and a park can always
            // be struck off again by hand.
            if incoming.visits.isEmpty,
               parksByIdentifier[key] == nil,
               excluded.covers(
                identifier: key,
                name: incoming.name,
                coordinate: CLLocationCoordinate2D(latitude: incoming.latitude, longitude: incoming.longitude)
               ) {
                continue
            }

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
                visit.isUndated = incomingVisit.isUndated
                context.insert(visit)
                knownVisitIDs.insert(incomingVisit.identifier)
                summary.visitsAdded += 1
                didChangePark = true

                for incomingMedia in incomingVisit.media where !knownMediaIDs.contains(incomingMedia.identifier) {
                    let data = incomingMedia.hasData ? try media(mediaName(for: incomingMedia.identifier)) : nil
                    let thumbnail = incomingMedia.hasThumbnail
                        ? try media(thumbnailName(for: incomingMedia.identifier))
                        : nil
                    guard data != nil || thumbnail != nil else { continue }

                    let item = MediaItem(data: data, isVideo: incomingMedia.isVideo, thumbnailData: thumbnail)
                    item.identifier = incomingMedia.identifier
                    item.createdAt = incomingMedia.createdAt
                    item.visit = visit
                    context.insert(item)
                    knownMediaIDs.insert(incomingMedia.identifier)
                    summary.mediaAdded += 1
                }
            }

            if didChangePark && !isNewPark {
                summary.parksUpdated += 1
            }
        }
    }

    private static func key(for park: Park) -> String {
        park.identifier.isEmpty
            ? Park.identity(name: park.name, coordinate: park.coordinate)
            : park.identifier
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

    // MARK: Everything else

    /// Restores the rejection list, then makes the catalogue agree with it.
    ///
    /// The second half is the part that matters, and it exists because of a real order of
    /// events. A fresh install starts sweeping the moment it opens, and a sweep run before
    /// any backup has been imported knows of no rejections at all — so it files every place
    /// the user had struck off, exactly as the map describes them. Importing then adds the
    /// rejections on top, and the result is a place sitting in the "not a park" list and in
    /// the search results at the same time.
    ///
    /// So an arriving rejection reaches back over what is already there. Reconciliation runs
    /// against the whole list rather than only the new arrivals, which means re-importing a
    /// backup repairs a catalogue that has already gone wrong this way.
    ///
    /// A park with visits on it is never removed. A rejection cascades to visits and their
    /// photos, and a rejected place should not have had visits in the first place — so a
    /// match here is a contradiction in the data rather than an instruction, and the reading
    /// that cannot destroy anything wins.
    private static func mergeExclusions(
        _ payload: BackupPayload,
        into context: ModelContext,
        summary: inout BackupMergeSummary
    ) throws {
        var known = Set(try context.fetch(FetchDescriptor<ExcludedPlace>()).map(\.identifier))
        for incoming in payload.excludedPlaces where !known.contains(incoming.identifier) {
            let place = ExcludedPlace(
                identifier: incoming.identifier,
                name: incoming.name,
                latitude: incoming.latitude,
                longitude: incoming.longitude
            )
            place.excludedAt = incoming.excludedAt
            context.insert(place)
            known.insert(incoming.identifier)
            summary.exclusionsAdded += 1
        }

        let index = ExclusionIndex(try context.fetch(FetchDescriptor<ExcludedPlace>()))
        guard !index.isEmpty else { return }

        for park in try context.fetch(FetchDescriptor<Park>()) where park.visitCount == 0 {
            guard index.covers(park) else { continue }
            context.delete(park)
            summary.parksStruckOff += 1
        }
    }

    /// Scanned ground has no identifier of its own, so it is keyed on the rectangle plus
    /// the grade of search that covered it — two records describing the same ground at the
    /// same resolution and generation are the same fact.
    private static func scannedKey(_ area: BackupScannedArea) -> String {
        func round(_ value: Double) -> String { String(format: "%.6f", value) }
        return [
            round(area.minLatitude), round(area.maxLatitude),
            round(area.minLongitude), round(area.maxLongitude),
            round(area.resolution), String(area.searchGeneration)
        ].joined(separator: "|")
    }

    private static func mergeScannedAreas(
        _ payload: BackupPayload,
        into context: ModelContext,
        summary: inout BackupMergeSummary
    ) throws {
        let existing = try context.fetch(FetchDescriptor<ScannedArea>())
        var known = Set(existing.map {
            scannedKey(BackupScannedArea(
                minLatitude: $0.minLatitude,
                maxLatitude: $0.maxLatitude,
                minLongitude: $0.minLongitude,
                maxLongitude: $0.maxLongitude,
                scannedAt: $0.scannedAt,
                resolution: $0.resolution,
                searchGeneration: $0.searchGeneration
            ))
        })

        for incoming in payload.scannedAreas {
            let key = scannedKey(incoming)
            guard !known.contains(key) else { continue }
            let area = ScannedArea(
                minLatitude: incoming.minLatitude,
                maxLatitude: incoming.maxLatitude,
                minLongitude: incoming.minLongitude,
                maxLongitude: incoming.maxLongitude,
                resolution: incoming.resolution,
                searchGeneration: incoming.searchGeneration
            )
            area.scannedAt = incoming.scannedAt
            context.insert(area)
            known.insert(key)
            summary.scannedAreasAdded += 1
        }
    }

    /// Region indexes upsert rather than skip: an incoming record from a newer indexer
    /// generation carries a total the local one cannot defend, so it wins.
    private static func mergeRegionIndexes(
        _ payload: BackupPayload,
        into context: ModelContext,
        summary: inout BackupMergeSummary
    ) throws {
        let existing = try context.fetch(FetchDescriptor<RegionIndex>())
        var byIdentifier: [String: RegionIndex] = [:]
        for index in existing { byIdentifier[index.identifier] = index }

        for incoming in payload.regionIndexes {
            if let local = byIdentifier[incoming.identifier] {
                guard incoming.indexerVersion > local.indexerVersion else { continue }
                local.parkCount = incoming.parkCount
                local.indexerVersion = incoming.indexerVersion
                local.indexedAt = incoming.indexedAt
                local.isApproximate = incoming.isApproximate
                continue
            }

            let index = RegionIndex(
                identifier: incoming.identifier,
                kind: RegionKind(rawValue: incoming.kindRaw) ?? .city,
                name: incoming.name,
                container: incoming.container,
                country: incoming.country,
                center: CLLocationCoordinate2D(
                    latitude: incoming.centerLatitude,
                    longitude: incoming.centerLongitude
                ),
                radiusMeters: incoming.radiusMeters
            )
            index.indexedAt = incoming.indexedAt
            index.parkCount = incoming.parkCount
            index.indexerVersion = incoming.indexerVersion
            index.isApproximate = incoming.isApproximate
            context.insert(index)
            byIdentifier[incoming.identifier] = index
            summary.regionIndexesAdded += 1
        }
    }

    private static func mergeFriends(
        _ payload: BackupPayload,
        into context: ModelContext,
        summary: inout BackupMergeSummary
    ) throws {
        var known = Set(try context.fetch(FetchDescriptor<Friend>()).map(\.friendCode))
        for incoming in payload.friends where !known.contains(incoming.friendCode) {
            let friend = Friend(friendCode: incoming.friendCode, displayName: incoming.displayName)
            friend.addedAt = incoming.addedAt
            context.insert(friend)
            known.insert(incoming.friendCode)
            summary.friendsAdded += 1
        }
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
