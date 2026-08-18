import Foundation
import SwiftData

/// Somewhere the map files as a park and the user says is not one.
///
/// Deleting the park is not enough by itself. The map has not changed its mind, so the next
/// sweep over that ground finds the same place, classifies it the same way, and files it
/// again — which is what made removing one feel like it did nothing. A removal is recorded
/// here instead, keyed by the same identity parks are deduped on, and discovery skips
/// anything in the list before it is ever saved.
///
/// Nothing is added here automatically. The map's own classification is the best evidence
/// available and is usually right; this exists for the cases where the user knows better —
/// a city's undeveloped land parcel, a private lawn, a name that Apple happens to categorise as
/// a park. Every entry is reversible from Settings.
@Model
final class ExcludedPlace {
    /// `Park.identity(name:coordinate:)` for the place that was rejected.
    var identifier: String = ""
    /// Kept so the exclusion list can be read back and undone by a human.
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var excludedAt: Date = Date()

    init(identifier: String, name: String, latitude: Double, longitude: Double) {
        self.identifier = identifier
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.excludedAt = Date()
    }

    convenience init(park: Park) {
        self.init(
            identifier: park.identifier,
            name: park.name,
            latitude: park.latitude,
            longitude: park.longitude
        )
    }
}
