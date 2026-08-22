import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

/// The check that stands between a rebuild and losing everything.
///
/// A rebuild deletes the store. The only thing making that acceptable is that the archive it
/// will restore from has already been read back and found to describe the same store — so
/// these are about the ways that check must refuse, not the ways it passes. A verification
/// that waves something through is indistinguishable from no verification at all right up
/// until the moment it matters.
@MainActor
final class StorageRebuildTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var scratch: URL!

    override func setUpWithError() throws {
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebuild-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        context = nil
        container = nil
    }

    private func settings() -> BackupSettings {
        BackupSettings(
            displayName: "Nv", friendCode: "ABC234",
            placeCoordinates: [:], placeLabels: [:],
            customRadiusMiles: 25, hasCompletedOnboarding: true
        )
    }

    @discardableResult
    private func populate(parks: Int, visitsEach: Int, mediaEach: Int) -> [Park] {
        var made: [Park] = []
        for index in 0..<parks {
            let lat = 47.6 + Double(index) / 1000
            let park = Park(
                identifier: Park.identity(name: "Park \(index)", coordinate: .init(latitude: lat, longitude: -122.3)),
                name: "Park \(index)",
                latitude: lat,
                longitude: -122.3
            )
            context.insert(park)
            for _ in 0..<visitsEach {
                let visit = Visit(date: Date(), park: park)
                context.insert(visit)
                for slot in 0..<mediaEach {
                    let item = MediaItem(data: Data(repeating: UInt8(slot + 1), count: 512), isVideo: false)
                    item.visit = visit
                    context.insert(item)
                }
            }
            made.append(park)
        }
        try? context.save()
        return made
    }

    private func writeArchive(to name: String) throws -> URL {
        let parks = try context.fetch(FetchDescriptor<Park>())
        let payload = DataExport.makeBackup(parks: parks, settings: settings())
        let url = scratch.appendingPathComponent(name)
        try DataExport.writeArchive(payload: payload, parks: parks, to: url)
        return url
    }

    /// The happy path, so the refusals below mean something.
    func testVerificationPassesForAFaithfulArchive() throws {
        populate(parks: 3, visitsEach: 2, mediaEach: 1)
        let url = try writeArchive(to: "good.\(BackupArchive.fileExtension)")
        XCTAssertNoThrow(try StorageRebuild.verify(url, against: context))
    }

    /// An archive written before more was added no longer describes the store, and
    /// rebuilding from it would silently drop the difference.
    func testVerificationRefusesAnArchiveThatIsBehindTheStore() throws {
        populate(parks: 2, visitsEach: 1, mediaEach: 1)
        let url = try writeArchive(to: "stale.\(BackupArchive.fileExtension)")

        populate(parks: 1, visitsEach: 1, mediaEach: 1)

        XCTAssertThrowsError(try StorageRebuild.verify(url, against: context)) { error in
            XCTAssertTrue(
                "\(error)".contains("parks"),
                "expected the refusal to name what disagreed, got: \(error)"
            )
        }
    }

    /// A file cut short — a full disk, an interrupted write — must not arm a deletion.
    func testVerificationRefusesATruncatedArchive() throws {
        populate(parks: 2, visitsEach: 1, mediaEach: 2)
        let url = try writeArchive(to: "cut.\(BackupArchive.fileExtension)")

        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count / 2).write(to: url)

        XCTAssertThrowsError(try StorageRebuild.verify(url, against: context))
    }

    func testVerificationRefusesSomethingThatIsNotAnArchive() throws {
        populate(parks: 1, visitsEach: 1, mediaEach: 0)
        let url = scratch.appendingPathComponent("nonsense.\(BackupArchive.fileExtension)")
        try Data("not a backup".utf8).write(to: url)

        XCTAssertThrowsError(try StorageRebuild.verify(url, against: context))
    }

    /// The count that matters most: an archive whose manifest promises attachments it does
    /// not contain would pass a row count and still lose photographs.
    func testVerificationRefusesAnArchiveMissingItsMedia() throws {
        populate(parks: 1, visitsEach: 1, mediaEach: 2)
        let parks = try context.fetch(FetchDescriptor<Park>())
        let payload = DataExport.makeBackup(parks: parks, settings: settings())

        // A manifest claiming media, written with none of the blobs beside it.
        let url = scratch.appendingPathComponent("hollow.\(BackupArchive.fileExtension)")
        let writer = try BackupArchiveWriter(url: url)
        try writer.writeManifest(try DataExport.encode(payload))
        try writer.finish()

        XCTAssertThrowsError(try StorageRebuild.verify(url, against: context)) { error in
            XCTAssertTrue(
                "\(error)".contains("missing"),
                "expected the refusal to say something is missing, got: \(error)"
            )
        }
    }
}
