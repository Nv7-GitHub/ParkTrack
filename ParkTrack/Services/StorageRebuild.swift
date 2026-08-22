import Foundation
import SwiftData

/// Rebuilds the store from a backup of itself, discarding anything the backup does not
/// carry.
///
/// This exists because external storage can end up holding files that no row refers to any
/// more. CoreData names those files internally and there is no way back from a file to the
/// row that owned it, so a sweep that tried to delete the unreferenced ones would be
/// guessing — and the cost of guessing wrong is somebody's photograph. Rebuilding sidesteps
/// the identification problem entirely: write down everything the app knows, throw the store
/// away, and put it back. Whatever is left out was, by definition, not referenced.
///
/// The dangerous half is obvious, so the order is strict. Nothing is deleted until an
/// archive has been written *and* read back *and* found to describe the same number of
/// parks, visits and attachments as the live store. The archive then outlives the deletion:
/// it is only removed once the import that follows has succeeded.
///
/// The work happens at launch rather than in the running app, because emptying the store
/// out from under a live `ModelContainer` is not something SwiftData supports. Tapping the
/// button prepares; the next launch performs.
enum StorageRebuild {
    private enum Key {
        static let archivePath = "storage.rebuild.archivePath"
        static let attempts = "storage.rebuild.attempts"
        static let failure = "storage.rebuild.failure"
    }

    /// Two goes, then stop. A rebuild that crashes the app on launch would otherwise crash
    /// it on every launch, and an app that will not open is far worse than a wasted
    /// megabyte. The archive is kept either way, so nothing is lost by giving up.
    private static let maximumAttempts = 2

    private static var defaults: UserDefaults { .standard }

    // MARK: - What the settings screen calls

    enum PrepareError: LocalizedError {
        case couldNotWrite(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .couldNotWrite(let reason): "Couldn't write the safety copy, so nothing was changed. \(reason)"
            case .verificationFailed(let reason): "The safety copy didn't match what's in the app, so nothing was changed. \(reason)"
            }
        }
    }

    /// Writes and verifies the archive the next launch will rebuild from.
    ///
    /// Returns its size, so the screen can say how much was safeguarded. Throws rather than
    /// arming the rebuild if anything at all is off.
    @discardableResult
    static func prepare(context: ModelContext, settings: BackupSettings) throws -> Int64 {
        let parks = (try? context.fetch(FetchDescriptor<Park>())) ?? []
        let payload = DataExport.makeBackup(
            parks: parks,
            excludedPlaces: (try? context.fetch(FetchDescriptor<ExcludedPlace>())) ?? [],
            scannedAreas: (try? context.fetch(FetchDescriptor<ScannedArea>())) ?? [],
            regionIndexes: (try? context.fetch(FetchDescriptor<RegionIndex>())) ?? [],
            friends: (try? context.fetch(FetchDescriptor<Friend>())) ?? [],
            settings: settings,
            includeMedia: true
        )

        let url = archiveURL()
        do {
            try? FileManager.default.removeItem(at: url)
            try DataExport.writeArchive(payload: payload, parks: parks, to: url)
        } catch {
            throw PrepareError.couldNotWrite(error.localizedDescription)
        }

        try verify(url, against: context)

        defaults.set(url.path, forKey: Key.archivePath)
        defaults.set(0, forKey: Key.attempts)
        defaults.removeObject(forKey: Key.failure)

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size)
    }

    /// Reads the archive back and checks it describes the store it came from.
    ///
    /// Counting rather than trusting the write to have succeeded: a truncated file, a full
    /// disk or an attachment that failed to load would all produce a readable archive that
    /// is quietly missing things, and the next step deletes the original.
    static func verify(_ url: URL, against context: ModelContext) throws {
        let reader: BackupArchiveReader
        do {
            reader = try BackupArchiveReader(url: url)
        } catch {
            throw PrepareError.verificationFailed(error.localizedDescription)
        }
        defer { reader.close() }

        let payload: BackupPayload
        do {
            payload = try DataExport.decode(reader.manifest)
        } catch {
            throw PrepareError.verificationFailed(error.localizedDescription)
        }

        let liveParks = (try? context.fetchCount(FetchDescriptor<Park>())) ?? 0
        let liveVisits = (try? context.fetchCount(FetchDescriptor<Visit>())) ?? 0
        let liveMedia = (try? context.fetchCount(FetchDescriptor<MediaItem>())) ?? 0

        let backedUpVisits = payload.parks.reduce(0) { $0 + $1.visits.count }
        let backedUpMedia = payload.parks.reduce(0) { $0 + $1.visits.reduce(0) { $0 + $1.media.count } }

        guard payload.parks.count == liveParks else {
            throw PrepareError.verificationFailed("It has \(payload.parks.count) parks, the app has \(liveParks).")
        }
        guard backedUpVisits == liveVisits else {
            throw PrepareError.verificationFailed("It has \(backedUpVisits) visits, the app has \(liveVisits).")
        }
        guard backedUpMedia == liveMedia else {
            throw PrepareError.verificationFailed("It has \(backedUpMedia) attachments, the app has \(liveMedia).")
        }

        // And every attachment the manifest promises has to actually be in the file, or the
        // rebuild would silently drop photographs.
        let present = Set(reader.entryNames)
        for park in payload.parks {
            for visit in park.visits {
                for item in visit.media {
                    if item.hasData, !present.contains(DataExport.mediaName(for: item.identifier)) {
                        throw PrepareError.verificationFailed("A photo or video is missing from it.")
                    }
                    if item.hasThumbnail, !present.contains(DataExport.thumbnailName(for: item.identifier)) {
                        throw PrepareError.verificationFailed("A video preview is missing from it.")
                    }
                }
            }
        }
    }

    static var isArmed: Bool { defaults.string(forKey: Key.archivePath) != nil }

    /// Set when a rebuild was abandoned, so the screen can say so rather than silently
    /// having done nothing.
    static var lastFailure: String? { defaults.string(forKey: Key.failure) }

    static func clearLastFailure() { defaults.removeObject(forKey: Key.failure) }

    static func cancel() {
        if let path = defaults.string(forKey: Key.archivePath) {
            try? FileManager.default.removeItem(atPath: path)
        }
        defaults.removeObject(forKey: Key.archivePath)
        defaults.removeObject(forKey: Key.attempts)
    }

    // MARK: - What the launch path calls

    /// Empties the store if a rebuild is armed, and hands back the archive to restore from.
    ///
    /// Called before the `ModelContainer` is built, which is the only moment the store files
    /// can be removed safely.
    static func beginIfArmed() -> URL? {
        guard let path = defaults.string(forKey: Key.archivePath) else { return nil }
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            defaults.set("The safety copy had gone, so the rebuild was cancelled.", forKey: Key.failure)
            cancel()
            return nil
        }

        let attempts = defaults.integer(forKey: Key.attempts)
        guard attempts < maximumAttempts else {
            defaults.set(
                "The rebuild didn't finish after \(maximumAttempts) tries, so it has been stopped. Your data is unchanged.",
                forKey: Key.failure
            )
            cancel()
            return nil
        }
        defaults.set(attempts + 1, forKey: Key.attempts)

        emptyStore()
        return url
    }

    /// Called once the restore has succeeded. Only now is the archive expendable.
    static func finish(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        defaults.removeObject(forKey: Key.archivePath)
        defaults.removeObject(forKey: Key.attempts)
        defaults.removeObject(forKey: Key.failure)
    }

    // MARK: - Files

    /// Kept in Documents rather than Application Support, which is the directory about to be
    /// emptied, or in the temporary directory, which the system may reclaim between the tap
    /// and the relaunch.
    private static func archiveURL() -> URL {
        let documents = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("StorageRebuild.\(BackupArchive.fileExtension)")
    }

    /// Removes the store and everything hanging off it, external blobs included.
    ///
    /// Deliberately by prefix rather than by deleting Application Support wholesale: the
    /// store is `default.store` with its write-ahead log beside it and its externalised
    /// blobs in `.default_SUPPORT`, and nothing else in that directory belongs to us.
    private static func emptyStore() {
        let manager = FileManager.default
        guard let support = try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        guard let entries = try? manager.contentsOfDirectory(
            at: support, includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("default.store") || name == ".default_SUPPORT" else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}
