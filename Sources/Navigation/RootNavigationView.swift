import SwiftUI

/// The app shell: a `NavigationSplitView` sidebar over a detail pane. Owns
/// selection routing only — each destination renders its own view. Real
/// destinations (Chat, Models) replace their placeholders in later checkpoints.
struct RootNavigationView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.theme) private var theme
    @State private var selection: AppRoute? = .chat

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection,
                        spectreEnabled: env.settings.spectreEnabled)
                .navigationSplitViewColumnWidth(min: 224, ideal: 252)
        } detail: {
            NavigationStack {
                detail(for: selection ?? .chat)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surfaceBase.ignoresSafeArea())
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func detail(for route: AppRoute) -> some View {
        switch route {
        case .models:
            ModelsView(manager: env.models)
        case .settings:
            SettingsView()
        default:
            // Chat becomes its real view in Checkpoint 5.
            PlaceholderView(route: route)
        }
    }
}
