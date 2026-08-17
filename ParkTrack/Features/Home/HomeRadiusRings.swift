import SwiftUI
import SwiftData
import CoreLocation

/// Route to the remaining-parks list for one ring.
///
/// The centre travels with the route instead of being read again on the far side, so the
/// detail always describes the ring that was actually tapped even if the user moves.
struct HomeRadiusRoute: Hashable {
    let radiusMiles: Double
    let latitude: Double
    let longitude: Double

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(radiusMiles: Double, center: CLLocationCoordinate2D) {
        self.radiusMiles = radiusMiles
        self.latitude = center.latitude
        self.longitude = center.longitude
    }
}

/// Completion rings for each radius the user cares about, centred on wherever they are.
///
/// A percentage implies a known denominator, and until discovery has actually searched the
/// ground a ring covers it has no such thing — so each ring says which of the two it is
/// rather than quietly presenting a floor as a total.
struct HomeRadiusRings: View {
    let completions: [RadiusCompletion]
    let center: CLLocationCoordinate2D

    @Environment(ServiceHub.self) private var services

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(completions.enumerated()), id: \.element.id) { index, completion in
                    NavigationLink(value: HomeRadiusRoute(radiusMiles: completion.radiusMiles, center: center)) {
                        ring(completion, tint: Theme.chartColors[index % Theme.chartColors.count])
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func ring(_ completion: RadiusCompletion, tint: Color) -> some View {
        let swept = isSwept(completion.radiusMiles)

        return VStack(spacing: 8) {
            ProgressRing(
                fraction: completion.fraction,
                lineWidth: 9,
                tint: swept ? tint : tint.opacity(0.55),
                label: Format.percent(completion.fraction),
                caption: Format.miles(completion.radiusMiles)
            )
            .frame(width: 96, height: 96)

            // The trailing "+" is the honest part: we know of at least this many parks here.
            Text(swept ? "\(completion.visited)/\(completion.total)" : "\(completion.visited)/\(completion.total)+")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)

            // "Scanning" used to mean "not fully covered", which is not the same thing at
            // all: a ring wider than the launch sweep is never covered, so it claimed to be
            // scanning on every launch while nothing was running. Now it says what is true —
            // searching, done, or a floor nobody is currently working on.
            Pill(
                text: swept ? "Swept" : (isSearching ? "Scanning" : "Partial"),
                systemImage: swept ? "checkmark" : (isSearching ? "binoculars" : "plus.magnifyingglass"),
                tint: swept ? Theme.moss : (isSearching ? Theme.sky : Theme.bark)
            )
        }
        .padding(.vertical, 14)
        .frame(width: 128)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Within \(Format.miles(completion.radiusMiles))")
        .accessibilityValue(swept
            ? "\(completion.visited) of \(completion.total) parks visited"
            : "\(completion.visited) of at least \(completion.total) parks visited. Still searching this area.")
        .accessibilityHint("Shows the parks you have left in this ring")
    }

    /// Whether a sweep is actually running right now, as opposed to ground simply not being
    /// covered yet.
    private var isSearching: Bool {
        services.discovery?.isSearching ?? false
    }

    private func isSwept(_ radiusMiles: Double) -> Bool {
        services.discovery?.hasSwept(around: center, radiusMiles: radiusMiles) ?? false
    }
}

/// Prompt shown in place of the rings when we have neither a fix nor a home coordinate.
struct HomeLocationPrompt: View {
    let isAuthorized: Bool
    let onEnableLocation: () -> Void
    let onSetHome: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "location.circle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Rings need a centre point")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Completion rings measure how much you've seen within a few miles of you. Share your location, or drop a home pin and we'll measure from there.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(isAuthorized ? "Use my location" : "Enable location", action: onEnableLocation)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    Button("Set home", action: onSetHome)
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
                .font(.subheadline.weight(.medium))
            }
        }
    }
}

/// The parks still unvisited inside one ring, nearest first.
///
/// It re-queries rather than carrying a snapshot, so logging a visit from here removes the
/// row the moment the store changes.
struct HomeRadiusDetailView: View {
    let route: HomeRadiusRoute

    @Environment(ServiceHub.self) private var services
    @Query private var parks: [Park]
    @State private var showsVisited = false

    private var completion: RadiusCompletion {
        StatsEngine.radiusCompletion(parks: parks, center: route.center, radiusMiles: route.radiusMiles)
    }

    /// Whether discovery has actually searched this ring, or is still working outwards
    /// towards it. Everything the screen claims about totals hangs off this.
    private var isSearching: Bool {
        services.discovery?.isSearching ?? false
    }

    private var isSwept: Bool {
        services.discovery?.hasSwept(around: route.center, radiusMiles: route.radiusMiles) ?? false
    }

    private var origin: CLLocation {
        CLLocation(latitude: route.latitude, longitude: route.longitude)
    }

    var body: some View {
        let completion = self.completion

        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                Card {
                    HStack(spacing: 18) {
                        ProgressRing(
                            fraction: completion.fraction,
                            lineWidth: 10,
                            tint: Theme.accent,
                            label: Format.percent(completion.fraction),
                            caption: nil
                        )
                        .frame(width: 84, height: 84)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(isSwept
                                 ? "\(completion.visited) of \(completion.total) visited"
                                 : "\(completion.visited) of \(completion.total)+ visited")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(summary(for: completion))
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !isSwept {
                                Pill(
                                    text: isSearching ? "Still scanning" : "Partial count",
                                    systemImage: isSearching ? "binoculars" : "plus.magnifyingglass",
                                    tint: isSearching ? Theme.sky : Theme.bark
                                )
                            }
                        }
                    }
                }

                // Both halves, not just the to-do list: "how am I doing here" is the question
                // the ring raises, and only the remaining parks cannot answer it.
                if completion.remaining.isEmpty {
                    EmptyStateView(
                        systemImage: isSwept ? "checkmark.seal" : "binoculars",
                        title: emptyStateTitle(for: completion),
                        message: emptyStateMessage(for: completion)
                    )
                } else {
                    parkList(title: "Still to go · \(completion.remaining.count)", parks: completion.remaining)
                }

                if !completion.visitedParks.isEmpty {
                    DisclosureGroup(isExpanded: $showsVisited) {
                        parkList(title: nil, parks: completion.visitedParks)
                            .padding(.top, 8)
                    } label: {
                        Text("Been to · \(completion.visited)")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .tint(Theme.accent)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Within \(Format.miles(route.radiusMiles))")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A percentage over ground we haven't searched is a guess, so say so before saying
    /// anything else about the total.
    @ViewBuilder
    private func parkList(title: String?, parks: [Park]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 0) {
                ForEach(parks) { park in
                    NavigationLink(value: park) {
                        row(park)
                    }
                    .buttonStyle(.plain)
                    if park.identifier != parks.last?.identifier {
                        Divider().overlay(Theme.separator).padding(.leading, 16)
                    }
                }
            }
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
        }
    }

    private func summary(for completion: RadiusCompletion) -> String {
        guard isSwept else {
            return "We're still searching within \(Format.miles(route.radiusMiles)), so this total will grow and the percentage is provisional."
        }
        // No parks known here is not the same as having visited them all.
        if completion.total == 0 {
            return "No parks found within \(Format.miles(route.radiusMiles))."
        }
        if completion.remaining.isEmpty {
            return "This ring is complete. Widen your radius for a new challenge."
        }
        return "\(Format.parkCount(completion.remaining.count)) still to go within \(Format.miles(route.radiusMiles))."
    }

    private func emptyStateTitle(for completion: RadiusCompletion) -> String {
        if completion.total == 0 { return "Nothing found here yet" }
        return isSwept ? "Ring complete" : "Nothing left so far"
    }

    private func emptyStateMessage(for completion: RadiusCompletion) -> String {
        guard isSwept else {
            return "We're still sweeping this area. Anything new that turns up lands here."
        }
        return completion.total == 0
            ? "Pull to refresh on Home to search this area for parks."
            : "You've visited every park we know about inside this ring."
    }

    private func row(_ park: Park) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tree")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.moss)
                .frame(width: 34, height: 34)
                .background(Theme.moss.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(park.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let region = park.regionLabel {
                    Text(region)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(Format.distance(park.distance(from: origin)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .padding(16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
