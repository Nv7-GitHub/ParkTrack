import SwiftUI
import Charts

/// When the user actually goes out: a year-long day grid plus the weekday and seasonal
/// shape of their visits.
struct StatsRhythmSection: View {
    let parks: [Park]

    @State private var focusedDay: StatsHeatmapDay?

    init(parks: [Park]) {
        self.parks = parks
    }

    private var weeks: [StatsHeatmapWeek] { StatsBreakdown.heatmapWeeks(parks: parks) }
    private var weekdays: [StatsBucket] { StatsBreakdown.byWeekday(parks: parks) }
    private var months: [StatsBucket] { StatsBreakdown.byMonthOfYear(parks: parks) }

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
                    bucketChart(
                        title: "By day of week",
                        buckets: weekdays,
                        tint: Theme.chartColors[0],
                        emptyMessage: "No visits logged yet."
                    )
                    Divider().overlay(Theme.separator)
                    bucketChart(
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

    @ViewBuilder
    private func bucketChart(
        title: String,
        buckets: [StatsBucket],
        tint: Color,
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            let peak = buckets.map(\.count).max() ?? 0
            if peak == 0 {
                StatsChartPlaceholder(systemImage: "chart.bar", message: emptyMessage)
            } else {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Period", Double(bucket.id)),
                        y: .value("Visits", Double(bucket.count)),
                        width: .ratio(0.6)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .accessibilityLabel(bucket.fullLabel)
                    .accessibilityValue("\(bucket.count) \(bucket.count == 1 ? "visit" : "visits")")
                }
                .chartXScale(domain: -0.6...(Double(buckets.count) - 0.4))
                .chartYScale(domain: 0...(Double(peak) * 1.15))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Theme.separator)
                        AxisValueLabel {
                            if let raw = value.as(Double.self) {
                                Text("\(Int(raw.rounded()))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: buckets.map { Double($0.id) }) { value in
                        AxisValueLabel {
                            if let raw = value.as(Double.self),
                               let match = buckets.first(where: { $0.id == Int(raw.rounded()) }) {
                                Text(match.shortLabel)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .frame(height: 130)
                .accessibilityLabel(title)
            }
        }
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

    private var peak: Int {
        max(weeks.flatMap { $0.days }.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(weeks) { week in
                    VStack(spacing: spacing) {
                        ForEach(week.days) { day in
                            cellView(for: day)
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
    private func cellView(for day: StatsHeatmapDay) -> some View {
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
