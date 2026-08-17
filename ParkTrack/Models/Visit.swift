import Foundation
import SwiftData

/// One logged trip to a park. A park can have many.
@Model
final class Visit {
    var identifier: UUID = UUID()
    var date: Date = Date()
    /// Minutes spent, or nil when the user didn't say.
    var durationMinutes: Int?
    var notes: String = ""
    /// 1...5, or 0 for "not rated".
    var rating: Int = 0
    var companions: String = ""
    /// Free-text weather note captured at log time, when available.
    var weatherSummary: String?
    var createdAt: Date = Date()

    var park: Park?

    @Relationship(deleteRule: .cascade, inverse: \MediaItem.visit)
    var media: [MediaItem]? = []

    init(
        date: Date = Date(),
        durationMinutes: Int? = nil,
        notes: String = "",
        rating: Int = 0,
        companions: String = "",
        park: Park? = nil
    ) {
        self.identifier = UUID()
        self.date = date
        self.durationMinutes = durationMinutes
        self.notes = notes
        self.rating = rating
        self.companions = companions
        self.park = park
        self.createdAt = Date()
    }
}

extension Visit {
    var sortedMedia: [MediaItem] {
        (media ?? []).sorted { $0.createdAt < $1.createdAt }
    }
    var hasMedia: Bool { !(media ?? []).isEmpty }
}
