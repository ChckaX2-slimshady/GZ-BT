import SwiftUI

/// A single discovered model as a selectable membrane card.
struct ModelRow: View {
    @Environment(\.theme) private var theme
    let model: DiscoveredModel
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Space.md) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isActive ? theme.accentPrimary : theme.textSecondary)
                    .frame(width: 46, height: 46)
                    .membraneSurface(cornerRadius: Radius.md, elevation: .low)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(ChameleonType.headline)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(ChameleonType.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Space.sm)

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.accentPrimary)
                } else {
                    Text("Select")
                        .font(ChameleonType.caption)
                        .foregroundStyle(theme.accentSecondary)
                }
            }
            .padding(Space.md)
            .membraneSurface(cornerRadius: Radius.lg, elevation: isActive ? .high : .medium)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(isActive ? theme.accentPrimary.opacity(0.55) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .animation(Motion.micro, value: isActive)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let arch = model.architecture { parts.append(arch) }
        if let quant = model.quantization { parts.append(quant) }
        parts.append(ByteFormat.string(model.sizeBytes))
        return parts.joined(separator: "  ·  ")
    }
}
