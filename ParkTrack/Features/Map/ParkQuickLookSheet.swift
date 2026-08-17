import SwiftUI
import SwiftData
import MapKit

/// The glass card that slides up when a pin is tapped.
///
/// Deliberately shallow: the small detent has to answer "what is this and have I been
/// there" at a glance, with the full history one push away rather than crammed in.
@MainActor
struct ParkQuickLookSheet: View {
    let park: Park
    let onLogVisit: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(LocationProvider.self) private var location
    @Environment(\.dismiss) private var dismiss

    private var distanceMeters: CLLocationDistance? {
        location.currentLocation.map { park.distance(from: $0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    actions
                    facts
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color.clear)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .tint(Theme.accent)
        .presentationDetents([.height(260), .large])
        .presentationBackground(.ultraThinMaterial)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(park.name)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            HStack(spacing: 8) {
                if park.isVisited {
                    Pill(text: "Visited", systemImage: "checkmark.seal.fill", tint: Theme.accent)
                } else {
                    Pill(text: "Not visited", systemImage: "circle.dashed", tint: Theme.bark)
                }
                if park.isWishlisted {
                    Pill(text: "Wishlist", systemImage: "star.fill", tint: Theme.sunset)
                }
                if let region = park.regionLabel {
                    Pill(text: region, systemImage: "mappin.and.ellipse", tint: Theme.sky)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onLogVisit) {
                Label("Log Visit", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            HStack(spacing: 10) {
                Button(action: toggleWishlist) {
                    Label(
                        park.isWishlisted ? "Wishlisted" : "Wishlist",
                        systemImage: park.isWishlisted ? "star.fill" : "star"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(Theme.sunset)
                .accessibilityLabel(park.isWishlisted ? "Remove from wishlist" : "Add to wishlist")

                Button(action: openDirections) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(Theme.sky)
            }

            NavigationLink {
                ParkDetailView(park: park)
            } label: {
                HStack {
                    Label("See Details", systemImage: "list.bullet.rectangle")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Theme.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
        }
    }

    private var facts: some View {
        HStack(spacing: 10) {
            StatTile(
                value: "\(park.visitCount)",
                label: park.visitCount == 1 ? "Visit" : "Visits",
                systemImage: "figure.walk"
            )
            StatTile(
                value: distanceMeters.map(Format.distance) ?? "—",
                label: "Away",
                systemImage: "location.fill",
                tint: Theme.sky
            )
            StatTile(
                value: park.lastVisitDate.map(Format.relative) ?? "Never",
                label: "Last visit",
                systemImage: "clock",
                tint: Theme.bark
            )
        }
    }

    private func toggleWishlist() {
        withAnimation(.smooth(duration: 0.25)) {
            park.isWishlisted.toggle()
        }
        try? modelContext.save()
    }

    private func openDirections() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: park.coordinate))
        item.name = park.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}
