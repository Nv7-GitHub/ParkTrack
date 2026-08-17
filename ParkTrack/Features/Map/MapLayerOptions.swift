import SwiftUI
import CoreLocation

/// Which overlays the map is drawing right now.
///
/// A single value type rather than a scatter of `@State` flags so the map body can diff
/// the whole layer configuration in one comparison, and so the layers panel only needs
/// one binding.
struct MapLayerOptions: Equatable {
    /// Fog of war dims everything and clears a circle around each visited park, so the
    /// unexplored parts of the map read as unexplored. That reveal is the only thing this
    /// radius drives — the map no longer paints bubbles on visited parks when fog is off,
    /// because they cluttered exactly the area the user most wants to read.
    var fogOfWar = false
    var revealRadiusMiles: Double = 0.5
    var showsRadiusRings = true
    var showsUnvisited = true
    /// Park names next to their pins. Automatic by default: names appear once the camera is
    /// close enough that they will not overlap into noise.
    var parkNames: ParkNameVisibility = .automatic

    var revealRadiusMeters: CLLocationDistance {
        revealRadiusMiles * Format.metersPerMile
    }
}

enum ParkNameVisibility: String, CaseIterable, Identifiable {
    case automatic, always, never
    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "When close"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

/// The sheet behind the "layers" control: everything that changes what the map draws.
struct MapLayersPanel: View {
    @Binding var options: MapLayerOptions
    let visitedCount: Int
    let totalCount: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader("Coverage", subtitle: "\(visitedCount) of \(totalCount) cached parks visited")

                            Picker(selection: $options.parkNames) {
                                ForEach(ParkNameVisibility.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            } label: {
                                Label("Park names", systemImage: "textformat.size")
                            }
                            .accessibilityHint("When to show park names beside their pins")

                            if options.fogOfWar {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Revealed radius")
                                            .font(.subheadline)
                                            .foregroundStyle(Theme.textSecondary)
                                        Spacer()
                                        Text(Format.miles(options.revealRadiusMiles))
                                            .font(.subheadline.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(Theme.textPrimary)
                                    }
                                    Slider(value: $options.revealRadiusMiles, in: 0.25...3, step: 0.25)
                                        .tint(Theme.accent)
                                        .accessibilityLabel("Fog of war revealed radius")
                                        .accessibilityValue(Format.miles(options.revealRadiusMiles))
                                }
                            }

                            Divider().overlay(Theme.separator)

                            Toggle(isOn: $options.fogOfWar) {
                                Label("Fog of war", systemImage: "cloud.fog.fill")
                            }
                            .accessibilityHint("Dims everywhere you have not explored yet")
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader("Guides")

                            Toggle(isOn: $options.showsRadiusRings) {
                                Label("Radius rings", systemImage: "target")
                            }
                            .accessibilityHint("Draws completion rings around you or your home")

                            Toggle(isOn: $options.showsUnvisited) {
                                Label("Show unvisited parks", systemImage: "tree")
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Map Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.height(430), .large])
        .presentationDragIndicator(.visible)
    }
}
