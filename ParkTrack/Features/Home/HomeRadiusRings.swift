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
struct HomeRadiusRings: View {
    let completions: [RadiusCompletion]
    let center: CLLocationCoordinate2D

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
        VStack(spacing: 10) {
            ProgressRing(
                fraction: completion.fraction,
                lineWidth: 9,
                tint: tint,
                label: Format.percent(completion.fraction),
                caption: Format.miles(completion.radiusMiles)
            )
            .frame(width: 96, height: 96)

            Text("\(completion.visited)/\(completion.total)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
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
        .accessibilityValue("\(completion.visited) of \(completion.total) parks visited")
        .accessibilityHint("Shows the parks you have left in this ring")
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

    @Query private var parks: [Park]

    private var completion: RadiusCompletion {
        StatsEngine.radiusCompletion(parks: parks, center: route.center, radiusMiles: route.radiusMiles)
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
                            Text("\(completion.visited) of \(completion.total) visited")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            // No parks known here is not the same as having visited them all.
                            Text(completion.total == 0
                                 ? "No parks found within \(Format.miles(route.radiusMiles)) yet."
                                 : completion.remaining.isEmpty
                                 ? "This ring is complete. Widen your radius for a new challenge."
                                 : "\(Format.parkCount(completion.remaining.count)) still to go within \(Format.miles(route.radiusMiles)).")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if completion.remaining.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.seal",
                        title: completion.total == 0 ? "Nothing found here yet" : "Ring complete",
                        message: completion.total == 0
                            ? "Pull to refresh on Home to search this area for parks."
                            : "You've visited every park we know about inside this ring."
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(completion.remaining) { park in
                            NavigationLink(value: park) {
                                row(park)
                            }
                            .buttonStyle(.plain)
                            if park.identifier != completion.remaining.last?.identifier {
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
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Within \(Format.miles(route.radiusMiles))")
        .navigationBarTitleDisplayMode(.inline)
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
