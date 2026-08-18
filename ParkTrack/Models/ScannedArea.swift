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
    /// Stands in for "as coarse as it gets". A literal because SwiftData's macro cannot take
    /// an expression as a stored property's default, and 999 degrees is wider than the world.
    static let coarsest: Double = 999

    var minLatitude: Double = 0
    var maxLatitude: Double = 0
    var minLongitude: Double = 0
    var maxLongitude: Double = 0
    var scannedAt: Date = Date()

    /// How finely this ground was searched, as the span in degrees of the individual search
    /// that covered it. A screen swept in a few wide requests and a city indexed in small
    /// tiles are both "searched", but only the fine one can back a claim about how many parks
    /// a place has — so an exhaustive index reuses ground only at its own grade or better.
    /// Records written before this existed decode as the coarsest possible value, which is the
    /// safe reading: they are reused for map browsing but never to shortcut an index.
    var resolution: Double = 999

    /// Which generation of search covered this ground.
    ///
    /// Resolution says how *finely* a cell was searched; this says how *thoroughly*. A cell
    /// swept when the index asked only for map-categorised parks is real coverage, but it is
    /// not the coverage today's sweep would produce — it misses about a tenth of what asking
    /// both ways finds. Rather than silently keeping a total that can no longer be defended,
    /// such ground is re-searched, while anything already done at the current generation is
    /// still skipped. Records written before this existed decode as 0, which is the honest
    /// reading: they came from the single-query sweep.
    var searchGeneration: Int = 0

    init(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double,
        resolution: Double = ScannedArea.coarsest,
        searchGeneration: Int = 0
    ) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
        self.resolution = resolution
        self.searchGeneration = searchGeneration
        self.scannedAt = Date()
    }
}
