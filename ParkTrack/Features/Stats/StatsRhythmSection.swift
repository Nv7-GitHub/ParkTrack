import SwiftUI
import Charts

/// When the user actually goes out: a year-long day grid plus the weekday and seasonal
/// shape of their visits.
struct StatsRhythmSection: View {
    let parks: [Park]
    let signature: StatsSignature
    let cache: StatsCache

    @State private var focusedDay: StatsHeatmapDay?

    init(parks: [Park], signature: StatsSignature, cache: StatsCache) {
        self.parks = parks
        self.signature = signature
        self.cache = cache
    }

    private var weeks: [StatsHeatmapWeek] { cache.heatmapWeeks }
    private var weekdays: [StatsBucket] { cache.weekdayBuckets }
    private var months: [StatsBucket] { cache.monthBuckets }

    private var hasVisits: Bool { parks.contains(where: \.isVisited) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Visit rhythm", subtitle: "The last year, day by day")

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    if hasVisits {
                        StatsHeatmapGrid(weeks: weeks, focusedDay: $focusedDay)
                        heatmapFooter
                    } else {
                        StatsChartPlaceholder(
                            systemImage: "square.grid.3x3.fill",
                            message: "Your visit calendar lights up as soon as you log a trip."
                        )
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 18) {
                    StatsBucketChart(
                        title: "By day of week",
                        buckets: weekdays,
                        tint: Theme.chartColors[0],
                        emptyMessage: "No visits logged yet."
                    )
                    Divider().overlay(Theme.separator)
                    StatsBucketChart(
                        title: "By month of year",
                        buckets: months,
                        tint: Theme.chartColors[2],
                        emptyMessage: "No visits logged yet."
                    )
                }
            }
        }
    }

    private var heatmapFooter: some View {
        HStack(spacing: 10) {
            if let focusedDay {
                Text("\(Format.date(focusedDay.date)) · \(focusedDay.count) \(focusedDay.count == 1 ? "visit" : "visits")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Text("Tap a day for detail")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            Text("Less").font(.caption2).foregroundStyle(Theme.textSecondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(StatsHeatmapGrid.color(level: level))
                    .frame(width: 10, height: 10)
            }
            Text("More").font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heatmap scale, from no visits to many")
    }

}

/// GitHub-style year grid. Weeks are the columns and the accessibility unit, because a
/// year of individually focusable days would be miserable to swipe through.
struct StatsHeatmapGrid: View {
    let weeks: [StatsHeatmapWeek]
    @Binding var focusedDay: StatsHeatmapDay?

    private let cell: CGFloat = 13
    private let spacing: CGFloat = 3

    init(weeks: [StatsHeatmapWeek], focusedDay: Binding<StatsHeatmapDay?>) {
        self.weeks = weeks
        self._focusedDay = focusedDay
    }

    /// The busiest day in the window, which sets the colour scale.
    ///
    /// Computed once for the whole grid. As a computed property it was re-derived inside
    /// every one of the year's 364 cells — two array allocations and a full pass over the
    /// grid each time — so drawing the heatmap, or tapping any day in it, walked a hundred
    /// thousand elements before a single rectangle was filled.
    private var peak: Int {
        var highest = 1
        for week in weeks {
            for day in week.days where day.count > highest { highest = day.count }
        }
        return highest
    }

    var body: some View {
        let peak = self.peak

        return ScrollView(.horizontal, showsIndicators: false) {
            // Lazy: a year is fifty-odd columns of seven cells, and only a handful are on
            // screen at once.
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(weeks) { week in
                    VStack(spacing: spacing) {
                        ForEach(week.days) { day in
                            cellView(for: day, peak: peak)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Week of \(Format.date(week.start))")
                    .accessibilityValue("\(week.total) \(week.total == 1 ? "visit" : "visits")")
                }
            }
            .padding(.vertical, 2)
        }
        .defaultScrollAnchor(.trailing)
        .frame(height: cell * 7 + spacing * 6 + 4)
    }

    @ViewBuilder
    private func cellView(for day: StatsHeatmapDay, peak: Int) -> some View {
        let level = day.isInWindow ? StatsHeatmapGrid.level(count: day.count, peak: peak) : -1
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(level < 0 ? Color.clear : StatsHeatmapGrid.color(level: level))
            .frame(width: cell, height: cell)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        focusedDay?.date == day.date ? Theme.textPrimary : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard day.isInWindow else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    focusedDay = focusedDay?.date == day.date ? nil : day
                }
            }
            .accessibilityHidden(true)
    }

    /// Five buckets, so a single busy day doesn't wash the rest of the year out.
    static func level(count: Int, peak: Int) -> Int {
        guard count > 0 else { return 0 }
        let ratio = Double(count) / Double(max(peak, 1))
        switch ratio {
        case ..<0.25: return 1
        case ..<0.5: return 2
        case ..<0.75: return 3
        default: return 4
        }
    }

    static func color(level: Int) -> Color {
        switch level {
        case 1: return Theme.accent.opacity(0.28)
        case 2: return Theme.accent.opacity(0.5)
        case 3: return Theme.accent.opacity(0.74)
        case 4: return Theme.accent
        default: return Theme.separator
        }
    }
}
