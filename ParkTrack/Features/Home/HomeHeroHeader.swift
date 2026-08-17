import SwiftUI

/// The headline block: one huge number for parks visited, three supporting figures.
///
/// The card measures its own position in the scroll's coordinate space rather than taking
/// an offset from the parent, so `HomeView` stays free of scroll bookkeeping. Pulling down
/// stretches and scales it; scrolling away fades it out.
struct HomeHeroHeader: View {
    let greeting: String
    let subtitle: String
    let totalParks: Int
    let totalVisits: Int
    let cities: Int
    let streakWeeks: Int

    @Environment(\.colorScheme) private var colorScheme

    private let baseHeight: CGFloat = 250

    /// The hero gradient inverts with the palette, so the text on it has to invert too.
    private var ink: Color { Theme.heroInk(colorScheme) }

    var body: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(HomeView.scrollSpace)).minY
            let stretch = max(0, minY)
            let departure = min(max(0, -minY), 200)

            // The figures are a separate view whose inputs do not change while scrolling, so
            // SwiftUI skips rebuilding them and the pull-to-stretch is pure transform. Built
            // inline against `stretch`, the whole text hierarchy — every numeric-text
            // transition included — was reconstructed on each frame of a scroll.
            HeroFigures(
                greeting: greeting,
                subtitle: subtitle,
                totalParks: totalParks,
                totalVisits: totalVisits,
                cities: cities,
                streakWeeks: streakWeeks,
                ink: ink
            )
                .scaleEffect(1 + stretch / 900, anchor: .bottomLeading)
                .padding(24)
                .frame(width: proxy.size.width, height: baseHeight + stretch, alignment: .bottomLeading)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                // Behind the clipped content, so the shadow is thrown by a plain shape
                // instead of forcing the whole card to be rasterised every frame.
                .background {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Theme.heroGradient)
                        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
                }
                .offset(y: -stretch)
                .opacity(1 - Double(departure) / 260)
                .scaleEffect(1 - Double(departure) / 2000, anchor: .top)
        }
        .frame(height: baseHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(greeting). \(totalParks) parks visited, \(totalVisits) visits, \(cities) cities, \(streakWeeks) week streak.")
    }

}

/// The hero's text and figures, independent of the scroll position.
private struct HeroFigures: View {
    let greeting: String
    let subtitle: String
    let totalParks: Int
    let totalVisits: Int
    let cities: Int
    let streakWeeks: Int
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ink.opacity(0.9))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(ink.opacity(0.72))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(totalParks)")
                    .font(.system(size: 68, weight: .heavy, design: .rounded))
                    .foregroundStyle(ink)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(totalParks == 1 ? "park" : "parks")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.8))
            }

            HStack(spacing: 0) {
                figure(value: "\(totalVisits)", label: totalVisits == 1 ? "visit" : "visits")
                divider
                figure(value: "\(cities)", label: cities == 1 ? "city" : "cities")
                divider
                figure(value: "\(streakWeeks)", label: streakWeeks == 1 ? "week streak" : "week streak")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(ink.opacity(0.28))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 12)
    }

    private func figure(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(ink.opacity(0.75))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
