import SwiftUI
import CoreLocation

/// The pin for one cached park.
///
/// Visited parks read as solid and confident, unvisited ones as faint outlines waiting to
/// be filled in — the whole point of the map is watching outlines turn solid.
struct ParkMarker: View {
    let park: Park
    var isSelected: Bool = false
    var isBulkSelected: Bool = false

    private var diameter: CGFloat { park.isVisited ? 30 : 24 }

    private var glyph: String {
        if isBulkSelected { return "checkmark" }
        return park.isVisited ? "leaf.fill" : "tree"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .overlay(
                    Circle().strokeBorder(stroke, lineWidth: park.isVisited || isBulkSelected ? 1 : 1.5)
                )
                .frame(width: diameter, height: diameter)
                // Shadows are an offscreen pass each, and with a screenful of pins that was
                // the difference between a smooth pan and a stuttering one. The stroke above
                // already separates a pin from the map, so only the selected pin lifts.
                .shadow(color: .black.opacity(isSelected ? 0.3 : 0), radius: isSelected ? 5 : 0, x: 0, y: 2)

            Image(systemName: glyph)
                .font(.system(size: park.isVisited ? 13 : 11, weight: .bold))
                .foregroundStyle(glyphTint)

            if park.isWishlisted {
                Image(systemName: "star.fill")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Theme.sunset, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                    .offset(x: diameter / 2 - 1, y: -diameter / 2 + 1)
            }
        }
        .scaleEffect(isSelected ? 1.4 : 1)
        .animation(.smooth(duration: 0.28), value: isSelected)
        .animation(.smooth(duration: 0.2), value: isBulkSelected)
        .contentShape(Circle().inset(by: -8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(park.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
    }

    private var fill: AnyShapeStyle {
        if isBulkSelected { return AnyShapeStyle(Theme.sky) }
        if park.isVisited { return AnyShapeStyle(Theme.accent) }
        return AnyShapeStyle(.ultraThinMaterial)
    }

    private var stroke: Color {
        if isBulkSelected { return .white.opacity(0.9) }
        return park.isVisited ? .white.opacity(0.85) : Theme.accent.opacity(0.85)
    }

    private var glyphTint: Color {
        (park.isVisited || isBulkSelected) ? .white : Theme.accent
    }

    private var accessibilityValue: String {
        var parts: [String] = [park.isVisited ? "Visited \(park.visitCount) time\(park.visitCount == 1 ? "" : "s")" : "Not visited yet"]
        if park.isWishlisted { parts.append("On your wishlist") }
        if isBulkSelected { parts.append("Selected for bulk logging") }
        return parts.joined(separator: ". ")
    }
}

/// The pin the user drops with a long press, before it becomes a real park.
struct DroppedPinMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.sunset.opacity(0.25))
                .frame(width: 44, height: 44)
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.sunset)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .accessibilityLabel("Dropped pin")
    }
}

/// Percentage tag that sits on the edge of a radius ring.
struct RadiusRingLabel: View {
    let completion: RadiusCompletion

    var body: some View {
        HStack(spacing: 5) {
            Text(Format.miles(completion.radiusMiles))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(Format.percent(completion.fraction))
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.sky)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.sky.opacity(0.4), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.miles(completion.radiusMiles)) ring")
        .accessibilityValue("\(Format.percent(completion.fraction)) complete, \(completion.visited) of \(completion.total) parks")
    }
}

/// Dark veil over everything outside the user's explored bubbles.
///
/// Drawn as a single `Canvas` with the bubbles punched out via `destinationOut` rather
/// than as map overlays, because MapKit has no notion of subtracting one shape from
/// another — the union has to happen in the compositor.
struct FogOfWarOverlay: View {
    let holes: [FogHole]

    struct FogHole: Hashable {
        let center: CGPoint
        let radius: CGFloat
    }

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(0.62))
            )

            context.blendMode = .destinationOut
            for hole in holes {
                context.fill(Path(ellipseIn: rect(for: hole)), with: .color(.black))
            }

            context.blendMode = .normal
            for hole in holes {
                context.stroke(
                    Path(ellipseIn: rect(for: hole)),
                    with: .color(Color.white.opacity(0.22)),
                    lineWidth: 1
                )
            }
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rect(for hole: FogHole) -> CGRect {
        CGRect(
            x: hole.center.x - hole.radius,
            y: hole.center.y - hole.radius,
            width: hole.radius * 2,
            height: hole.radius * 2
        )
    }
}
