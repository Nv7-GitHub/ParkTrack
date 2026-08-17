import Foundation
import CoreLocation
import Observation

/// Every derived figure the Stats tab shows, computed once and shared by its sections.
///
/// Each section used to hold its own cache and fill it the first time it was built. Inside a
/// LazyVStack that means the work happens exactly when the section scrolls into view — so the
/// tab froze on the way in while the top sections computed, and hitched again at each new
/// section on the way down. Here the whole screen's figures are worked out once, up front,
/// yielding between each so the run loop keeps drawing, and a section that appears later is
/// reading an answer that already exists.
@Observable
@MainActor
final class StatsCache {
    private(set) var isWarm = false

    private var signature: StatsSignature?

    private(set) var records: Records?
    private(set) var streaks: Streaks?
    private(set) var radiusCompletions: [RadiusCompletion] = []
    private(set) var cityCompletions: [RegionCompletion] = []
    private(set) var countyCompletions: [RegionCompletion] = []
    private(set) var stateCompletions: [RegionCompletion] = []
    private(set) var monthlyTimeline: [TimelinePoint] = []
    private(set) var visitTimeline: [TimelinePoint] = []
    private(set) var heatmapWeeks: [StatsHeatmapWeek] = []
    private(set) var weekdayBuckets: [StatsBucket] = []
    private(set) var monthBuckets: [StatsBucket] = []

    /// Timeline range the cached points were built for, so a section can tell whether the
    /// shared answer covers what it is asking about.
    private(set) var timelineMonths = 0

    func warm(
        parks: [Park],
        signature: StatsSignature,
        indexes: [RegionIndex],
        origin: CLLocation?,
        anchor: CLLocationCoordinate2D?,
        radiiMiles: [Double],
        timelineMonths months: Int
    ) async {
        guard self.signature != signature || !isWarm || timelineMonths != months else { return }
        self.signature = signature
        self.timelineMonths = months

        // A yield between each step hands the run loop back, so a long screen's worth of
        // figures never blocks a frame.
        records = StatsEngine.records(parks: parks, origin: origin)
        await Task.yield()
        streaks = StatsEngine.streaks(parks: parks)
        await Task.yield()
        if let anchor {
            radiusCompletions = StatsEngine.radiusCompletions(parks: parks, center: anchor, radiiMiles: radiiMiles)
        } else {
            radiusCompletions = []
        }
        await Task.yield()
        cityCompletions = StatsEngine.completionByCity(parks: parks, indexes: indexes)
        await Task.yield()
        countyCompletions = StatsEngine.completionByCounty(parks: parks, indexes: indexes)
        await Task.yield()
        stateCompletions = StatsEngine.completionByState(parks: parks, indexes: indexes)
        await Task.yield()
        monthlyTimeline = StatsEngine.monthlyTimeline(parks: parks, monthsBack: months)
        await Task.yield()
        visitTimeline = StatsEngine.visitTimeline(parks: parks, monthsBack: months)
        await Task.yield()
        heatmapWeeks = StatsBreakdown.heatmapWeeks(parks: parks)
        await Task.yield()
        weekdayBuckets = StatsBreakdown.byWeekday(parks: parks)
        await Task.yield()
        monthBuckets = StatsBreakdown.byMonthOfYear(parks: parks)

        isWarm = true
    }

    func completions(for scope: StatsRegionSection.Scope) -> [RegionCompletion] {
        switch scope {
        case .city: return cityCompletions
        case .county: return countyCompletions
        case .state: return stateCompletions
        }
    }
}
