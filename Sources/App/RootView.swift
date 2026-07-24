import SwiftUI

/// Session-1 Checkpoint-1 placeholder root.
///
/// Intentionally free of visual constants — it exists only to prove the app
/// builds and launches on macOS and iPhone. It is replaced by the
/// DesignSystem-driven navigation shell in Checkpoint 3.
struct RootView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("GZ-BT")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
            Text("Phoenix · Session 1 scaffold")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RootView()
}
