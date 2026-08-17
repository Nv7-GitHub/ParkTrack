import Foundation
import MapKit
import SwiftData

/// A rectangle of ground that has actually been searched.
///
/// The parks found by a search are saved, but until this existed the knowledge of *where* the
/// app had looked lived only in memory — so every launch forgot it, and the map re-searched
/// the same streets it had already paid for, over and over. Areas are as worth caching as the
/// parks in them, and rather more so: a park that opened since is one new result, while a
/// re-scan is a dozen requests against a rate limit.
@Model
final class ScannedArea {
    var minLatitude: Double = 0
    var maxLatitude: Double = 0
    var minLongitude: Double = 0
    var maxLongitude: Double = 0
    var scannedAt: Date = Date()

    init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
        self.scannedAt = Date()
    }
}
