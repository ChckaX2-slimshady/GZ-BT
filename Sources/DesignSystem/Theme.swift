import SwiftUI

/// Semantic color + gradient roles for the Veiled Chameleon language.
///
/// Dark is primary; light inverts around bone with green/gold structure. Values
/// are tuned for WCAG: bone-on-nearBlack ≈ 17:1 and charcoal-on-bone ≈ 15:1
/// (both AAA); accents are reserved for structure/emphasis at ≥3:1.
struct Theme: Sendable, Equatable {
    // Surfaces & structure
    var surfaceBase: Color
    var surfaceRaised: Color
    var surfaceInset: Color
    var membraneTint: Color
    var structure: Color
    var hairline: Color

    // Accents
    var accentPrimary: Color
    var accentSecondary: Color
    var onAccent: Color

    // Text
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color

    // Status (rust: warnings only)
    var warning: Color

    static let dark = Theme(
        surfaceBase: ChameleonPalette.nearBlack,
        surfaceRaised: ChameleonPalette.charcoal,
        surfaceInset: ChameleonPalette.abyss,
        membraneTint: ChameleonPalette.canopy,
        structure: ChameleonPalette.emerald,
        hairline: ChameleonPalette.emerald.opacity(0.30),
        accentPrimary: ChameleonPalette.turquoise,
        accentSecondary: ChameleonPalette.gold,
        onAccent: ChameleonPalette.nearBlack,
        textPrimary: ChameleonPalette.bone,
        textSecondary: ChameleonPalette.bone.opacity(0.72),
        textTertiary: ChameleonPalette.bone.opacity(0.48),
        warning: ChameleonPalette.rust)

    static let light = Theme(
        surfaceBase: ChameleonPalette.bone,
        surfaceRaised: ChameleonPalette.boneRaised,
        surfaceInset: ChameleonPalette.bone.opacity(0.6),
        membraneTint: ChameleonPalette.emerald,
        structure: ChameleonPalette.emerald,
        hairline: ChameleonPalette.emerald.opacity(0.24),
        accentPrimary: ChameleonPalette.emerald,
        accentSecondary: ChameleonPalette.gold,
        onAccent: ChameleonPalette.bone,
        textPrimary: ChameleonPalette.charcoal,
        textSecondary: ChameleonPalette.charcoal.opacity(0.70),
        textTertiary: ChameleonPalette.charcoal.opacity(0.45),
        warning: ChameleonPalette.rust)
}

// MARK: - Tonal gradients (subtle, membrane-friendly)

extension Theme {
    /// A restrained top-to-bottom canopy wash for full-screen backgrounds.
    var canopyWash: LinearGradient {
        LinearGradient(
            colors: [surfaceBase, membraneTint.opacity(0.22), surfaceBase],
            startPoint: .top, endPoint: .bottom)
    }

    /// A soft radial veil that adds depth behind foreground membranes.
    var depthVeil: RadialGradient {
        RadialGradient(
            colors: [membraneTint.opacity(0.20), surfaceBase.opacity(0.0)],
            center: .topLeading, startRadius: 0, endRadius: 640)
    }
}

// MARK: - Environment plumbing

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .dark
}

extension EnvironmentValues {
    /// The resolved Veiled Chameleon theme. Views read this; nothing else owns color.
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

private struct ChameleonThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.theme, scheme == .dark ? .dark : .light)
    }
}

extension View {
    /// Resolve the theme for the current color scheme and inject it into the
    /// environment. Apply once near the root.
    func chameleonTheme() -> some View {
        modifier(ChameleonThemeModifier())
    }
}
