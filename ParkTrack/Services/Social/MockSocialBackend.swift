import Foundation
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

/// Stand-in backend used wherever CloudKit isn't configured — the simulator, unsigned
/// builds, anyone not signed into iCloud.
///
/// It exists so the Friends tab is never an empty shell during development or review:
/// three fictional friends with full visit histories, a couple carrying generated
/// images so the feed's media path gets exercised too. Everything is invented — the
/// park names are made up, and every coordinate is a small offset from an anchor
/// (the user's home when it's set), so the sample data lands wherever the user is
/// rather than pointing at any real place.
final class MockSocialBackend: SocialBackend, @unchecked Sendable {
    /// Set by the service from what the user has actually indexed. Guarded by a lock because
    /// the protocol is Sendable and this is the one piece of mutable state in here.
    private let lock = NSLock()
    private var indexedRegions: [RegionProgressPayload] = []

    func updateIndexedRegions(_ regions: [RegionProgressPayload]) async {
        lock.lock()
        defer { lock.unlock() }
        indexedRegions = regions
    }

    private let profiles: [String: FriendProfilePayload]
    private let visitsByCode: [String: [FriendVisitPayload]]

    /// Codes that resolve in this backend, so the UI can offer them as a demo hint.
    let sampleCodes: [String]

    init(anchor: CLLocationCoordinate2D? = nil) {
        let origin = anchor ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let today = Calendar.current.startOfDay(for: Date())

        var profiles: [String: FriendProfilePayload] = [:]
        var visits: [String: [FriendVisitPayload]] = [:]

        for (index, sample) in Self.samples.enumerated() {
            let generated = Self.makeVisits(for: sample, index: index, origin: origin, today: today)
            visits[sample.code] = generated
            profiles[sample.code] = FriendProfilePayload(
                code: sample.code,
                displayName: sample.name,
                totalParks: generated.count,
                totalVisits: generated.count + index + 2,
                citiesCount: 2 + index,
                currentStreakWeeks: 3 + index * 2,
                parksThisMonth: 2 + index,
                excludedPlaces: Self.makeExclusions(index: index, origin: origin, today: today)
            )
        }

        self.profiles = profiles
        self.visitsByCode = visits
        self.sampleCodes = Self.samples.map(\.code)
    }

    /// A couple of invented rejections per friend, so the adoption screen has something to
    /// show in the simulator. Offsets are small and anchored like everything else here, and
    /// the second friend's pair deliberately land on the same name a few dozen metres apart
    /// — that is the ambiguous case the matcher refuses to guess at, and it should be
    /// reachable without waiting for it to happen in the wild.
    private static func makeExclusions(
        index: Int,
        origin: CLLocationCoordinate2D,
        today: Date
    ) -> [ExcludedPlacePayload] {
        let names = [
            ["Riverside Parcel", "Old Depot Lot"],
            ["Commons Green", "Commons Green"],
            ["Hillside Verge"]
        ][index % 3]

        return names.enumerated().map { offset, name in
            let latitude = origin.latitude + 0.006 * Double(index + 1) + 0.0004 * Double(offset)
            let longitude = origin.longitude - 0.005 * Double(index + 1)
            return ExcludedPlacePayload(
                identifier: Park.identity(
                    name: name,
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                ),
                name: name,
                latitude: latitude,
                longitude: longitude,
                excludedAt: today.addingTimeInterval(-86_400 * Double(offset + 1))
            )
        }
    }

    // MARK: - SocialBackend

    /// Sample standings keyed by nothing real: the identifiers are filled in against
    /// whatever the user has actually indexed, so the race has someone to run against in a
    /// build with no CloudKit. Names stay generic — see the sample data note above.
    private func regionProgress(forSampleAt index: Int) -> [RegionProgressPayload] {
        lock.lock()
        let regions = indexedRegions
        lock.unlock()
        return regions.map { region in
            RegionProgressPayload(
                identifier: region.identifier,
                name: region.name,
                kind: region.kind,
                visited: max(0, min(region.total, region.total / 3 + index)),
                total: region.total
            )
        }
    }

    func fetchProfile(code: String) async throws -> FriendProfilePayload {
        await Self.simulateLatency()
        guard let profile = profiles[code.uppercased()] else { throw SocialError.notFound }
        let index = sampleCodes.firstIndex(of: code.uppercased()) ?? 0
        return FriendProfilePayload(
            code: profile.code,
            displayName: profile.displayName,
            totalParks: profile.totalParks,
            totalVisits: profile.totalVisits,
            citiesCount: profile.citiesCount,
            currentStreakWeeks: profile.currentStreakWeeks,
            parksThisMonth: profile.parksThisMonth,
            regions: regionProgress(forSampleAt: index)
        )
    }

    /// Everything it has, so a mock friend never appears to have deleted anything.
    func visitIdentifiers(code: String) async throws -> Set<String>? {
        Set((visitsByCode[code] ?? []).map(\.identifier))
    }

    func fetchVisits(code: String, since: Date?) async throws -> [FriendVisitPayload] {
        await Self.simulateLatency()
        guard let all = visitsByCode[code.uppercased()] else { throw SocialError.notFound }
        let filtered = since.map { cutoff in all.filter { $0.date > cutoff } } ?? all
        return filtered.sorted { $0.date > $1.date }
    }

    /// Nothing to publish to — sample friends can't see the user. Succeeding quietly
    /// keeps the share flow testable without pretending data left the device.
    func publish(
        profile: FriendProfilePayload,
        visits: [FriendVisitPayload],
        progress: @Sendable @MainActor (Double) -> Void
    ) async throws {
        // Reported in steps rather than in one jump, so the progress view this drives is
        // actually exercised somewhere it can be looked at.
        for step in 1...4 {
            await Self.simulateLatency()
            await MainActor.run { progress(Double(step) / 4) }
        }
    }

    // MARK: - Sample data

    private struct Sample {
        let code: String
        let name: String
        let visitCount: Int
        let daySpacing: Int
    }

    private static let samples: [Sample] = [
        Sample(code: "CEDAR3", name: "Avery", visitCount: 9, daySpacing: 4),
        Sample(code: "MAPLE7", name: "Jordan", visitCount: 6, daySpacing: 7),
        Sample(code: "SUMMT5", name: "Rowan", visitCount: 12, daySpacing: 3)
    ]

    private static let parkNames = [
        "Cedar Ridge Park",
        "Lakeview Commons",
        "Willow Creek Greenway",
        "Harbor Point Preserve",
        "Maple Hollow Park",
        "Sunset Meadows",
        "Stonebridge Trailhead",
        "Birch Grove Park",
        "Quarry Lake Reserve",
        "Elmwood Square",
        "Fox Run Nature Area",
        "Old Mill Riverfront"
    ]

    private static let notes = [
        "",
        "Long loop around the pond, worth the detour.",
        "Quiet on a weekday morning.",
        "",
        "Great picnic spot near the north entrance.",
        "Muddy after the rain but the trail held up."
    ]

    private static func makeVisits(
        for sample: Sample,
        index: Int,
        origin: CLLocationCoordinate2D,
        today: Date
    ) -> [FriendVisitPayload] {
        (0..<sample.visitCount).map { position in
            let seed = index * 7 + position
            let name = parkNames[seed % parkNames.count]

            // Roughly a 1-2 km lattice around the anchor: close enough to feel local
            // anywhere on earth, spread out enough to draw as distinct map pins.
            let latitude = origin.latitude + Double((seed % 5) - 2) * 0.012 + Double(index) * 0.004
            let longitude = origin.longitude + Double((seed % 7) - 3) * 0.014 - Double(index) * 0.005

            let daysAgo = position * sample.daySpacing + index
            let date = today.addingTimeInterval(-Double(daysAgo) * 86_400 + Double(9 + seed % 8) * 3_600)

            let media: Data? = position < 2 && index != 1 ? sampleImageData(seed: seed) : nil

            return FriendVisitPayload(
                identifier: "mock-\(sample.code)-\(position)",
                parkName: name,
                latitude: latitude,
                longitude: longitude,
                regionLabel: nil,
                date: date,
                note: notes[seed % notes.count],
                rating: 3 + (seed % 3),
                mediaData: media,
                mediaIsVideo: false,
                // Every third one, so the simulator shows what a friend's marked-visited
                // park looks like and where it sorts. There is no other way to see it
                // without two signed devices and a backlog between them.
                isUndated: seed % 3 == 0
            )
        }
    }

    /// A flat two-tone gradient stands in for a photo. Generated rather than bundled
    /// so no image asset ships in the app for data that only exists in demo mode.
    private static func sampleImageData(seed: Int) -> Data? {
        #if canImport(UIKit)
        let size = CGSize(width: 320, height: 320)
        let hue = Double((seed * 37) % 100) / 100.0
        let top = UIColor(hue: hue, saturation: 0.45, brightness: 0.72, alpha: 1)
        let bottom = UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                             saturation: 0.55, brightness: 0.45, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            top.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            bottom.setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.55, width: size.width, height: size.height * 0.45))
        }
        return image.jpegData(compressionQuality: 0.7)
        #else
        return nil
        #endif
    }

    private static func simulateLatency() async {
        try? await Task.sleep(for: .milliseconds(250))
    }
}
