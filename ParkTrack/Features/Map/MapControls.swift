import SwiftUI
import CoreLocation

/// One glass button in the floating cluster.
struct MapControlButton: View {
    let systemImage: String
    let label: String
    var isActive: Bool = false
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isActive ? .white : Theme.textPrimary)
                    .frame(width: 46, height: 46)
                    .background {
                        if isActive {
                            Circle().fill(Theme.accent)
                        } else {
                            Circle().fill(.ultraThinMaterial)
                        }
                    }
                    .overlay(Circle().strokeBorder(.white.opacity(isActive ? 0.35 : 0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.sunset, in: Capsule())
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .animation(.smooth(duration: 0.25), value: isActive)
    }
}

/// Bottom bar for the "I've been to all of these" flow.
struct BulkModeBar: View {
    let count: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // The caption never pluralises. "parks selected" is wider than "park selected",
            // and that one extra character grew this column enough to wrap "Mark Visited"
            // onto a second line, which changed the height of the whole bar between one
            // selection and two.
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                Text("selected")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(0)

            Spacer(minLength: 4)

            Button("Cancel", action: onCancel)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .buttonStyle(.bordered)
                .tint(Theme.bark)
                .layoutPriority(1)

            Button(action: onConfirm) {
                Label("Mark Visited", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(count == 0)
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bulk logging. \(count) parks selected.")
    }
}

/// Transient status capsule shown while discovery is running over the visible region.
struct MapStatusPill: View {
    let text: String
    var systemImage: String?
    var showsSpinner = false

    var body: some View {
        HStack(spacing: 7) {
            if showsSpinner {
                ProgressView().controlSize(.mini)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }
}

/// A single search hit, rendered as a glass row over the map.
struct MapSearchResultRow: View {
    let candidate: ParkCandidate
    let distanceMeters: CLLocationDistance?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "tree.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.name)
        .accessibilityHint("Shows this park on the map")
    }

    private var subtitle: String? {
        let distance = distanceMeters.map(Format.distance)
        let parts = [candidate.addressLine, distance].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The park's name beside its pin. Kept short and high-contrast: on a map it competes with
/// terrain, roads and Apple's own labels, so it carries its own backing rather than relying
/// on whatever happens to be underneath.
struct ParkNameLabel: View {
    let name: String
    let isVisited: Bool

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 118)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(isVisited ? Theme.canopy : Theme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
