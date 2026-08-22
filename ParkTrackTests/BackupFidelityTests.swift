import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

/// What a backup actually carries across a wipe-and-reinstall.
///
/// These exist because a backup is only trustworthy field by field. "It exported and
/// imported without an error" is not the same claim as "the store on the other side says
/// what this one said", and the gap between those two is where a migration quietly loses
/// something. Every test here goes through a real archive file on disk rather than passing
/// a payload straight from `makeBackup` to `merge`, so the container is under test too.
@MainActor
final class BackupFidelityTests: XCTestCase {

    private var source: ModelContext!
    private var destination: ModelContext!
    private var sourceContainer: ModelContainer!
    private var destinationContainer: ModelContainer!
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        sourceContainer = PersistenceController.makeInMemoryContainer()
        destinationContainer = PersistenceController.makeInMemoryContainer()
        source = ModelContext(sourceContainer)
        destination = ModelContext(destinationContainer)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        source = nil; destination = nil
        sourceContainer = nil; destinationContainer = nil
        scratch = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 12))!
    }

    private func settings(
        name: String = "Nv",
        code: String = "ABC234",
        places: [String: [Double]] = ["home": [47.6, -122.3], "school": [47.7, -122.2]],
        labels: [String: String] = ["school": "Campus"]
    ) -> BackupSettings {
        BackupSettings(
            displayName: name,
            friendCode: code,
            placeCoordinates: places,
            placeLabels: labels,
            customRadiusMiles: 25,
            hasCompletedOnboarding: true
        )
    }

    @discardableResult
    private func makePark(_ name: String, lat: Double = 47.6, lon: Double = -122.3) -> Park {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let park = Park(
            identifier: Park.identity(name: name, coordinate: coordinate),
            name: name,
            latitude: lat,
            longitude: lon
        )
        source.insert(park)
        return park
    }

    /// Export everything in `source` to a real file, then import it into `destination`.
    @discardableResult
    private func roundTrip(includeMedia: Bool = true) throws -> DataExport.ImportResult {
        let parks = try source.fetch(FetchDescriptor<Park>())
        let payload = DataExport.makeBackup(
            parks: parks,
            excludedPlaces: try source.fetch(FetchDescriptor<ExcludedPlace>()),
            scannedAreas: try source.fetch(FetchDescriptor<ScannedArea>()),
            regionIndexes: try source.fetch(FetchDescriptor<RegionIndex>()),
            friends: try source.fetch(FetchDescriptor<Friend>()),
            settings: settings(),
            includeMedia: includeMedia
        )
        let url = scratch.appendingPathComponent("test.\(BackupArchive.fileExtension)")
        try? FileManager.default.removeItem(at: url)
        try DataExport.writeArchive(payload: payload, parks: parks, to: url)
        return try DataExport.importArchive(at: url, into: destination)
    }

    private func restoredParks() throws -> [Park] {
        try destination.fetch(FetchDescriptor<Park>())
    }

    // MARK: - Parks and visits

    func testDatedVisitSurvivesRoundTrip() throws {
        let park = makePark("Discovery Park")
        park.locality = "Seattle"
        park.administrativeArea = "WA"
        park.isWishlisted = true

        let visit = Visit(
            date: day(2025, 4, 2),
            durationMinutes: 90,
            notes: "cherry blossoms",
            rating: 5,
            companions: "Sam",
            park: park
        )
        visit.weatherSummary = "clear"
        source.insert(visit)
        try source.save()

        try roundTrip()

        let restored = try XCTUnwrap(try restoredParks().first)
        XCTAssertEqual(restored.name, "Discovery Park")
        XCTAssertEqual(restored.locality, "Seattle")
        XCTAssertEqual(restored.administrativeArea, "WA")
        XCTAssertTrue(restored.isWishlisted)

        let restoredVisit = try XCTUnwrap(restored.visits?.first)
        XCTAssertEqual(restoredVisit.date, day(2025, 4, 2))
        XCTAssertEqual(restoredVisit.durationMinutes, 90)
        XCTAssertEqual(restoredVisit.notes, "cherry blossoms")
        XCTAssertEqual(restoredVisit.rating, 5)
        XCTAssertEqual(restoredVisit.companions, "Sam")
        XCTAssertEqual(restoredVisit.weatherSummary, "clear")
    }

    /// A visit marked "I've been here, I don't know when" must not come back claiming a day.
    func testUndatedVisitStaysUndated() throws {
        let park = makePark("Green Lake Park")
        source.insert(Visit.undated(park: park))
        try source.save()

        try roundTrip()

        let restoredVisit = try XCTUnwrap(try restoredParks().first?.visits?.first)
        XCTAssertTrue(restoredVisit.isUndated, "an undated visit came back with a date it never had")
        XCTAssertNil(restoredVisit.knownDate)
        XCTAssertTrue(try XCTUnwrap(try restoredParks().first).isVisitedWithoutADate)
    }

    /// The stat-level consequence, stated on its own so a regression names the symptom.
    func testUndatedBacklogDoesNotInventATimeline() throws {
        for (offset, name) in ["A Park", "B Park", "C Park"].enumerated() {
            let park = makePark(name, lat: 47.6 + Double(offset) / 100)
            source.insert(Visit.undated(park: park))
        }
        try source.save()

        try roundTrip()

        let dated = try restoredParks().flatMap { $0.datedVisits }
        XCTAssertTrue(dated.isEmpty, "\(dated.count) undated visits gained a date across the backup")
    }

    // MARK: - Media

    func testPhotosAndVideoSurviveRoundTrip() throws {
        let park = makePark("Gas Works Park")
        let visit = Visit(date: day(2025, 7, 1), park: park)
        source.insert(visit)

        let photoBytes = Data((0..<4096).map { UInt8($0 % 251) })
        let posterBytes = Data((0..<512).map { UInt8($0 % 199) })
        let photo = MediaItem(data: photoBytes, isVideo: false)
        photo.visit = visit
        source.insert(photo)

        let video = MediaItem(data: Data(repeating: 0xAB, count: 8192), isVideo: true, thumbnailData: posterBytes)
        video.visit = visit
        source.insert(video)
        try source.save()

        let result = try roundTrip()
        XCTAssertEqual(result.summary.mediaAdded, 2)

        let restoredVisit = try XCTUnwrap(try restoredParks().first?.visits?.first)
        let media = restoredVisit.sortedMedia
        XCTAssertEqual(media.count, 2)

        let restoredPhoto = try XCTUnwrap(media.first { !$0.isVideo })
        XCTAssertEqual(restoredPhoto.data, photoBytes, "photo bytes changed in transit")

        let restoredVideo = try XCTUnwrap(media.first { $0.isVideo })
        XCTAssertEqual(restoredVideo.data?.count, 8192)
        XCTAssertEqual(restoredVideo.thumbnailData, posterBytes, "poster frame changed in transit")
    }

    /// Turning media off must leave the visit intact and simply carry no attachments.
    func testMediaCanBeLeftOut() throws {
        let park = makePark("Gas Works Park")
        let visit = Visit(date: day(2025, 7, 1), park: park)
        source.insert(visit)
        let photo = MediaItem(data: Data(repeating: 1, count: 1024), isVideo: false)
        photo.visit = visit
        source.insert(photo)
        try source.save()

        let result = try roundTrip(includeMedia: false)
        XCTAssertEqual(result.summary.mediaAdded, 0)
        XCTAssertEqual(result.summary.visitsAdded, 1)

        let restoredVisit = try XCTUnwrap(try restoredParks().first?.visits?.first)
        XCTAssertTrue(restoredVisit.sortedMedia.isEmpty)
    }

    // MARK: - The other stores

    func testExclusionsSurvive() throws {
        source.insert(ExcludedPlace(
            identifier: "some lawn|47.61|-122.31",
            name: "Some Lawn",
            latitude: 47.61,
            longitude: -122.31
        ))
        try source.save()

        try roundTrip()

        let restored = try destination.fetch(FetchDescriptor<ExcludedPlace>())
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.name, "Some Lawn")
        XCTAssertEqual(restored.first?.identifier, "some lawn|47.61|-122.31")
    }

    func testScannedAreasSurvive() throws {
        source.insert(ScannedArea(
            minLatitude: 47.5, maxLatitude: 47.7,
            minLongitude: -122.4, maxLongitude: -122.2,
            resolution: 0.02, searchGeneration: 5
        ))
        try source.save()

        try roundTrip()

        let restored = try destination.fetch(FetchDescriptor<ScannedArea>())
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.resolution, 0.02)
        XCTAssertEqual(restored.first?.searchGeneration, 5)
        XCTAssertEqual(restored.first?.maxLatitude, 47.7)
    }

    func testRegionIndexesSurvive() throws {
        let index = RegionIndex(
            identifier: RegionIndex.identity(kind: .city, name: "Seattle", container: "WA"),
            kind: .city,
            name: "Seattle",
            container: "WA",
            country: "United States",
            center: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            radiusMeters: 20_000
        )
        index.parkCount = 412
        index.indexedAt = day(2025, 3, 1)
        index.indexerVersion = RegionIndex.currentIndexerVersion
        source.insert(index)
        try source.save()

        try roundTrip()

        let restored = try XCTUnwrap(try destination.fetch(FetchDescriptor<RegionIndex>()).first)
        XCTAssertEqual(restored.parkCount, 412, "the denominator behind every percentage was lost")
        XCTAssertEqual(restored.indexerVersion, RegionIndex.currentIndexerVersion)
        XCTAssertTrue(restored.isIndexed)
        XCTAssertEqual(restored.name, "Seattle")
    }

    /// A fresh install discovers a region before it sweeps it, leaving an empty placeholder
    /// record. That must not block the real index arriving in the backup.
    func testAnIndexBeatsAnUnsweptPlaceholder() throws {
        let seattle = "city|seattle|wa"
        for offset in 0..<3 {
            let park = makePark("Park \(offset)", lat: 47.6 + Double(offset) / 1000)
            park.locality = "Seattle"
            park.administrativeArea = "WA"
        }
        let index = RegionIndex(
            identifier: seattle, kind: .city, name: "Seattle", container: "WA",
            country: "United States",
            center: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            radiusMeters: 20_000
        )
        index.parkCount = 3
        index.indexedAt = day(2025, 3, 1)
        index.indexerVersion = RegionIndex.currentIndexerVersion
        source.insert(index)
        try source.save()

        // The new install has met Seattle but never swept it: same generation counter (0),
        // no indexedAt. The old rule compared versions only and would have kept this.
        let placeholder = RegionIndex(
            identifier: seattle, kind: .city, name: "Seattle", container: "WA",
            country: "United States",
            center: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            radiusMeters: 20_000
        )
        destination.insert(placeholder)
        try destination.save()

        try roundTrip()

        let restored = try XCTUnwrap(try destination.fetch(FetchDescriptor<RegionIndex>()).first)
        XCTAssertNotNil(restored.indexedAt, "an empty placeholder blocked the real index")
        XCTAssertTrue(restored.isIndexed)
        XCTAssertEqual(restored.parkCount, 3)
    }

    /// A region's total is the parks on *this* device, so it has to be re-totalled after an
    /// import moves parks around — including after the import strikes some off.
    func testTotalsAreRecountedAgainstWhatActuallyLanded() throws {
        let seattle = "city|seattle|wa"
        for offset in 0..<4 {
            let park = makePark("Park \(offset)", lat: 47.6 + Double(offset) / 1000)
            park.locality = "Seattle"
            park.administrativeArea = "WA"
        }
        // One of those four is also rejected, so only three should survive the import.
        let doomed = try XCTUnwrap(try source.fetch(FetchDescriptor<Park>()).first { $0.name == "Park 3" })
        source.insert(ExcludedPlace(park: doomed))

        let index = RegionIndex(
            identifier: seattle, kind: .city, name: "Seattle", container: "WA",
            country: "United States",
            center: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            radiusMeters: 20_000
        )
        index.parkCount = 4          // true when the backup was written
        index.indexedAt = day(2025, 3, 1)
        index.indexerVersion = RegionIndex.currentIndexerVersion
        source.insert(index)
        try source.save()

        try roundTrip()

        XCTAssertEqual(try restoredParks().count, 3, "the rejected park was restored anyway")
        let restored = try XCTUnwrap(try destination.fetch(FetchDescriptor<RegionIndex>()).first)
        XCTAssertEqual(
            restored.parkCount, 3,
            "the denominator still claims a park the import deliberately struck off"
        )
    }

    /// Friends come back as identity only — their feed re-pulls rather than restoring stale.
    func testFriendsSurviveAsIdentityOnly() throws {
        let friend = Friend(friendCode: "XYZ789", displayName: "Sam")
        friend.totalParks = 99
        source.insert(friend)
        let stale = FriendVisit(identifier: "v1", parkName: "Somewhere", latitude: 1, longitude: 2, date: Date())
        stale.friend = friend
        source.insert(stale)
        try source.save()

        try roundTrip()

        let restored = try XCTUnwrap(try destination.fetch(FetchDescriptor<Friend>()).first)
        XCTAssertEqual(restored.friendCode, "XYZ789")
        XCTAssertEqual(restored.displayName, "Sam")
        XCTAssertEqual(restored.totalParks, 0, "stale stats were restored instead of being re-pulled")
        XCTAssertTrue(try destination.fetch(FetchDescriptor<FriendVisit>()).isEmpty)
    }

    func testSettingsComeBackIncludingSchoolAndWork() throws {
        makePark("Anywhere")
        try source.save()

        let result = try roundTrip()

        let defaults = UserDefaults(suiteName: "backup-test-\(UUID().uuidString)")!
        let restored = AppSettings(defaults: defaults)
        restored.apply(result.settings)

        XCTAssertEqual(restored.displayName, "Nv")
        XCTAssertEqual(restored.friendCode, "ABC234", "the friend code changed, so friends lose the user")
        XCTAssertEqual(restored.coordinate(for: .home)?.latitude ?? 0, 47.6, accuracy: 0.0001)
        XCTAssertEqual(restored.coordinate(for: .school)?.latitude ?? 0, 47.7, accuracy: 0.0001)
        XCTAssertEqual(restored.label(for: .school), "Campus")
        XCTAssertNil(restored.coordinate(for: .work))
        XCTAssertTrue(restored.hasCompletedOnboarding)
    }

    /// An import must never overwrite what the user has already typed on this install.
    func testSettingsDoNotClobberAUsedInstall() throws {
        makePark("Anywhere")
        try source.save()
        let result = try roundTrip()

        let defaults = UserDefaults(suiteName: "backup-test-\(UUID().uuidString)")!
        let existing = AppSettings(defaults: defaults)
        existing.displayName = "Someone Else"
        let ownCode = existing.friendCode

        existing.apply(result.settings)

        XCTAssertEqual(existing.displayName, "Someone Else")
        XCTAssertEqual(existing.friendCode, ownCode)
        // Places were blank locally, so those still fill in.
        XCTAssertNotNil(existing.coordinate(for: .school))
    }

    // MARK: - Two parks with the same name

    /// Boston Common and the other Boston Common 150 m away are different places, and a
    /// backup must not fold them together.
    func testSameNameParksStayDistinct() throws {
        let lat = 42.3550
        let lon = -71.0656
        makePark("Boston Common", lat: lat, lon: lon)
        makePark("Boston Common", lat: lat + 0.00135, lon: lon) // ~150 m north
        try source.save()

        try roundTrip()

        let restored = try restoredParks()
        XCTAssertEqual(restored.count, 2, "two same-name parks collapsed into one across the backup")
        XCTAssertEqual(Set(restored.map(\.identifier)).count, 2)
    }

    /// Striking off one of them and keeping the other must survive verbatim: the excluded
    /// one stays excluded, and the one next door is still there.
    func testStrikingOffOneOfTwoSameNameParks() throws {
        let lat = 42.3550
        let lon = -71.0656
        let kept = makePark("Boston Common", lat: lat, lon: lon)
        let struckOff = makePark("Boston Common", lat: lat + 0.00135, lon: lon)

        let struckIdentifier = struckOff.identifier
        let keptIdentifier = kept.identifier
        source.insert(ExcludedPlace(park: struckOff))
        source.delete(struckOff)
        try source.save()

        try roundTrip()

        let restored = try restoredParks()
        XCTAssertEqual(restored.count, 1, "the wrong number of Boston Commons came back")
        XCTAssertEqual(restored.first?.identifier, keptIdentifier)

        let exclusions = try destination.fetch(FetchDescriptor<ExcludedPlace>())
        XCTAssertEqual(exclusions.count, 1)
        XCTAssertEqual(exclusions.first?.identifier, struckIdentifier)
        XCTAssertNotEqual(exclusions.first?.identifier, keptIdentifier)
    }

    // MARK: - A restore must not put back what the file says isn't a park

    /// A backup naming the same place in both lists must not resurrect it.
    func testABackupCarryingBothAParkAndItsExclusionDoesNotRestoreIt() throws {
        let park = makePark("Some Lawn", lat: 47.61, lon: -122.31)
        source.insert(ExcludedPlace(park: park))
        try source.save()

        let result = try roundTrip()

        XCTAssertTrue(try restoredParks().isEmpty, "the import restored a place the same file rejects")
        XCTAssertEqual(try destination.fetch(FetchDescriptor<ExcludedPlace>()).count, 1)
        XCTAssertEqual(result.summary.parksAdded, 0)
    }

    /// The order that actually bit: a fresh install sweeps before anyone imports anything,
    /// so the catalogue is already full of places the backup is about to reject.
    func testImportStrikesOffWhatAnEarlierSweepAlreadyFiled() throws {
        // The backup knows only that this place is not a park.
        let rejected = makePark("Some Lawn", lat: 47.61, lon: -122.31)
        let identifier = rejected.identifier
        source.insert(ExcludedPlace(park: rejected))
        source.delete(rejected)
        makePark("Discovery Park", lat: 47.65, lon: -122.41)
        try source.save()

        // Meanwhile the new install has swept and filed it, knowing of no rejections.
        let swept = Park(
            identifier: identifier,
            name: "Some Lawn",
            latitude: 47.61,
            longitude: -122.31
        )
        destination.insert(swept)
        try destination.save()

        let result = try roundTrip()

        let names = try restoredParks().map(\.name)
        XCTAssertFalse(names.contains("Some Lawn"), "a swept-in park survived the rejection that arrived with the backup")
        XCTAssertTrue(names.contains("Discovery Park"), "reconciliation removed something it had no business touching")
        XCTAssertEqual(result.summary.parksStruckOff, 1)
    }

    /// And it has to work when the two identifiers disagree, which `ParkIdentityProbe`
    /// measures happening for about 9% of one-metre re-finds.
    func testStrikingOffSurvivesGridDrift() throws {
        source.insert(ExcludedPlace(
            identifier: Park.identity(
                name: "Some Lawn",
                coordinate: CLLocationCoordinate2D(latitude: 42.354949, longitude: -71.0656)
            ),
            name: "Some Lawn",
            latitude: 42.354949,
            longitude: -71.0656
        ))
        try source.save()

        let drifted = Park(
            identifier: Park.identity(
                name: "Some Lawn",
                coordinate: CLLocationCoordinate2D(latitude: 42.354951, longitude: -71.0656)
            ),
            name: "Some Lawn",
            latitude: 42.354951,
            longitude: -71.0656
        )
        XCTAssertNotEqual(
            drifted.identifier,
            try source.fetch(FetchDescriptor<ExcludedPlace>()).first?.identifier,
            "this test is pointless if the identifiers agree"
        )
        destination.insert(drifted)
        try destination.save()

        try roundTrip()
        XCTAssertTrue(try restoredParks().isEmpty, "grid drift let a rejected place survive the import")
    }

    /// A namesake far away is a different place and must be left alone.
    func testStrikingOffDoesNotReachADistantNamesake() throws {
        source.insert(ExcludedPlace(
            identifier: "boston common|42.355|-71.0656",
            name: "Boston Common",
            latitude: 42.3550,
            longitude: -71.0656
        ))
        try source.save()

        let elsewhere = Park(
            identifier: Park.identity(
                name: "Boston Common",
                coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)
            ),
            name: "Boston Common",
            latitude: 47.6,
            longitude: -122.3
        )
        destination.insert(elsewhere)
        try destination.save()

        try roundTrip()
        XCTAssertEqual(try restoredParks().count, 1, "a rejection in Boston removed a park in Seattle")
    }

    /// Never at the cost of visits: a contradiction in the data is resolved the way that
    /// cannot destroy anything.
    func testAVisitedParkIsNeverStruckOffByAnImport() throws {
        source.insert(ExcludedPlace(
            identifier: Park.identity(
                name: "Some Lawn",
                coordinate: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.31)
            ),
            name: "Some Lawn",
            latitude: 47.61,
            longitude: -122.31
        ))
        try source.save()

        let visited = Park(
            identifier: Park.identity(
                name: "Some Lawn",
                coordinate: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.31)
            ),
            name: "Some Lawn",
            latitude: 47.61,
            longitude: -122.31
        )
        destination.insert(visited)
        let visit = Visit(date: day(2025, 5, 1), park: visited)
        destination.insert(visit)
        let photo = MediaItem(data: Data(repeating: 4, count: 128), isVideo: false)
        photo.visit = visit
        destination.insert(photo)
        try destination.save()

        try roundTrip()

        XCTAssertEqual(try restoredParks().count, 1, "an import deleted a park the user had visited")
        XCTAssertEqual(try destination.fetch(FetchDescriptor<Visit>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<MediaItem>()).count, 1)
    }

    /// Re-importing the same file is how someone already in the broken state gets out of it.
    func testReimportingRepairsACatalogueThatAlreadyWentWrong() throws {
        let rejected = makePark("Some Lawn", lat: 47.61, lon: -122.31)
        let identifier = rejected.identifier
        source.insert(ExcludedPlace(park: rejected))
        source.delete(rejected)
        try source.save()

        // The state the bug left behind: the rejection imported, the park swept in anyway.
        destination.insert(ExcludedPlace(
            identifier: identifier, name: "Some Lawn", latitude: 47.61, longitude: -122.31
        ))
        destination.insert(Park(
            identifier: identifier, name: "Some Lawn", latitude: 47.61, longitude: -122.31
        ))
        try destination.save()

        let result = try roundTrip()

        XCTAssertTrue(try restoredParks().isEmpty, "re-importing did not repair the catalogue")
        XCTAssertEqual(result.summary.parksStruckOff, 1)
        XCTAssertEqual(result.summary.exclusionsAdded, 0, "the rejection was already there")
    }

    // MARK: - Idempotence and bad input

    /// Importing the same file twice must change nothing the second time.
    func testReimportAddsNothing() throws {
        let park = makePark("Discovery Park")
        source.insert(Visit(date: day(2025, 4, 2), park: park))
        source.insert(ExcludedPlace(identifier: "x|1.0|2.0", name: "X", latitude: 1, longitude: 2))
        source.insert(ScannedArea(
            minLatitude: 1, maxLatitude: 2, minLongitude: 3, maxLongitude: 4,
            resolution: 0.01, searchGeneration: 5
        ))
        source.insert(Friend(friendCode: "AAA111", displayName: "Sam"))
        try source.save()

        let parks = try source.fetch(FetchDescriptor<Park>())
        let payload = DataExport.makeBackup(
            parks: parks,
            excludedPlaces: try source.fetch(FetchDescriptor<ExcludedPlace>()),
            scannedAreas: try source.fetch(FetchDescriptor<ScannedArea>()),
            regionIndexes: [],
            friends: try source.fetch(FetchDescriptor<Friend>()),
            settings: settings()
        )
        let url = scratch.appendingPathComponent("twice.\(BackupArchive.fileExtension)")
        try DataExport.writeArchive(payload: payload, parks: parks, to: url)

        let first = try DataExport.importArchive(at: url, into: destination)
        XCTAssertFalse(first.summary.isEmpty)

        let second = try DataExport.importArchive(at: url, into: destination)
        XCTAssertTrue(second.summary.isEmpty, "a second import duplicated something: \(second.summary)")

        XCTAssertEqual(try destination.fetch(FetchDescriptor<Park>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<Visit>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<ExcludedPlace>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<ScannedArea>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<Friend>()).count, 1)
    }

    /// Importing the same file twice must not double the photos on disk.
    ///
    /// Media is the expensive thing to get wrong: a duplicated row means a duplicated blob
    /// in external storage, and a library of a hundred megabytes becomes two hundred with
    /// nothing on screen to show for it. Split out from the general idempotence test, which
    /// counted rows in every store except this one.
    func testReimportDoesNotDuplicateMedia() throws {
        let park = makePark("Gas Works Park")
        let visit = Visit(date: day(2025, 7, 1), park: park)
        source.insert(visit)
        for index in 0..<3 {
            let item = MediaItem(
                data: Data(repeating: UInt8(index + 1), count: 2048),
                isVideo: false,
                thumbnailData: Data(repeating: UInt8(index + 100), count: 256)
            )
            item.visit = visit
            source.insert(item)
        }
        try source.save()

        let parks = try source.fetch(FetchDescriptor<Park>())
        let payload = DataExport.makeBackup(parks: parks, settings: settings())
        let url = scratch.appendingPathComponent("twice-media.\(BackupArchive.fileExtension)")
        try DataExport.writeArchive(payload: payload, parks: parks, to: url)

        let first = try DataExport.importArchive(at: url, into: destination)
        XCTAssertEqual(first.summary.mediaAdded, 3)

        let afterFirst = try destination.fetch(FetchDescriptor<MediaItem>())
        let bytesAfterFirst = afterFirst.reduce(0) { $0 + ($1.data?.count ?? 0) + ($1.thumbnailData?.count ?? 0) }

        let second = try DataExport.importArchive(at: url, into: destination)
        XCTAssertEqual(second.summary.mediaAdded, 0, "a second import added media again")

        let afterSecond = try destination.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(afterSecond.count, 3, "importing twice duplicated the photos")
        XCTAssertEqual(
            afterSecond.reduce(0) { $0 + ($1.data?.count ?? 0) + ($1.thumbnailData?.count ?? 0) },
            bytesAfterFirst,
            "importing twice changed how many bytes of media are stored"
        )
        XCTAssertEqual(try destination.fetch(FetchDescriptor<Visit>()).count, 1)
        XCTAssertEqual(Set(afterSecond.map(\.identifier)).count, 3, "media identifiers stopped being unique")
    }

    func testRandomFileIsRejected() throws {
        let url = scratch.appendingPathComponent("nonsense.\(BackupArchive.fileExtension)")
        try Data("this is not a backup, it is a haiku".utf8).write(to: url)

        XCTAssertThrowsError(try DataExport.importArchive(at: url, into: destination)) { error in
            XCTAssertEqual(error as? BackupArchiveError, .notAnArchive)
        }
    }

    func testTruncatedArchiveIsRejected() throws {
        let park = makePark("Somewhere")
        let visit = Visit(date: day(2025, 1, 1), park: park)
        source.insert(visit)
        let photo = MediaItem(data: Data(repeating: 7, count: 4096), isVideo: false)
        photo.visit = visit
        source.insert(photo)
        try source.save()

        let parks = try source.fetch(FetchDescriptor<Park>())
        let payload = DataExport.makeBackup(parks: parks, settings: settings())
        let url = scratch.appendingPathComponent("cut.\(BackupArchive.fileExtension)")
        try DataExport.writeArchive(payload: payload, parks: parks, to: url)

        // Lop off the tail, as an interrupted AirDrop or a full disk would.
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count - 2048).write(to: url)

        XCTAssertThrowsError(try DataExport.importArchive(at: url, into: destination))
    }
}

extension BackupArchiveError: @retroactive Equatable {
    public static func == (lhs: BackupArchiveError, rhs: BackupArchiveError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}
