import SwiftUI

/// Membrane surfaces — the Veiled Chameleon way of expressing depth: layered
/// translucency (SwiftUI material) + a canopy tint + a hairline edge. **Depth
/// through membranes, not shadows** — so these modifiers never add a shadow.
struct MembraneSurface: ViewModifier {
    enum Elevation { case low, medium, high }

    @Environment(\.theme) private var theme
    var radius: CGFloat
    var elevation: Elevation

    func body(content: Content) -> some View {
        let material: Material = switch elevation {
        case .low:    .ultraThinMaterial
        case .medium: .regularMaterial
        case .high:   .thickMaterial
        }
        let tintOpacity: Double = switch elevation {
        case .low:    0.08
        case .medium: 0.12
        case .high:   0.16
        }
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(material)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.membraneTint.opacity(tintOpacity))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.8)
                }
        }
    }
}

extension View {
    /// Wrap content in a translucent membrane surface (material + tint + hairline).
    func membraneSurface(
        cornerRadius: CGFloat = Radius.md,
        elevation: MembraneSurface.Elevation = .low
    ) -> some View {
        modifier(MembraneSurface(radius: cornerRadius, elevation: elevation))
    }
}
