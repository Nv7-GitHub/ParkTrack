import SwiftUI
import Charts

/// One rhythm chart: visits per weekday, or per month of the year.
///
/// Split out from `StatsRhythmSection` so the picture can be built from a bare list of
/// buckets, which is what makes it renderable on its own, and so checkable.
struct StatsBucketChart: View {
    let title: String
    let buckets: [StatsBucket]
    let tint: Color
    let emptyMessage: String

    init(title: String, buckets: [StatsBucket], tint: Color, emptyMessage: String) {
        self.title = title
        self.buckets = buckets
        self.tint = tint
        self.emptyMessage = emptyMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            let peak = buckets.map(\.count).max() ?? 0
            if peak == 0 {
                StatsChartPlaceholder(systemImage: "chart.bar", message: emptyMessage)
            } else {
                // A plottable *category* on x, not the bucket's numeric index. `.ratio`
                // widths are a fraction of a discrete scale's step, and a continuous x
                // scale has no step to take a fraction of — so every bar came out with no
                // width and both charts drew an empty plot with correct axes.
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Period", bucket.fullLabel),
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
                // The domain fixes the order: without it the categories sort themselves
                // alphabetically, which puts Friday before Monday and April before January.
                .chartXScale(domain: buckets.map(\.fullLabel))
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
                    // Labelled by the full name so the ticks line up with the bars, drawn
                    // as the short one so twelve months fit across a phone.
                    AxisMarks(values: buckets.map(\.fullLabel)) { value in
                        AxisValueLabel {
                            if let raw = value.as(String.self),
                               let match = buckets.first(where: { $0.fullLabel == raw }) {
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
