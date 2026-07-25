import SwiftUI

/// The sidebar: grouped destination list bound to the shell's selection.
/// Spectre appears only when enabled — Settings owns that toggle.
struct SidebarView: View {
    @Environment(\.theme) private var theme
    @Binding var selection: AppRoute?
    let spectreEnabled: Bool

    var body: some View {
        List(selection: $selection) {
            section("Workspace", AppRoute.workspace)
            section("Labs", labsRoutes)
            section("System", AppRoute.system)
        }
        .navigationTitle("GZ-BT")
    }

    private var labsRoutes: [AppRoute] {
        spectreEnabled ? AppRoute.labs + [.spectre] : AppRoute.labs
    }

    private func section(_ title: String, _ routes: [AppRoute]) -> some View {
        Section {
            ForEach(routes) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(route)
                    .foregroundStyle(route.isImplemented ? theme.textPrimary : theme.textSecondary)
            }
        } header: {
            Text(title)
                .font(ChameleonType.caption)
                .foregroundStyle(theme.textTertiary)
        }
    }
}
