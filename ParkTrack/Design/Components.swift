import SwiftUI

/// Rounded, softly shadowed container used for nearly every block of content.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The shadow is cast by the background shape rather than by the card as a whole.
            // Shadowing the whole view makes the compositor rasterise every subview inside
            // it first, on every redraw; shadowing an opaque rounded rectangle is one cheap
            // blur of a simple shape, and looks identical.
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
    }
}

/// Section header with an optional trailing action.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Big number + caption, the workhorse of the stats screens.
struct StatTile: View {
    let value: String
    /// Drawn smaller, beside the value, and excluded from the value's own fitting.
    ///
    /// A tile showing "116.8 MB" next to two showing "3244" and "125" used to shrink the
    /// only one with a unit in it: the whole string had to fit one line, and the unit is a
    /// third of its width. Three numbers meant to be read together came out at two
    /// different sizes. Splitting the unit off keeps every number at the same size.
    var unit: String?
    let label: String
    var systemImage: String?
    var tint: Color = Theme.accent
    /// Draws a chevron beside the icon. A number that opens into a list has to look like it
    /// does, or nobody finds out that it does.
    var showsDisclosure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                }
                if showsDisclosure {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.5))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            // Always two lines' worth, whether or not this label needs both. Tiles sit in a
            // row and are read across, so "Parks tracked" wrapping while "Visits logged"
            // does not left the three baselines at two different heights.
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Fills its grid cell so a tile whose label wraps cannot leave its neighbour
        // floating at a different height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
    }
}

/// Circular completion indicator used for radius and region progress.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 10
    var tint: Color = Theme.accent
    var label: String?
    var caption: String?

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.separator, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.55), tint], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.6), value: clamped)
            VStack(spacing: 1) {
                Text(label ?? "\(Int((clamped * 100).rounded()))%")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(lineWidth + 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? "Progress")
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }
}

/// Horizontal completion bar with a label and "m of n" trailing count.
struct ProgressBar: View {
    let title: String
    let visited: Int
    let total: Int
    var tint: Color = Theme.accent

    private var fraction: Double {
        total > 0 ? Double(visited) / Double(total) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(visited)/\(total)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.separator)
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * fraction))
                        .animation(.smooth(duration: 0.5), value: fraction)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(visited) of \(total)")
    }
}

/// Consistent empty state for lists that have nothing to show yet.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}

/// Small capsule tag used for categories, regions and filters.
struct Pill: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.moss

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            // A pill is a capsule; wrapped text inside one reads as a mistake, so it stays on
            // one line and shrinks a little before it truncates.
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// The one-tap "I've been to this park" control.
///
/// The same action the map's bulk mode performs on a whole selection, so it carries the
/// same name wherever it appears. It deliberately says what it will not do: a mark is not
/// a log, and nothing about it reaches the timeline, the streak or the heatmap.
struct MarkVisitedButton: View {
    let action: () -> Void
    var isCompact: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Label("Mark visited", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                if !isCompact {
                    Text("Counts it as visited, without a date")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(Theme.moss)
        .accessibilityLabel("Mark visited")
        .accessibilityHint("Counts this park as visited without recording a date")
    }
}
