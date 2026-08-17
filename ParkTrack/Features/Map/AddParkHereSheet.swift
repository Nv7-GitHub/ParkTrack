import SwiftUI
import CoreLocation

/// Names the park the user just long-pressed into existence.
///
/// The geocoder usually knows something about the spot — a point of interest, a street,
/// at worst a neighbourhood — so we prefill from that and let the user correct it, which
/// is far less work than typing a name from scratch on a map.
@MainActor
struct AddParkHereSheet: View {
    let coordinate: CLLocationCoordinate2D
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var placeDescription: String?
    @State private var isResolving = true
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("Name this place", subtitle: subtitle)

                            TextField("Park name", text: $name)
                                .textInputAutocapitalization(.words)
                                .font(.title3.weight(.medium))
                                .focused($nameFocused)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 12)
                                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                                        .strokeBorder(Theme.separator, lineWidth: 0.5)
                                )
                                .submitLabel(.done)
                                .onSubmit(add)

                            if isResolving {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("Looking up this spot…")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader("Coordinates")
                            Text(coordinateLabel)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Add Park Here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.height(340), .large])
        .presentationDragIndicator(.visible)
        .task { await resolvePlace() }
    }

    private var subtitle: String {
        placeDescription ?? "Anything the map doesn't already know about"
    }

    private var coordinateLabel: String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private func add() {
        guard !trimmedName.isEmpty else { return }
        onAdd(trimmedName)
        dismiss()
    }

    private func resolvePlace() async {
        defer { isResolving = false }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }

        placeDescription = [placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
            .nilIfEmpty

        guard name.isEmpty else { return }
        let suggestion = placemark.areasOfInterest?.first
            ?? placemark.name
            ?? placemark.thoroughfare
            ?? placemark.subLocality
            ?? placemark.locality
        if let suggestion, !suggestion.isEmpty {
            name = suggestion
        } else {
            nameFocused = true
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
