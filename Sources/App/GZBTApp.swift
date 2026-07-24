import SwiftUI

/// GZ-BT Phoenix — application entry point.
///
/// Layer: **App**. Owns the process lifecycle and the scene graph only.
/// Composition of dependencies happens in `AppEnvironment` (added Checkpoint 3+);
/// routing lives in the **Navigation** layer; nothing here reaches into Inference.
@main
struct GZBTApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
