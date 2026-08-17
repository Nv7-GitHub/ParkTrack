import SwiftUI

/// The app's visual language: nature-toned depth. Deep forest and moss greens with a
/// sky accent, layered over map imagery with glass materials.
///
/// Every colour is defined for both light and dark here rather than in an asset catalog
/// so the whole palette is readable in one place.
enum Theme {
    // MARK: Palette

    static let canopy = adaptive(light: Color(hex: 0x1B4332), dark: Color(hex: 0xD8F3DC))
    static let moss = adaptive(light: Color(hex: 0x2D6A4F), dark: Color(hex: 0x74C69D))
    static let fern = adaptive(light: Color(hex: 0x40916C), dark: Color(hex: 0x52B788))
    static let sky = adaptive(light: Color(hex: 0x1D6F9E), dark: Color(hex: 0x7FC8F0))
    static let bark = adaptive(light: Color(hex: 0x6B5A45), dark: Color(hex: 0xC9B79C))
    static let sunset = adaptive(light: Color(hex: 0xD1633A), dark: Color(hex: 0xF0956B))

    /// Primary accent used for interactive elements and visited state.
    static let accent = fern

    // MARK: Surfaces

    static let background = adaptive(light: Color(hex: 0xF4F7F3), dark: Color(hex: 0x0E1512))
    static let surface = adaptive(light: .white, dark: Color(hex: 0x18211D))
    static let surfaceRaised = adaptive(light: .white, dark: Color(hex: 0x1F2A25))
    static let separator = adaptive(light: Color(hex: 0xE1E7DE), dark: Color(hex: 0x2A3630))

    // MARK: Text

    static let textPrimary = adaptive(light: Color(hex: 0x14201A), dark: Color(hex: 0xEEF4EF))
    static let textSecondary = adaptive(light: Color(hex: 0x5A6B60), dark: Color(hex: 0x9CB0A4))

    // MARK: Gradients

    // Built once rather than per access: these are read inside `ForEach` bodies, so a
    // computed property rebuilt the gradient or the array for every row on every frame.

    /// Hero gradient used behind headline stats.
    static let heroGradient = LinearGradient(
        colors: [canopy, moss, sky.opacity(0.75)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let progressGradient = LinearGradient(
        colors: [fern, sky],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Distinct hues for charts and multi-series data, ordered for adjacent-pair contrast.
    static let chartColors: [Color] = [fern, sky, sunset, bark, moss, canopy]

    // MARK: Metrics

    static let cornerRadius: CGFloat = 22
    static let tightCornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    /// Room the floating tab bar takes out of every tab's content. The bar floats over the
    /// content instead of shortening it, so a screen scrolled to its end leaves its last
    /// element half-hidden unless it reserves this much space.
    static let tabBarClearance: CGFloat = 76

    /// Text drawn on `heroGradient`.
    ///
    /// The gradient inverts with the palette — its dark-mode colours are the light ones, a
    /// pale green through to a pale blue — so the ink has to invert with it. White on the
    /// dark-mode gradient is white on pale green, which is barely there.
    static func heroInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x0E1512) : .white
    }

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

extension View {
    /// Reserves `Theme.tabBarClearance` below the content so it clears the floating tab bar.
    ///
    /// Padding goes into the safe area rather than around the view so backgrounds still run
    /// to the screen edge, scroll indicators stop in the right place, and anything centred
    /// in the remaining space centres in what the user can actually see. One modifier,
    /// applied the same way in every tab, is what keeps the five of them agreeing on where
    /// the bottom of the app is.
    func tabBarBottomInset() -> some View {
        safeAreaPadding(.bottom, Theme.tabBarClearance)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
