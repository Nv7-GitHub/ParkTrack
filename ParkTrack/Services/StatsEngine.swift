import Foundation
import CoreLocation

/// How much of a radius ring around a point has been visited.
struct RadiusCompletion: Identifiable {
    var id: Double { radiusMiles }
    let radiusMiles: Double
    let visited: Int
    let total: Int
    let fraction: Double
    let remaining: [Park]
    /// The visited half, so a ring's detail can show progress rather than only a to-do list.
    var visitedParks: [Park] = []
}

/// How much of a named area (city, county, state) has been visited.
struct RegionCompletion: Identifiable {
    var id: String { name }
    let name: String
    let visited: Int
    // Re-read from the store once an index finishes, so a screen already on display updates.
    var total: Int
    var fraction: Double
    let remaining: [Park]
    /// The visited half of the same group, so a detail view can show both sides.
    var visitedParks: [Park] = []
    /// True when `total` came from a completed sweep of this place rather than from however
    /// many of its parks happen to have been found so far.
    var isIndexed: Bool = false
    /// True when the indexed total is a floor: the place was too large to sweep at full
    /// density, so there are probably more parks in it than this.
    var isApproximate: Bool = false
    var indexedAt: Date?
    /// Key shared with friends, so a head-to-head counts both sides against the same total.
    var identifier: String = ""
    var kind: RegionKind = .city
}

/// One bucket on a chart: the count in that period plus the running total up to it.
struct TimelinePoint: Identifiable {
    var id: Date { date }
    let date: Date
    let count: Int
    let cumulative: Int
}

struct Streaks {
    let currentWeeks: Int
    let longestWeeks: Int
    let longestGapDays: Int
    let lastVisitDate: Date?
}

struct Records {
    let totalParks: Int
    let totalVisits: Int
    let parksThisMonth: Int
    let parksThisYear: Int
    let distinctCities: Int
    let distinctStates: Int
    let mostVisitedPark: Park?
    let farthestPark: Park?
    let farthestDistanceMeters: Double?
    let biggestDayDate: Date?
    let biggestDayCount: Int
    let averageRating: Double?
    let firstVisitDate: Date?
}

/// Every number the stats screens show, derived from the cached parks alone.
///
/// Pure by design: no persistence, no networking, no UI. The screens own the fetch and
/// hand the results in, which keeps the maths testable and lets any view recompute
/// cheaply as SwiftData publishes changes.
///
/// Date-sensitive functions take the "now" and calendar they measure against on an
/// internal overload so tests are deterministic; the public entry points use the
/// user's own calendar and the current moment.
enum StatsEngine {

    /// Coordinates round-trip through miles → meters, so an exactly-on-the-ring park can
    /// land a fraction of a millimetre outside the limit. Half a metre of slack keeps the
    /// boundary inclusive without meaningfully widening the ring.
    private static let radiusToleranceMeters: CLLocationDistance = 0.5

    // MARK: - Radius completion

    static func radiusCompletion(
        parks: [Park],
        center: CLLocationCoordinate2D,
        radiusMiles: Double
    ) -> RadiusCompletion {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let limit = radiusMiles * Format.metersPerMile + radiusToleranceMeters

        let inRing = parks
            .map { ($0, $0.distance(from: origin)) }
            .filter { $0.1 <= limit }

        let total = inRing.count
        let visited = inRing.filter { $0.0.isVisited }.count
        let remaining = inRing
            .filter { !$0.0.isVisited }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }

        return RadiusCompletion(
            radiusMiles: radiusMiles,
            visited: visited,
            total: total,
            fraction: total == 0 ? 0 : Double(visited) / Double(total),
            remaining: remaining,
            visitedParks: inRing.filter { $0.0.isVisited }.sorted { $0.1 < $1.1 }.map { $0.0 }
        )
    }

    static func radiusCompletions(
        parks: [Park],
        center: CLLocationCoordinate2D,
        radiiMiles: [Double]
    ) -> [RadiusCompletion] {
        radiiMiles.map { radiusCompletion(parks: parks, center: center, radiusMiles: $0) }
    }

    // MARK: - Region completion

    static func completionByCity(parks: [Park], indexes: [RegionIndex] = []) -> [RegionCompletion] {
        completion(parks: parks, kind: .city, indexes: indexes) { $0.locality }
    }

    static func completionByCounty(parks: [Park], indexes: [RegionIndex] = []) -> [RegionCompletion] {
        completion(parks: parks, kind: .county, indexes: indexes) { $0.subAdministrativeArea }
    }

    static func completionByState(parks: [Park], indexes: [RegionIndex] = []) -> [RegionCompletion] {
        completion(parks: parks, kind: .state, indexes: indexes) { $0.administrativeArea }
    }

    /// Parks that haven't been reverse-geocoded yet have no key, and are left out entirely
    /// rather than lumped into an "Unknown" bucket that would skew every percentage.
    private static func completion(
        parks: [Park],
        kind: RegionKind,
        indexes: [RegionIndex],
        key: (Park) -> String?
    ) -> [RegionCompletion] {
        let indexByIdentifier = Dictionary(
            indexes.filter(\.isIndexed).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var groups: [String: [Park]] = [:]
        for park in parks {
            guard let name = key(park)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            groups[name, default: []].append(park)
        }

        return groups
            .map { name, members in
                let visited = members.filter(\.isVisited).count
                // An indexed region knows how many parks it really has. Without one the
                // total is only what has been stumbled across so far, which is why it used
                // to move whenever the search radius did.
                let indexed = members.compactMap { RegionIndex.identity(kind: kind, park: $0) }
                    .first
                    .flatMap { indexByIdentifier[$0] }
                let total = max(indexed?.parkCount ?? members.count, members.count)
                return RegionCompletion(
                    name: name,
                    visited: visited,
                    total: total,
                    fraction: total == 0 ? 0 : Double(visited) / Double(total),
                    remaining: members.filter { !$0.isVisited }.sorted { $0.name < $1.name },
                    visitedParks: members.filter(\.isVisited),
                    isIndexed: indexed != nil,
                    isApproximate: indexed?.isApproximate ?? false,
                    indexedAt: indexed?.indexedAt,
                    identifier: indexed?.identifier
                        ?? members.compactMap { RegionIndex.identity(kind: kind, park: $0) }.first
                        ?? name,
                    kind: kind
                )
            }
            .sorted { $0.total == $1.total ? $0.name < $1.name : $0.total > $1.total }
    }

    // MARK: - Timelines

    static func monthlyTimeline(parks: [Park], monthsBack: Int) -> [TimelinePoint] {
        monthlyTimeline(parks: parks, monthsBack: monthsBack, now: Date(), calendar: .current)
    }

    /// New parks per month. `cumulative` is seeded with everything first visited before the
    /// window, so the line reads as the size of the collection rather than restarting at zero.
    static func monthlyTimeline(
        parks: [Park],
        monthsBack: Int,
        now: Date,
        calendar: Calendar
    ) -> [TimelinePoint] {
        let months = monthStarts(monthsBack: monthsBack, now: now, calendar: calendar)
        guard let windowStart = months.first else { return [] }

        let firsts = parks.compactMap(\.firstVisitDate)
        var running = firsts.filter { $0 < windowStart }.count

        return months.map { month in
            let count = firsts.filter { calendar.isDate($0, equalTo: month, toGranularity: .month) }.count
            running += count
            return TimelinePoint(date: month, count: count, cumulative: running)
        }
    }

    static func visitTimeline(parks: [Park], monthsBack: Int) -> [TimelinePoint] {
        visitTimeline(parks: parks, monthsBack: monthsBack, now: Date(), calendar: .current)
    }

    static func visitTimeline(
        parks: [Park],
        monthsBack: Int,
        now: Date,
        calendar: Calendar
    ) -> [TimelinePoint] {
        let months = monthStarts(monthsBack: monthsBack, now: now, calendar: calendar)
        guard let windowStart = months.first else { return [] }

        let dates = allVisitDates(parks)
        var running = dates.filter { $0 < windowStart }.count

        return months.map { month in
            let count = dates.filter { calendar.isDate($0, equalTo: month, toGranularity: .month) }.count
            running += count
            return TimelinePoint(date: month, count: count, cumulative: running)
        }
    }

    static func calendarHeatmap(parks: [Park], daysBack: Int) -> [Date: Int] {
        calendarHeatmap(parks: parks, daysBack: daysBack, now: Date(), calendar: .current)
    }

    /// Every day in the window is present, zeros included, so a grid can index straight in.
    static func calendarHeatmap(
        parks: [Park],
        daysBack: Int,
        now: Date,
        calendar: Calendar
    ) -> [Date: Int] {
        guard daysBack > 0 else { return [:] }

        let today = calendar.startOfDay(for: now)
        var counts: [Date: Int] = [:]
        for offset in 0..<daysBack {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            counts[day] = 0
        }

        for date in allVisitDates(parks) {
            let day = calendar.startOfDay(for: date)
            guard counts[day] != nil else { continue }
            counts[day, default: 0] += 1
        }
        return counts
    }

    // MARK: - Streaks

    static func streaks(parks: [Park]) -> Streaks {
        streaks(parks: parks, now: Date(), calendar: .current)
    }

    /// A streak is measured in calendar weeks that contain at least one visit. The week in
    /// progress is not counted against the user: if last week had a visit the streak is
    /// still live, it just hasn't been extended yet.
    static func streaks(parks: [Park], now: Date, calendar: Calendar) -> Streaks {
        let dates = allVisitDates(parks).sorted()
        guard !dates.isEmpty else {
            return Streaks(currentWeeks: 0, longestWeeks: 0, longestGapDays: 0, lastVisitDate: nil)
        }

        let weeks = Set(dates.map { weekStart($0, calendar) })
        let thisWeek = weekStart(now, calendar)
        let lastWeek = previousWeek(thisWeek, calendar) ?? thisWeek

        var cursor: Date? = weeks.contains(thisWeek) ? thisWeek : (weeks.contains(lastWeek) ? lastWeek : nil)
        var current = 0
        while let week = cursor, weeks.contains(week) {
            current += 1
            cursor = previousWeek(week, calendar)
        }

        var longest = 0
        var run = 0
        var previous: Date?
        for week in weeks.sorted() {
            if let previous, nextWeek(previous, calendar) == week {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = week
        }

        var longestGap = 0
        let days = Array(Set(dates.map { calendar.startOfDay(for: $0) })).sorted()
        for (earlier, later) in zip(days, days.dropFirst()) {
            let gap = calendar.dateComponents([.day], from: earlier, to: later).day ?? 0
            longestGap = max(longestGap, gap)
        }

        return Streaks(
            currentWeeks: current,
            longestWeeks: longest,
            longestGapDays: longestGap,
            lastVisitDate: dates.last
        )
    }

    // MARK: - Records

    static func records(parks: [Park], origin: CLLocation?) -> Records {
        records(parks: parks, origin: origin, now: Date(), calendar: .current)
    }

    static func records(
        parks: [Park],
        origin: CLLocation?,
        now: Date,
        calendar: Calendar
    ) -> Records {
        let visited = visitedParks(parks)
        let allVisits = visited.flatMap { $0.visits ?? [] }

        let firsts = visited.compactMap(\.firstVisitDate)
        let parksThisMonth = firsts.filter { calendar.isDate($0, equalTo: now, toGranularity: .month) }.count
        let parksThisYear = firsts.filter { calendar.isDate($0, equalTo: now, toGranularity: .year) }.count

        let cities = Set(visited.compactMap { nonEmpty($0.locality) })
        let states = Set(visited.compactMap { nonEmpty($0.administrativeArea) })

        let mostVisited = visited
            .sorted { $0.visitCount == $1.visitCount ? $0.name < $1.name : $0.visitCount > $1.visitCount }
            .first

        var farthest: Park?
        var farthestMeters: Double?
        if let origin {
            let ranked: [(park: Park, meters: Double)] = visited.map { park in
                (park, park.distance(from: origin))
            }
            let best = ranked.sorted { lhs, rhs in
                lhs.meters == rhs.meters ? lhs.park.name < rhs.park.name : lhs.meters > rhs.meters
            }.first
            farthest = best?.park
            farthestMeters = best?.meters
        }

        // Distinct parks per day, not raw visits: three laps of one park isn't a big day out.
        var parksPerDay: [Date: Set<String>] = [:]
        for park in visited {
            for visit in park.visits ?? [] {
                let day = calendar.startOfDay(for: visit.date)
                parksPerDay[day, default: []].insert(park.identifier)
            }
        }
        let biggest = parksPerDay
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .first

        let ratings = allVisits.compactMap { $0.rating > 0 ? Double($0.rating) : nil }

        return Records(
            totalParks: visited.count,
            totalVisits: allVisits.count,
            parksThisMonth: parksThisMonth,
            parksThisYear: parksThisYear,
            distinctCities: cities.count,
            distinctStates: states.count,
            mostVisitedPark: mostVisited,
            farthestPark: farthest,
            farthestDistanceMeters: farthestMeters,
            biggestDayDate: biggest?.key,
            biggestDayCount: biggest?.value.count ?? 0,
            averageRating: ratings.isEmpty ? nil : ratings.reduce(0, +) / Double(ratings.count),
            firstVisitDate: firsts.min()
        )
    }

    // MARK: - Filters

    static func visitedParks(_ parks: [Park]) -> [Park] {
        parks.filter(\.isVisited)
    }

    static func unvisitedParks(_ parks: [Park]) -> [Park] {
        parks.filter { !$0.isVisited }
    }

    // MARK: - Helpers

    private static func allVisitDates(_ parks: [Park]) -> [Date] {
        parks.flatMap { ($0.visits ?? []).map(\.date) }
    }

    private static func monthStarts(monthsBack: Int, now: Date, calendar: Calendar) -> [Date] {
        guard monthsBack > 0 else { return [] }
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let months = (0..<monthsBack)
            .compactMap { calendar.date(byAdding: .month, value: -$0, to: thisMonth) }
        return Array(months.reversed())
    }

    /// Canonical key for the calendar week a date falls in. Normalised to a day start so
    /// that stepping week by week across a daylight-saving change still lands on the same key.
    private static func weekStart(_ date: Date, _ calendar: Calendar) -> Date {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return calendar.startOfDay(for: start)
    }

    private static func previousWeek(_ week: Date, _ calendar: Calendar) -> Date? {
        guard let stepped = calendar.date(byAdding: .weekOfYear, value: -1, to: week) else { return nil }
        return weekStart(stepped, calendar)
    }

    private static func nextWeek(_ week: Date, _ calendar: Calendar) -> Date? {
        guard let stepped = calendar.date(byAdding: .weekOfYear, value: 1, to: week) else { return nil }
        return weekStart(stepped, calendar)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
