import SwiftUI

/// Semi-real Settings. Session 1's single real setting is the global **Spectre
/// toggle** (default OFF), which gates the Spectre destination's visibility.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var settings = env.settings
        ZStack {
            theme.canopyWash.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    spectreCard(isOn: $settings.spectreEnabled)
                    Spacer(minLength: 0)
                }
                .padding(Space.xl)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Settings")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Settings")
                .font(ChameleonType.display)
                .foregroundStyle(theme.textPrimary)
            Text("Session 1 · the Spectre integration seam")
                .font(ChameleonType.callout)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func spectreCard(isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Enable Spectre")
                    .font(ChameleonType.headline)
                    .foregroundStyle(theme.textPrimary)
                Text("Reveals the Spectre metrics tab. Off by default; Spectre incorporates at will and never blocks the app.")
                    .font(ChameleonType.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(theme.accentPrimary)
        .padding(Space.lg)
        .membraneSurface(cornerRadius: Radius.lg, elevation: .medium)
    }
}
