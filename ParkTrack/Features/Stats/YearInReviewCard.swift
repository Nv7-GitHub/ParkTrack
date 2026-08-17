import SwiftUI
import CoreLocation

/// The numbers the year-in-review poster shows.
///
/// Deliberately a value type of plain scalars and strings: it is rendered off-screen by
/// `ImageRenderer`, which walks the view outside the app's normal environment, so nothing
/// in the poster may reach back into SwiftData or the model context.
struct YearInReviewSummary: Equatable {
    let year: Int
    let displayName: String
    let parksDiscovered: Int
    let visits: Int
    let cities: Int
    let states: Int
    let streakWeeks: Int
    let topParkName: String?
    let topParkVisits: Int
    let firstVisitOfYear: Date?
    let averageRating: Double?

    var isEmpty: Bool { parksDiscovered == 0 && visits == 0 }

    /// Builds the year's slice from the cached parks. Only first visits inside the year
    /// count as discoveries, so a park revisited every January isn't re-counted.
    static func make(
        parks: [Park],
        year: Int,
        streakWeeks: Int,
        displayName: String,
        calendar: Calendar = .current
    ) -> YearInReviewSummary {
        let discovered = StatsBreakdown.parksDiscovered(parks: parks, year: year, calendar: calendar)

        func visitsInYear(_ park: Park) -> [Visit] {
            let all: [Visit] = park.visits ?? []
            return all.filter { (visit: Visit) -> Bool in
                calendar.component(.year, from: visit.date) == year
            }
        }

        var visitsThisYear: [Visit] = []
        var ranked: [(park: Park, count: Int)] = []
        for park in parks {
            let matches = visitsInYear(park)
            guard !matches.isEmpty else { continue }
            visitsThisYear.append(contentsOf: matches)
            ranked.append((park: park, count: matches.count))
        }
        ranked.sort { (a: (park: Park, count: Int), b: (park: Park, count: Int)) -> Bool in
            a.count == b.count ? a.park.name < b.park.name : a.count > b.count
        }

        var ratings: [Double] = []
        for visit in visitsThisYear where visit.rating > 0 {
            ratings.append(Double(visit.rating))
        }

        let cityNames: [String] = discovered.compactMap { nonEmpty($0.locality) }
        let stateNames: [String] = discovered.compactMap { nonEmpty($0.administrativeArea) }
        let visitDates: [Date] = visitsThisYear.map(\.date)
        let ratingAverage: Double? = ratings.isEmpty ? nil : ratings.reduce(0, +) / Double(ratings.count)

        return YearInReviewSummary(
            year: year,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            parksDiscovered: discovered.count,
            visits: visitsThisYear.count,
            cities: Set(cityNames).count,
            states: Set(stateNames).count,
            streakWeeks: streakWeeks,
            topParkName: ranked.first?.park.name,
            topParkVisits: ranked.first?.count ?? 0,
            firstVisitOfYear: visitDates.min(),
            averageRating: ratingAverage
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The shareable poster itself, kept separate from the card so `ImageRenderer` can draw
/// exactly what the user sees at a fixed width.
struct YearInReviewPoster: View {
    let summary: YearInReviewSummary

    init(summary: YearInReviewSummary) {
        self.summary = summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayName.isEmpty ? "My year in parks" : "\(summary.displayName)'s year in parks")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(String(summary.year))
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 10) {
                posterStat(String(summary.parksDiscovered), "new parks")
                posterStat(String(summary.visits), "visits")
                posterStat(String(summary.cities), summary.cities == 1 ? "city" : "cities")
            }

            HStack(spacing: 10) {
                posterStat(String(summary.states), summary.states == 1 ? "state" : "states")
                posterStat("\(summary.streakWeeks)", summary.streakWeeks == 1 ? "week streak" : "week streak")
                posterStat(
                    summary.averageRating.map { String(format: "%.1f", $0) } ?? "—",
                    "avg rating"
                )
            }

            if let top = summary.topParkName {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Favourite this year")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(top)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text("\(summary.topParkVisits) \(summary.topParkVisits == 1 ? "visit" : "visits")")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
            }

            HStack(spacing: 6) {
                Image(systemName: "tree.fill").font(.caption2)
                Text("ParkTrack").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if let first = summary.firstVisitOfYear {
                    Text("since \(Format.shortDate(first))").font(.caption2)
                }
            }
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Year in review for \(String(summary.year))")
    }

    private func posterStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// The poster plus the affordance to share it as an image.
struct YearInReviewCard: View {
    let summary: YearInReviewSummary

    @Environment(\.displayScale) private var displayScale
    @State private var rendered: Image?

    init(summary: YearInReviewSummary) {
        self.summary = summary
    }

    private var shareTitle: String {
        summary.displayName.isEmpty
        ? "My \(summary.year) in parks"
        : "\(summary.displayName)'s \(summary.year) in parks"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Year in review", subtitle: "A card built for sharing")

            YearInReviewPoster(summary: summary)
                .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 6)

            if summary.isEmpty {
                Text("Log a visit this year and the card fills in.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else if let rendered {
                ShareLink(
                    item: rendered,
                    preview: SharePreview(shareTitle, image: rendered)
                ) {
                    Label("Share this card", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .accessibilityHint("Shares the year in review card as an image")
            }
        }
        .onAppear { render() }
        .onChange(of: summary) { render() }
        .onChange(of: displayScale) { render() }
    }

    /// Rasterised eagerly rather than on tap so the share sheet opens instantly.
    @MainActor
    private func render() {
        guard !summary.isEmpty else {
            rendered = nil
            return
        }
        let renderer = ImageRenderer(content: YearInReviewPoster(summary: summary).frame(width: 360))
        renderer.scale = displayScale
        guard let image = renderer.uiImage else { return }
        rendered = Image(uiImage: image)
    }
}
