import Foundation
import CoreLocation
import SwiftData

/// Somewhere a friend has struck off as "not a park".
///
/// A local mirror of what a friend published, kept for two quite separate reasons.
///
/// The first is fairness, and it needs no action from anyone. A race is only meaningful if
/// both sides count against the same denominator, and striking a place off changes what
/// that denominator is. Two people who have rejected different places are already racing
/// on different totals — so the standings subtract the union of both sides' rejections,
/// which makes the percentages comparable the moment two people connect.
///
/// The second is labour. Deciding that the map is wrong about a place is work, and it is
/// the same work for everyone who walks the same ground, so a friend who has already done
/// it can be borrowed from. That half is strictly opt-in and never automatic: see
/// `ExclusionMatch`.
@Model
final class FriendExclusion {
    /// `Park.identity(name:coordinate:)` as the friend computed it. Not assumed to equal
    /// the local identity for the same place — see `ExclusionMatcher` for why.
    var identifier: String = ""
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var excludedAt: Date = Date()

    var friend: Friend?

    init(identifier: String, name: String, latitude: Double, longitude: Double, excludedAt: Date = Date()) {
        self.identifier = identifier
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.excludedAt = excludedAt
    }
}

extension FriendExclusion {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}
