import SwiftUI
import CoreLocation

/// Completion rings for the fixed 2.5 / 5 / 10 mile bands plus the user's own radius,
/// measured from a point they choose, with a slider for exploring any other distance.
struct StatsRadiusSection: View {
    let parks: [Park]
    let signature: StatsSignature
    let anchor: StatsAnchor
    let anchorCoordinate: CLLocationCoordinate2D?
    let radiiMiles: [Double]
    @Binding var selectedAnchor: StatsAnchor
    let onDropPin: () -> Void

    @State private var exploreMiles: Double = 15
    @State private var detail: RadiusCompletion?
    @State private var completionsCache = DerivedCache<[RadiusCompletion]>()
    @State private var exploreCache = DerivedCache<RadiusCompletion?>()

    init(
        parks: [Park],
        signature: StatsSignature,
        anchor: StatsAnchor,
        anchorCoordinate: CLLocationCoordinate2D?,
        radiiMiles: [Double],
        selectedAnchor: Binding<StatsAnchor>,
        onDropPin: @escaping () -> Void
    ) {
        self.parks = parks
        self.signature = signature
        self.anchor = anchor
        self.anchorCoordinate = anchorCoordinate
        self.radiiMiles = radiiMiles
        self._selectedAnchor = selectedAnchor
        self.onDropPin = onDropPin
    }

    private var origin: CLLocation? {
        anchorCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var completions: [RadiusCompletion] {
        guard let anchorCoordinate else { return [] }
        return completionsCache.value(for: signature) {
            StatsEngine.radiusCompletions(parks: parks, center: anchorCoordinate, radiiMiles: radiiMiles)
        }
    }

    private var exploration: RadiusCompletion? {
        guard let anchorCoordinate else { return nil }
        return exploreCache.value(for: signature.adding(exploreMiles)) {
            StatsEngine.radiusCompletion(parks: parks, center: anchorCoordinate, radiusMiles: exploreMiles)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                "How far you've gotten",
                subtitle: "Every park within each ring of your anchor point"
            )

            Card {
                VStack(alignment: .leading, spacing: 16) {
                    anchorPicker

                    if anchorCoordinate == nil {
                        StatsChartPlaceholder(systemImage: "location.slash", message: anchor.unavailableMessage)
                    } else {
                        rings
                        Divider().overlay(Theme.separator)
                        explorer
                    }
                }
            }
        }
        .sheet(item: $detail) { completion in
            StatsRemainingParksSheet(
                title: "Left within \(Format.miles(completion.radiusMiles))",
                subtitle: "within \(Format.miles(completion.radiusMiles))",
                parks: completion.remaining,
                origin: origin
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var anchorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Measure from", selection: $selectedAnchor) {
                ForEach(StatsAnchor.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Measure rings from")

            if selectedAnchor == .pin {
                Button(action: onDropPin) {
                    Label(
                        anchorCoordinate == nil ? "Drop a pin on the map" : "Move the pin",
                        systemImage: "mappin.and.ellipse"
                    )
                    .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }
        }
    }

    private var rings: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 78), spacing: 12)],
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(Array(completions.enumerated()), id: \.offset) { index, completion in
                Button {
                    detail = completion
                } label: {
                    VStack(spacing: 6) {
                        ProgressRing(
                            fraction: completion.fraction,
                            lineWidth: 9,
                            tint: Theme.chartColors[index % Theme.chartColors.count],
                            label: Format.percent(completion.fraction),
                            caption: Format.miles(completion.radiusMiles)
                        )
                        .frame(width: 78, height: 78)

                        Text("\(completion.visited)/\(completion.total)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Within \(Format.miles(completion.radiusMiles))")
                .accessibilityValue(
                    completion.total == 0
                    ? "No parks found yet"
                    : "\(completion.visited) of \(completion.total) parks visited, \(Format.percent(completion.fraction))"
                )
                .accessibilityHint("Shows the parks you still have left")
                .accessibilityAddTraits(.isButton)
            }
        }
        .animation(.smooth(duration: 0.5), value: completions.map(\.fraction))
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Explore any radius")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(Format.miles(exploreMiles))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
            }

            Slider(value: $exploreMiles, in: 0.5...100, step: 0.5) {
                Text("Radius in miles")
            } minimumValueLabel: {
                Text(Format.miles(0.5)).font(.caption2).foregroundStyle(Theme.textSecondary)
            } maximumValueLabel: {
                Text(Format.miles(100)).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            .tint(Theme.accent)
            .accessibilityLabel("Explore radius")
            .accessibilityValue(Format.miles(exploreMiles))

            if let exploration {
                ProgressBar(
                    title: "Visited within \(Format.miles(exploration.radiusMiles))",
                    visited: exploration.visited,
                    total: exploration.total,
                    tint: Theme.sky
                )

                if !exploration.remaining.isEmpty {
                    Button {
                        detail = exploration
                    } label: {
                        Label(
                            "\(Format.parkCount(exploration.remaining.count)) left in this ring",
                            systemImage: "list.bullet"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                } else if exploration.total > 0 {
                    Pill(text: "Ring complete", systemImage: "checkmark.seal.fill", tint: Theme.fern)
                }
            }
        }
    }
}
