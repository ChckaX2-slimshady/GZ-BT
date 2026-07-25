import SwiftUI

/// GZ-BT Phoenix — application entry point.
///
/// Layer: **App**. Owns the process lifecycle and the scene graph only.
/// Composition of dependencies happens in `AppEnvironment` (added Checkpoint 3+);
/// routing lives in the **Navigation** layer; nothing here reaches into Inference.
@main
struct GZBTApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootNavigationView()
                .environment(environment)
                .chameleonTheme()
                .preferredColorScheme(.dark)   // Veiled Chameleon: dark is primary
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif
    }
}
