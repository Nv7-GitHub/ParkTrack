import SwiftUI
import Charts

/// The collection growing over time: the range picker, the chart itself, a legend and a
/// one-line summary of what the range holds.
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
                        TimelineChart(data: data, monthsBack: monthsBack)
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

    private func monthLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }
}
