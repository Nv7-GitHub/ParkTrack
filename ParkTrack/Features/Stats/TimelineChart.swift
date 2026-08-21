import SwiftUI
import Charts

/// The "Parks over time" plot itself: a cumulative area curve with the month-by-month
/// additions underneath it.
///
/// Split out from `StatsTimelineSection` so the picture can be built from a bare list of
/// points — which is what makes it renderable on its own, and so checkable.
///
/// The two series live on one plot but on wildly different scales, so the bars are drawn
/// against a scaled-down copy of the cumulative axis and given their own trailing axis
/// with the real counts. That keeps the shape of both readable without a second chart.
struct TimelineChart: View {
    let data: [TimelinePoint]
    /// How long a span the axis covers, which decides whether a January is worth naming.
    let monthsBack: Int

    init(data: [TimelinePoint], monthsBack: Int) {
        self.data = data
        self.monthsBack = monthsBack
    }

    var body: some View {
        let ceiling = max(data.map(\.cumulative).max() ?? 1, 1)
        let barPeak = max(data.map(\.count).max() ?? 1, 1)
        // Bars occupy at most ~55% of the plot so they never swamp the curve.
        let barScale = Double(ceiling) * 0.55 / Double(barPeak)

        let step = xStride(for: data.count)
        let names = axisNames(for: data, step: step)
        // Everything is plotted at the middle of its month, which is where a `BarMark` given
        // a month unit already sits. See `AxisValueLabel(anchor:)` below for why the axis
        // did not agree.
        Chart {
            curve
            bars(scale: barScale)
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
            // No vertical grid lines. A month boundary and the middle of a month are half a
            // month apart, and once the labels sit over their bars a line drawn anywhere
            // else only invites the eye to read a bar against the wrong one. The horizontal
            // grid does the work of reading a height off the axis.
            //
            // `anchor: .top` is the whole reason the bars looked misaligned. An
            // `AxisValueLabel` built from a custom view — rather than from a format style —
            // hangs that view off the *leading* edge of its tick by default, so every month
            // name sat about half its own width to the right of the bar it named.
            AxisMarks(values: Array(names.keys).sorted()) { value in
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self), let name = name(at: date, in: names) {
                        Text(name)
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


    /// The cumulative total, as a filled area with its own line on top.
    @ChartContentBuilder
    private var curve: some ChartContent {
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
    }

    /// New parks that month, drawn against a scaled-down copy of the cumulative axis.
    @ChartContentBuilder
    private func bars(scale: Double) -> some ChartContent {
        ForEach(data) { point in
            BarMark(
                x: .value("Month", point.date, unit: .month),
                y: .value("New parks", Double(point.count) * scale),
                width: .ratio(0.42)
            )
            .cornerRadius(3)
            .foregroundStyle(Theme.chartColors[1].opacity(0.85))
            .accessibilityLabel(monthLabel(point.date))
            .accessibilityValue("\(point.count) new \(point.count == 1 ? "park" : "parks")")
        }
    }

    private func monthLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }

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

    /// The middle of `date`'s month, which is where a month-binned bar is drawn and so
    /// where the curve and the axis labels have to be too.
    private func midMonth(_ date: Date) -> Date {
        guard let month = Calendar.current.dateInterval(of: .month, for: date) else { return date }
        return month.start.addingTimeInterval(month.duration / 2)
    }

    /// What the axis says and where, keyed by the position each label sits at.
    ///
    /// Started half a stride in rather than at the first month, so a centred label always
    /// has half a stride of plot to sit in. Naming the very first month of a two-year range
    /// put "Jan 25" against the left edge with nowhere to go, and it came out as "…".
    ///
    /// The year is called out whenever it changes rather than at each January, because a
    /// strided axis need never land on one: two years of months labelled every fourth came
    /// out as "Nov Mar Jul Nov Mar Jul", which names the months and hides which year is
    /// which.
    private func axisNames(for data: [TimelinePoint], step: Int) -> [Date: String] {
        let calendar = Calendar.current
        let initials = usesInitials(data: data, step: step)
        var names: [Date: String] = [:]
        var lastYear: Int?

        for index in Swift.stride(from: step / 2, to: data.count, by: step) {
            let date = data[index].date
            let year = calendar.component(.year, from: date)
            let showsYear = !initials && monthsBack > 14 && year != lastYear
            names[midMonth(date)] = monthName(date, initial: initials, withYear: showsYear)
            lastYear = year
        }
        return names
    }

    /// Ticks come back as the dates they were given, but a nearest match costs nothing and
    /// means a rounding difference could never blank a label out.
    private func name(at date: Date, in names: [Date: String]) -> String? {
        if let exact = names[date] { return exact }
        return names
            .min { abs($0.key.timeIntervalSince(date)) < abs($1.key.timeIntervalSince(date)) }?
            .value
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

    private func monthName(_ date: Date, initial: Bool, withYear: Bool) -> String {
        if initial { return date.formatted(.dateTime.month(.narrow)) }
        if withYear { return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits)) }
        return date.formatted(.dateTime.month(.abbreviated))
    }
}
