import SwiftUI
import Charts

/// The collection growing over time: a cumulative area curve with the month-by-month
/// additions underneath it.
///
/// The two series live on one plot but on wildly different scales, so the bars are drawn
/// against a scaled-down copy of the cumulative axis and given their own trailing axis
/// with the real counts. That keeps the shape of both readable without a second chart.
struct StatsTimelineSection: View {
    let parks: [Park]
    let signature: StatsSignature
    let cache: StatsCache
    @State private var pointsCache = DerivedCache<[TimelinePoint]>()
    @State private var visitPointsCache = DerivedCache<[TimelinePoint]>()
    @State private var monthsCache = DerivedCache<Int>()

    enum Range: String, CaseIterable, Identifiable {
        case sixMonths, year, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sixMonths: return "6M"
            case .year: return "1Y"
            case .all: return "All"
            }
        }

        var accessibilityTitle: String {
            switch self {
            case .sixMonths: return "Six months"
            case .year: return "One year"
            case .all: return "All time"
            }
        }
    }

    @State private var range: Range = .year

    init(parks: [Park], signature: StatsSignature, cache: StatsCache) {
        self.parks = parks
        self.signature = signature
        self.cache = cache
    }

    /// "All" is bounded by the first visit on record so the axis never stretches over
    /// empty years, and capped so a very old first visit can't produce a useless chart.
    private var monthsBack: Int {
        switch range {
        case .sixMonths: return 6
        case .year: return 12
        case .all:
            // Finding the earliest first visit faults every park's relationship, and both
            // series ask for the range, so the answer is kept rather than re-derived twice
            // on every body evaluation.
            return monthsCache.value(for: signature) {
                guard let first = parks.compactMap(\.firstVisitDate).min() else { return 12 }
                let months = Calendar.current.dateComponents([.month], from: first, to: Date()).month ?? 12
                return min(max(months + 1, 6), 120)
            }
        }
    }

    private var points: [TimelinePoint] {
        // The shared answer covers the range the screen warmed; another range is the user
        // asking for something new, and that one computation is worth doing on the spot.
        if cache.timelineMonths == monthsBack, !cache.monthlyTimeline.isEmpty {
            return cache.monthlyTimeline
        }
        return pointsCache.value(for: signature.adding(Double(monthsBack))) {
            StatsEngine.monthlyTimeline(parks: parks, monthsBack: monthsBack)
        }
    }

    private var visitPoints: [TimelinePoint] {
        if cache.timelineMonths == monthsBack, !cache.visitTimeline.isEmpty {
            return cache.visitTimeline
        }
        return visitPointsCache.value(for: signature.adding(Double(monthsBack))) {
            StatsEngine.visitTimeline(parks: parks, monthsBack: monthsBack)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Parks over time", subtitle: "New parks each month against your running total")

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Time range")
                    .accessibilityValue(range.accessibilityTitle)

                    let data = points
                    if data.count < 2 || data.last?.cumulative == 0 {
                        StatsChartPlaceholder(
                            systemImage: "chart.line.uptrend.xyaxis",
                            message: "Log visits to a few parks and your collection curve appears here."
                        )
                    } else {
                        chart(for: data)
                            .frame(height: 210)

                        HStack(spacing: 14) {
                            StatsLegendSwatch(color: Theme.chartColors[0], label: "Total parks")
                            StatsLegendSwatch(color: Theme.chartColors[1], label: "New that month")
                            Spacer(minLength: 0)
                        }

                        summary(for: data)
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: range)
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(for data: [TimelinePoint]) -> some View {
        let ceiling = max(data.map(\.cumulative).max() ?? 1, 1)
        let barPeak = max(data.map(\.count).max() ?? 1, 1)
        // Bars occupy at most ~55% of the plot so they never swamp the curve.
        let barScale = Double(ceiling) * 0.55 / Double(barPeak)

        let step = xStride(for: data.count)
        // Every mark plots at the middle of its month. A `BarMark` given a month unit fills
        // the whole month and so sits half a month to the right of the month's own date —
        // which is where the curve and the axis labels were, so at 6M, where every month is
        // labelled, each bar stood visibly to the right of its label and its own curve point.
        Chart {
            ForEach(data) { point in
                AreaMark(
                    x: .value("Month", midMonth(point.date)),
                    y: .value("Total parks", Double(point.cumulative))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.chartColors[0].opacity(0.45), Theme.chartColors[0].opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .accessibilityLabel(monthLabel(point.date))
                .accessibilityValue("\(point.cumulative) parks in total")
            }

            ForEach(data) { point in
                LineMark(
                    x: .value("Month", midMonth(point.date)),
                    y: .value("Total parks", Double(point.cumulative))
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Theme.chartColors[0])
                .accessibilityHidden(true)
            }

            ForEach(data) { point in
                BarMark(
                    x: .value("Month", point.date, unit: .month),
                    y: .value("New parks", Double(point.count) * barScale),
                    width: .ratio(0.42)
                )
                .cornerRadius(3)
                .foregroundStyle(Theme.chartColors[1].opacity(0.85))
                .accessibilityLabel(monthLabel(point.date))
                .accessibilityValue("\(point.count) new \(point.count == 1 ? "park" : "parks")")
            }
        }
        .chartYScale(domain: 0...(Double(ceiling) * 1.1))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.separator)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text("\(Int(raw.rounded()))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            AxisMarks(position: .trailing, values: barAxisValues(peak: barPeak, scale: barScale)) { value in
                AxisValueLabel {
                    if let raw = value.as(Double.self), barScale > 0 {
                        Text("\(Int((raw / barScale).rounded()))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.chartColors[1])
                    }
                }
            }
        }
        .chartXAxis {
            // Two passes: the grid lines belong on the month boundaries, and the labels
            // belong under the middle of the month they name, which is where its bar is.
            AxisMarks(values: .stride(by: .month, count: step)) { _ in
                AxisGridLine().foregroundStyle(Theme.separator.opacity(0.5))
            }
            AxisMarks(values: labelDates(for: data, step: step)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date, usesInitials: usesInitials(data: data, step: step)))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(Theme.background.opacity(0.35))
        }
        .accessibilityLabel("Parks over time")
        .accessibilityHint("Cumulative parks visited, with new parks per month")
    }

    private func summary(for data: [TimelinePoint]) -> some View {
        let added = data.reduce(0) { $0 + $1.count }
        let visits = visitPoints.reduce(0) { $0 + $1.count }
        let best = data.max { $0.count < $1.count }

        return HStack(spacing: 10) {
            Pill(text: "\(added) new", systemImage: "plus.circle.fill", tint: Theme.fern)
            Pill(text: "\(visits) visits", systemImage: "figure.walk", tint: Theme.sky)
            if let best, best.count > 0 {
                Pill(text: "Best: \(monthLabel(best.date))", systemImage: "trophy.fill", tint: Theme.sunset)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(added) new parks and \(visits) visits in this range"
        )
    }

    // MARK: Helpers

    /// Tick positions for the trailing (bar) axis, expressed in the plot's own scale.
    private func barAxisValues(peak: Int, scale: Double) -> [Double] {
        guard peak > 0, scale > 0 else { return [] }
        let step = max(1, Int((Double(peak) / 3).rounded(.up)))
        return stride(from: 0, through: peak, by: step).map { Double($0) * scale }
    }

    private func xStride(for count: Int) -> Int {
        switch count {
        case ..<15: return 1
        case ..<27: return 4
        case ..<50: return 6
        default: return 12
        }
    }

    /// The middle of `date`'s month — where a month-wide bar actually sits.
    private func midMonth(_ date: Date) -> Date {
        guard let month = Calendar.current.dateInterval(of: .month, for: date) else { return date }
        return month.start.addingTimeInterval(month.duration / 2)
    }

    /// The months the axis names, at the position their bars occupy.
    private func labelDates(for data: [TimelinePoint], step: Int) -> [Date] {
        Swift.stride(from: 0, to: data.count, by: step).map { midMonth(data[$0].date) }
    }

    /// Initials once every month is named and there are enough of them to crowd.
    ///
    /// A year is twelve labels across a phone, which is exactly what the rhythm charts
    /// draw as single letters. Below that there is room for the abbreviated name, and it
    /// is worth having: a strided axis labelling every fourth month as "S N J M M J" would
    /// be unreadable, and worse than useless because it looks like it should mean something.
    private func usesInitials(data: [TimelinePoint], step: Int) -> Bool {
        step == 1 && data.count > 8
    }

    /// Month names, with the year called out at each January so a multi-year range stays
    /// placed.
    private func axisLabel(_ date: Date, usesInitials: Bool) -> String {
        if usesInitials { return date.formatted(.dateTime.month(.narrow)) }
        let month = date.formatted(.dateTime.month(.abbreviated))
        guard monthsBack > 14 else { return month }
        let isJanuary = Calendar.current.component(.month, from: date) == 1
        return isJanuary ? date.formatted(.dateTime.month(.abbreviated).year(.twoDigits)) : month
    }

    private func monthLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }
}
