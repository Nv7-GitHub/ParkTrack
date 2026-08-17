import SwiftUI

/// The three ways to start a visit log. "I'm here now" is deliberately the biggest target:
/// it's the one people reach for while standing in the park.
struct HomeQuickActions: View {
    let isLocating: Bool
    let onHereNow: () -> Void
    let onFindByName: () -> Void
    let onPickOnMap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The hero gradient inverts with the palette, so the label on it inverts too.
    private var ink: Color {
        colorScheme == .dark ? Color(hex: 0x0E1512) : .white
    }

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onHereNow) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 46, height: 46)
                        if isLocating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(ink)
                        } else {
                            Image(systemName: "location.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ink)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("I'm here now")
                            .font(.headline)
                            .foregroundStyle(ink)
                        Text(isLocating ? "Looking for the nearest park…" : "Log the park you're standing in")
                            .font(.footnote)
                            .foregroundStyle(ink.opacity(0.85))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(ink.opacity(0.7))
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.heroGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(isLocating)
            .accessibilityLabel("I'm here now")
            .accessibilityHint("Finds the nearest park and opens the visit log")

            HStack(spacing: 12) {
                secondary(
                    title: "Find by name",
                    detail: "Search anywhere",
                    systemImage: "magnifyingglass",
                    tint: Theme.sky,
                    action: onFindByName
                )
                secondary(
                    title: "Pick on map",
                    detail: "Tap a park",
                    systemImage: "mappin.and.ellipse",
                    tint: Theme.sunset,
                    action: onPickOnMap
                )
            }
        }
    }

    private func secondary(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.14), in: Circle())
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
