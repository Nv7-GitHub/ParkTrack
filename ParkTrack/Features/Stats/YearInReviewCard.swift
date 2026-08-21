import SwiftUI
import CoreLocation

/// The numbers the year-in-review poster shows.
///
/// Deliberately a value type of plain scalars and strings: it is rendered off-screen by
/// `ImageRenderer`, which walks the view outside the app's normal environment, so nothing
/// in the poster may reach back into SwiftData or the model context.
struct YearInReviewSummary: Equatable {

    /// How much of the neighbourhood around one saved place has been ticked off.
    ///
    /// Carries its own label and figures rather than a `SavedPlaceKind`, for the same
    /// reason as everything else here: the poster is drawn outside the app's environment
    /// and cannot ask `AppSettings` what the user renamed "work" to.
    struct PlaceCompletion: Equatable {
        let label: String
        let visited: Int
        let total: Int

        var fraction: Double { total == 0 ? 0 : Double(visited) / Double(total) }
    }

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
    /// One entry per saved place that exists and has parks near it, in Home/School/Work
    /// order. Unlike everything else on the poster this is the whole collection rather
    /// than the year's slice — "how much of my own neighbourhood have I done" doesn't
    /// reset in January.
    let placeCompletions: [PlaceCompletion]
    /// The ring these were measured at, so the poster can name it.
    let placeRadiusMiles: Double

    var isEmpty: Bool { parksDiscovered == 0 && visits == 0 }

    /// Builds the year's slice from the cached parks. Only first visits inside the year
    /// count as discoveries, so a park revisited every January isn't re-counted.
    static func make(
        parks: [Park],
        year: Int,
        streakWeeks: Int,
        displayName: String,
        placeCompletions: [PlaceCompletion] = [],
        placeRadiusMiles: Double = 2.5,
        calendar: Calendar = .current
    ) -> YearInReviewSummary {
        let discovered = StatsBreakdown.parksDiscovered(parks: parks, year: year, calendar: calendar)

        // Dated visits only. A backlog marked visited belongs in the collection, not in a
        // particular year's story. See `Visit.isUndated`.
        func visitsInYear(_ park: Park) -> [Visit] {
            park.datedVisits.filter { (visit: Visit) -> Bool in
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
            averageRating: ratingAverage,
            placeCompletions: placeCompletions,
            placeRadiusMiles: placeRadiusMiles
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

    /// Fixed, not adaptive. See `Theme.posterGradient`: the card on screen and the image it
    /// exports have to be the same picture, and only a background that does not depend on
    /// the drawing context can guarantee that.
    private let ink = Theme.posterInk

    init(summary: YearInReviewSummary) {
        self.summary = summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayName.isEmpty ? "My year in parks" : "\(summary.displayName)'s year in parks")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ink.opacity(0.9))
                Text(String(summary.year))
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(ink)
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
                    Text("Favorite this year")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ink.opacity(0.75))
                    Text(top)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text("\(summary.topParkVisits) \(summary.topParkVisits == 1 ? "visit" : "visits")")
                        .font(.caption)
                        .foregroundStyle(ink.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(ink.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
            }

            if !summary.placeCompletions.isEmpty {
                placeCompletions
            }

            HStack(spacing: 6) {
                Image(systemName: "tree.fill").font(.caption2)
                Text("ParkTrack").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if let first = summary.firstVisitOfYear {
                    Text("since \(Format.shortDate(first))").font(.caption2)
                }
            }
            .foregroundStyle(ink.opacity(0.8))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.posterGradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Year in review for \(String(summary.year))")
    }

    /// Home, school and work side by side, so the card answers "how much of where I
    /// actually live have I covered" alongside the year's totals.
    private var placeCompletions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Within \(Format.miles(summary.placeRadiusMiles))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ink.opacity(0.75))

            HStack(spacing: 10) {
                ForEach(summary.placeCompletions, id: \.label) { place in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Format.percent(place.fraction))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text(place.label)
                            .font(.caption2)
                            .foregroundStyle(ink.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("\(place.visited)/\(place.total)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(ink.opacity(0.7))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .background(ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(place.label), within \(Format.miles(summary.placeRadiusMiles))")
                    .accessibilityValue("\(place.visited) of \(place.total) parks visited, \(Format.percent(place.fraction))")
                }
            }
        }
    }

    private func posterStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(ink.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .task(id: RenderKey(summary: summary, scale: displayScale)) { await renderWhenIdle() }
    }

    /// What a rasterisation depends on, so the card re-renders when the figures or the
    /// screen's scale actually change and not merely when the view is rebuilt.
    private struct RenderKey: Equatable {
        let summary: YearInReviewSummary
        let scale: CGFloat
    }

    /// Rasterised ahead of time so the share sheet opens instantly — but not during the
    /// frame that brings the card on screen.
    ///
    /// `ImageRenderer` walks and draws the whole poster at screen scale, which is tens of
    /// milliseconds of main-thread work. Doing that from `onAppear` meant scrolling to the
    /// bottom of the Stats tab dropped frames every single time. Waiting until the scroll
    /// has settled costs nothing: the image is only needed once the user reaches for Share.
    private func renderWhenIdle() async {
        guard !summary.isEmpty else {
            rendered = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }

        let renderer = ImageRenderer(content: YearInReviewPoster(summary: summary).frame(width: 360))
        renderer.scale = displayScale
        guard let image = renderer.uiImage else { return }
        rendered = Image(uiImage: image)
    }
}
