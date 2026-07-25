import SwiftUI

/// Three softly-cycling dots — a brief, physical "generating" cue.
struct StreamingIndicatorView: View {
    @Environment(\.theme) private var theme
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(theme.accentPrimary.opacity(phase == index ? 1.0 : 0.28))
                    .frame(width: 5, height: 5)
            }
        }
        .onReceive(timer) { _ in
            withAnimation(Motion.quick) { phase = (phase + 1) % 3 }
        }
    }
}
