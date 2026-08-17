import SwiftUI
import CoreLocation

/// Which overlays the map is drawing right now.
///
/// A single value type rather than a scatter of `@State` flags so the map body can diff
/// the whole layer configuration in one comparison, and so the layers panel only needs
/// one binding.
struct MapLayerOptions: Equatable {
    var showsFootprint = true
    /// Radius of the explored bubble drawn around every visited park.
    var footprintRadiusMiles: Double = 0.5
    var fogOfWar = false
    var showsRadiusRings = true
    var showsUnvisited = true

    var footprintRadiusMeters: CLLocationDistance {
        footprintRadiusMiles * Format.metersPerMile
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

                            Toggle(isOn: $options.showsFootprint) {
                                Label("Explored footprint", systemImage: "circle.dotted.circle")
                            }
                            .accessibilityHint("Draws a bubble around every park you have visited")

                            if options.showsFootprint {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Bubble radius")
                                            .font(.subheadline)
                                            .foregroundStyle(Theme.textSecondary)
                                        Spacer()
                                        Text(Format.miles(options.footprintRadiusMiles))
                                            .font(.subheadline.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(Theme.textPrimary)
                                    }
                                    Slider(value: $options.footprintRadiusMiles, in: 0.25...3, step: 0.25)
                                        .tint(Theme.accent)
                                        .accessibilityLabel("Explored bubble radius")
                                        .accessibilityValue(Format.miles(options.footprintRadiusMiles))
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
