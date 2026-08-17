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

    /// True when the user only said "I've been here", without saying when.
    ///
    /// Marking a park visited and logging a visit are different claims. The first is about
    /// the park — it belongs in the collection, in the completion rings, in the counts. The
    /// second is about a day, and only that one can honestly appear on a timeline, a streak
    /// or a heatmap. Recording a backlog as a hundred visits dated today made every
    /// date-shaped figure in the app describe the afternoon the app was installed.
    ///
    /// `date` still holds when the row was created, so lists have something to order by; it
    /// simply is not a claim about when the user was there. Defaults to false so every visit
    /// already in the store keeps its date, which is what the fix-up screen is for.
    var isUndated: Bool = false

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
    /// A visit recorded without a day: "I've been here", nothing more.
    ///
    /// `date` is the moment the row was made, purely so lists have something to order by.
    static func undated(park: Park? = nil) -> Visit {
        let visit = Visit(park: park)
        visit.isUndated = true
        return visit
    }

    /// The day this visit happened, when the user actually said.
    var knownDate: Date? { isUndated ? nil : date }

    /// True when nothing was recorded beyond the fact of the visit — which is what a
    /// "mark visited" row looks like, and what the fix-up screen offers to correct.
    var hasNoDetails: Bool {
        rating == 0
            && durationMinutes == nil
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && companions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (weatherSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (media ?? []).isEmpty
    }

    var sortedMedia: [MediaItem] {
        (media ?? []).sorted { $0.createdAt < $1.createdAt }
    }
    var hasMedia: Bool { !(media ?? []).isEmpty }
}

extension Array where Element == Visit {
    /// Newest first, with the undated ones after everything that has a date.
    ///
    /// Sorting on `date` alone files a park merely marked visited by the moment it was
    /// tapped, which is not a claim about recency at all — so it would sit at the very top
    /// of "recently visited" on the strength of a timestamp that means nothing. Among
    /// themselves the undated ones fall back to when they were recorded, which is the only
    /// ordering the store actually knows.
    func orderedByRecency() -> [Visit] {
        filter { !$0.isUndated }.sorted { $0.date > $1.date }
            + filter(\.isUndated).sorted { $0.createdAt > $1.createdAt }
    }
}
