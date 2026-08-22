import SwiftUI
import SwiftData
import CoreLocation

/// Which indexed places appear as races.
///
/// This started as a long-press on the chips themselves, with a line underneath offering to
/// reveal what was hidden. That put a destructive, undiscoverable gesture on the same control
/// used for switching races, and made the strip of chips do double duty as its own settings
/// screen. A list is the right shape for a list of things: everything visible at once, with
/// what you have put away in its own section rather than folded into the row of things you
/// are choosing between.
struct RaceVisibilitySheet: View {
    @Environment(\.dismiss) private var dismiss

    let origin: CLLocation?

    @Query(sort: \RegionIndex.name) private var indexes: [RegionIndex]

    private var indexed: [RegionIndex] {
        indexes.filter(\.isIndexed)
    }

    /// Same ordering as the races themselves, so the list reads in the order it is used.
    private func sorted(_ regions: [RegionIndex]) -> [RegionIndex] {
        guard let origin else { return regions }
        return regions
            .map { (region: $0, metres: origin.distance(from: CLLocation(latitude: $0.centerLatitude, longitude: $0.centerLongitude))) }
            .sorted { $0.metres < $1.metres }
            .map(\.region)
    }

    private var racing: [RegionIndex] { sorted(indexed.filter { !$0.isHiddenFromRaces }) }
    private var hidden: [RegionIndex] { sorted(indexed.filter(\.isHiddenFromRaces)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if racing.isEmpty {
                        Text("Nothing is racing. Bring something back from below.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(racing) { region in
                            row(region, isHidden: false)
                        }
                    }
                } header: {
                    Text("Racing")
                } footer: {
                    Text("Nearest first, the same order the races appear in.")
                }

                if !hidden.isEmpty {
                    Section("Hidden") {
                        ForEach(hidden) { region in
                            row(region, isHidden: true)
                        }
                    }
                }
            }
            .navigationTitle("Places to race")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ region: RegionIndex, isHidden: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: region.kind == .county ? "map" : "building.2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isHidden ? Theme.textSecondary : Theme.fern)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(region.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail(for: region))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(.smooth(duration: 0.25)) {
                    region.isHiddenFromRaces.toggle()
                }
            } label: {
                Image(systemName: isHidden ? "plus.circle" : "minus.circle")
                    .font(.title3)
                    .foregroundStyle(isHidden ? Theme.fern : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isHidden ? "Show \(region.displayName) in races" : "Hide \(region.displayName) from races")
        }
        .padding(.vertical, 2)
    }

    private func detail(for region: RegionIndex) -> String {
        var parts = [Format.parkCount(region.parkCount)]
        if let origin {
            let metres = origin.distance(from: CLLocation(
                latitude: region.centerLatitude,
                longitude: region.centerLongitude
            ))
            parts.append(Format.miles(metres / Format.metersPerMile))
        }
        return parts.joined(separator: " · ")
    }
}
