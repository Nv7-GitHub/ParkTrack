import SwiftUI
import MapKit
import CoreLocation

/// Where the radius rings are measured from.
///
/// The anchor is a user choice rather than a fixed point because "how much have I
/// explored" means something different depending on whether you're standing somewhere
/// new, sitting at home, or planning a trip around a spot you dropped on the map.
enum StatsAnchor: String, CaseIterable, Identifiable {
    case currentLocation
    case home
    case pin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentLocation: return "Current"
        case .home: return "Home"
        case .pin: return "Pin"
        }
    }

    /// How the anchor reads inside a sentence, as opposed to on a segmented control.
    var sheetLabel: String {
        switch self {
        case .currentLocation: return "you"
        case .home: return "home"
        case .pin: return "your pin"
        }
    }

    var systemImage: String {
        switch self {
        case .currentLocation: return "location.fill"
        case .home: return "house.fill"
        case .pin: return "mappin"
        }
    }

    var unavailableMessage: String {
        switch self {
        case .currentLocation: return "Allow location access to measure rings from where you are."
        case .home: return "Set a home location in Settings to measure rings from it."
        case .pin: return "Drop a pin anywhere on the map to measure rings from it."
        }
    }
}

// MARK: - Derived buckets

/// One column of a bar chart. `id` doubles as the plotted x position, so the buckets are
/// drawn in the user's own week order and duplicate short symbols (two "S" days, three
/// "J" months) can't collapse into a single bar.
struct StatsBucket: Identifiable, Equatable {
    let id: Int
    let shortLabel: String
    let fullLabel: String
    let count: Int
}

/// A single cell of the calendar heatmap.
struct StatsHeatmapDay: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let count: Int
    /// Days that pad the first and last week out to seven are drawn blank.
    let isInWindow: Bool
}

/// A column of the heatmap. Weeks, not days, are the VoiceOver unit — a year of
/// individually focusable days would be unusable.
struct StatsHeatmapWeek: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let days: [StatsHeatmapDay]

    var total: Int { days.reduce(0) { $0 + $1.count } }
}

/// Aggregations the stats screens need that aren't part of the shared `StatsEngine`
/// contract: rhythm buckets and the heatmap's week/day grid geometry.
enum StatsBreakdown {

    /// Visits per weekday, ordered from the user's own first day of the week.
    static func byWeekday(parks: [Park], calendar: Calendar = .current) -> [StatsBucket] {
        var counts = [Int](repeating: 0, count: 7)
        for date in visitDates(parks) {
            let index = calendar.component(.weekday, from: date) - 1
            guard counts.indices.contains(index) else { continue }
            counts[index] += 1
        }

        let short = calendar.veryShortWeekdaySymbols
        let full = calendar.weekdaySymbols
        return (0..<7).map { offset in
            let index = (calendar.firstWeekday - 1 + offset) % 7
            return StatsBucket(
                id: offset,
                shortLabel: short.indices.contains(index) ? short[index] : "\(index)",
                fullLabel: full.indices.contains(index) ? full[index] : "\(index)",
                count: counts[index]
            )
        }
    }

    /// Visits per month of the year, aggregated across every year on record.
    static func byMonthOfYear(parks: [Park], calendar: Calendar = .current) -> [StatsBucket] {
        var counts = [Int](repeating: 0, count: 12)
        for date in visitDates(parks) {
            let index = calendar.component(.month, from: date) - 1
            guard counts.indices.contains(index) else { continue }
            counts[index] += 1
        }

        let short = calendar.veryShortMonthSymbols
        let full = calendar.monthSymbols
        return (0..<12).map { index in
            StatsBucket(
                id: index,
                shortLabel: short.indices.contains(index) ? short[index] : "\(index + 1)",
                fullLabel: full.indices.contains(index) ? full[index] : "\(index + 1)",
                count: counts[index]
            )
        }
    }

    /// The heatmap grid, padded at both ends so every column holds exactly seven rows
    /// and the first row is always the user's first day of the week.
    static func heatmapWeeks(
        parks: [Park],
        daysBack: Int = 364,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [StatsHeatmapWeek] {
        guard daysBack > 0 else { return [] }

        let counts = StatsEngine.calendarHeatmap(parks: parks, daysBack: daysBack)
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(daysBack - 1), to: today) else { return [] }

        let gridStart = calendar.startOfDay(
            for: calendar.dateInterval(of: .weekOfYear, for: windowStart)?.start ?? windowStart
        )

        var weeks: [StatsHeatmapWeek] = []
        var cursor = gridStart
        while cursor <= today {
            var days: [StatsHeatmapDay] = []
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: cursor) else { continue }
                let inWindow = day >= windowStart && day <= today
                days.append(StatsHeatmapDay(date: day, count: inWindow ? (counts[day] ?? 0) : 0, isInWindow: inWindow))
            }
            weeks.append(StatsHeatmapWeek(start: cursor, days: days))
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return weeks
    }

    /// Visits logged inside a calendar year, used by the year-in-review card.
    static func visitCount(parks: [Park], year: Int, calendar: Calendar = .current) -> Int {
        visitDates(parks).filter { calendar.component(.year, from: $0) == year }.count
    }

    /// Parks whose *first* visit landed in the given year — the year's genuine discoveries.
    static func parksDiscovered(parks: [Park], year: Int, calendar: Calendar = .current) -> [Park] {
        parks.filter { park in
            guard let first = park.firstVisitDate else { return false }
            return calendar.component(.year, from: first) == year
        }
    }

    private static func visitDates(_ parks: [Park]) -> [Date] {
        parks.flatMap { ($0.visits ?? []).map(\.date) }
    }
}

// MARK: - Shared rows and sheets

/// One superlative: an icon, what it measures, and the answer.
struct StatsRecordRow: View {
    let systemImage: String
    let label: String
    let value: String
    var detail: String?
    var tint: Color = Theme.accent

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(detail.map { "\(value), \($0)" } ?? value)
    }
}

/// The parks still to be ticked off inside a ring or a region.
struct StatsRemainingParksSheet: View {
    let title: String
    let subtitle: String
    let parks: [Park]
    var origin: CLLocation?

    @Environment(\.dismiss) private var dismiss

    init(title: String, subtitle: String, parks: [Park], origin: CLLocation? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.parks = parks
        self.origin = origin
    }

    var body: some View {
        NavigationStack {
            Group {
                if parks.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.seal.fill",
                        title: "All done here",
                        message: "You've visited every park \(subtitle.isEmpty ? "in this area" : subtitle)."
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List(parks, id: \.identifier) { park in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(park.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                if let region = park.regionLabel {
                                    Text(region)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if let origin {
                                Text(Format.distance(park.distance(from: origin)))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            if park.isWishlisted {
                                Image(systemName: "heart.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.sunset)
                                    .accessibilityLabel("Wishlisted")
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Lets the user measure completion around any point on earth without typing coordinates.
struct StatsPinPickerSheet: View {
    var initialCoordinate: CLLocationCoordinate2D?
    let onSelect: (CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?

    init(initialCoordinate: CLLocationCoordinate2D?, onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        self.initialCoordinate = initialCoordinate
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera)
                    .mapStyle(.standard(elevation: .flat))
                    .onMapCameraChange(frequency: .continuous) { context in
                        center = context.region.center
                    }
                    .accessibilityLabel("Map. Pan to place the pin.")

                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.sunset)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Drop a pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use pin") {
                        if let center { onSelect(center) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(center == nil)
                }
            }
            .onAppear {
                guard let initialCoordinate else { return }
                center = initialCoordinate
                camera = .region(
                    MKCoordinateRegion(
                        center: initialCoordinate,
                        latitudinalMeters: 40_000,
                        longitudinalMeters: 40_000
                    )
                )
            }
        }
    }
}

/// Placeholder used inside cards when a chart has nothing meaningful to draw. Charts with
/// no data render a broken axis, so they're replaced wholesale rather than left empty.
struct StatsChartPlaceholder: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .accessibilityElement(children: .combine)
    }
}

/// Legend swatch shared by the charts, so every series is named without relying on
/// Swift Charts' default legend styling.
struct StatsLegendSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityHidden(true)
    }
}
