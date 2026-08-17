import Foundation
import CoreLocation
import SwiftData

/// A friend added by short code. Their stats and visits are mirrored locally so the
/// leaderboard and feed render instantly and keep working offline.
@Model
final class Friend {
    var friendCode: String = ""
    var displayName: String = ""
    var addedAt: Date = Date()
    var lastSyncedAt: Date?

    // Mirrored summary stats, refreshed on sync.
    var totalParks: Int = 0
    var totalVisits: Int = 0
    var citiesCount: Int = 0
    var currentStreakWeeks: Int = 0
    var parksThisMonth: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \FriendVisit.friend)
    var visits: [FriendVisit]? = []

    @Relationship(deleteRule: .cascade, inverse: \FriendRegionProgress.friend)
    var regions: [FriendRegionProgress]? = []

    init(friendCode: String, displayName: String) {
        self.friendCode = friendCode
        self.displayName = displayName
        self.addedAt = Date()
    }
}

/// One entry in the friends feed: a park a friend logged, with optional media.
@Model
final class FriendVisit {
    var identifier: String = ""
    var parkName: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var regionLabel: String?
    var date: Date = Date()
    var note: String = ""
    var rating: Int = 0
    @Attribute(.externalStorage) var mediaData: Data?
    var mediaIsVideo: Bool = false

    var friend: Friend?

    init(
        identifier: String,
        parkName: String,
        latitude: Double,
        longitude: Double,
        date: Date
    ) {
        self.identifier = identifier
        self.parkName = parkName
        self.latitude = latitude
        self.longitude = longitude
        self.date = date
    }
}

extension FriendVisit {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}


/// A friend's standing in one indexed place, mirrored locally so a head-to-head reads
/// instantly. Both sides count against the same `total`, which is what makes the race fair:
/// it comes from whoever indexed the region, not from how much ground each person happened
/// to have wandered across.
@Model
final class FriendRegionProgress {
    var regionIdentifier: String = ""
    var regionName: String = ""
    var kindRaw: String = RegionKind.city.rawValue
    var visited: Int = 0
    var total: Int = 0
    var updatedAt: Date = Date()

    var friend: Friend?

    init(regionIdentifier: String, regionName: String, kind: RegionKind, visited: Int, total: Int) {
        self.regionIdentifier = regionIdentifier
        self.regionName = regionName
        self.kindRaw = kind.rawValue
        self.visited = visited
        self.total = total
    }

    var kind: RegionKind { RegionKind(rawValue: kindRaw) ?? .city }
    var fraction: Double { total > 0 ? Double(visited) / Double(total) : 0 }
}
