import SwiftUI

extension Color {
    /// Construct a Color from a 0xRRGGBB literal in sRGB.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// Raw **Veiled Chameleon** palette — the pigments.
///
/// Feature code never references these directly; it reads the semantic roles on
/// `Theme`. Keeping the raw ramp in one place is what makes DesignSystem the sole
/// owner of color.
enum ChameleonPalette {
    static let canopy    = Color(hex: 0x0B3D2E)  // deep canopy green
    static let emerald   = Color(hex: 0x1E6F5C)
    static let gold      = Color(hex: 0xD9A72C)
    static let turquoise = Color(hex: 0x2EC4B6)
    static let bone      = Color(hex: 0xF2EDE4)
    static let charcoal  = Color(hex: 0x101413)
    static let nearBlack = Color(hex: 0x0B0D0C)
    static let rust      = Color(hex: 0xC1662F)  // warnings only

    // Depth extensions used by surfaces/gradients (still part of the ramp).
    static let abyss     = Color(hex: 0x070908)
    static let boneRaised = Color(hex: 0xFBF8F2)
}
