import SwiftUI

/// One reusable, fully-tokenized placeholder for not-yet-built destinations.
/// Even stubs render through the DesignSystem so the whole shell is on-language.
/// Depends only on DesignSystem tokens and `AppRoute` for its label.
struct PlaceholderView: View {
    @Environment(\.theme) private var theme
    let route: AppRoute

    var body: some View {
        ZStack {
            theme.canopyWash.ignoresSafeArea()
            theme.depthVeil.ignoresSafeArea()

            VStack(spacing: Space.lg) {
                Image(systemName: route.systemImage)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(theme.accentPrimary)
                    .frame(width: 96, height: 96)
                    .membraneSurface(cornerRadius: Radius.lg, elevation: .medium)

                VStack(spacing: Space.xs) {
                    Text(route.title)
                        .font(ChameleonType.title)
                        .foregroundStyle(theme.textPrimary)
                    Text("Reserved for a later session")
                        .font(ChameleonType.callout)
                        .foregroundStyle(theme.textSecondary)
                }

                Text("VEILED CHAMELEON")
                    .font(ChameleonType.monoSmall)
                    .tracking(2)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .membraneSurface(cornerRadius: Radius.capsule, elevation: .low)
            }
            .padding(Space.xxl)
        }
        .navigationTitle(route.title)
    }
}
