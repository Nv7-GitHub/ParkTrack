import SwiftUI

/// The superlatives — the answers people actually want to tell someone else.
struct StatsRecordsSection: View {
    let records: Records
    let streaks: Streaks
    /// How the ring anchor reads in a sentence — "you", "home", "your pin". The farthest
    /// park is measured from whatever the radius section is pointed at, and "your anchor"
    /// named the mechanism rather than the place.
    let anchorLabel: String

    init(records: Records, streaks: Streaks, anchorLabel: String) {
        self.records = records
        self.streaks = streaks
        self.anchorLabel = anchorLabel
    }

    private var hasAnything: Bool { records.totalVisits > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Records", subtitle: "Your personal bests")

            Card {
                if hasAnything {
                    VStack(spacing: 14) {
                        if let park = records.mostVisitedPark {
                            StatsRecordRow(
                                systemImage: "star.fill",
                                label: "Most visited",
                                value: park.name,
                                detail: "\(park.visitCount)×",
                                tint: Theme.sunset
                            )
                        }

                        if let park = records.farthestPark {
                            StatsRecordRow(
                                systemImage: "airplane",
                                label: "Farthest from \(anchorLabel)",
                                value: park.name,
                                detail: records.farthestDistanceMeters.map { Format.distance($0) },
                                tint: Theme.sky
                            )
                        }

                        if let day = records.biggestDayDate, records.biggestDayCount > 0 {
                            StatsRecordRow(
                                systemImage: "flame.fill",
                                label: "Biggest single day",
                                value: Format.parkCount(records.biggestDayCount),
                                detail: Format.date(day),
                                tint: Theme.sunset
                            )
                        }

                        StatsRecordRow(
                            systemImage: "hand.thumbsup.fill",
                            label: "Average rating",
                            value: records.averageRating.map { String(format: "%.1f / 5", $0) } ?? "Not rated yet",
                            detail: records.averageRating == nil ? nil : "across \(records.totalVisits) visits",
                            tint: Theme.fern
                        )

                        if let first = records.firstVisitDate {
                            StatsRecordRow(
                                systemImage: "flag.fill",
                                label: "First visit ever",
                                value: Format.date(first),
                                detail: Format.relative(first),
                                tint: Theme.moss
                            )
                        }

                        StatsRecordRow(
                            systemImage: "hourglass",
                            label: "Longest gap between visits",
                            value: streaks.longestGapDays > 0
                                ? "\(streaks.longestGapDays) \(streaks.longestGapDays == 1 ? "day" : "days")"
                                : "No gap yet",
                            detail: streaks.lastVisitDate.map { "last: \(Format.relative($0))" },
                            tint: Theme.bark
                        )
                    }
                } else {
                    StatsChartPlaceholder(
                        systemImage: "trophy",
                        message: "Log your first visit and your records start filling in."
                    )
                }
            }
        }
    }
}
