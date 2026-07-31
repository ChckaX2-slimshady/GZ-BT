import SwiftUI

/// The Spectre tab — a **live** view of Seam-1, and nothing more.
///
/// S2.5's exit criterion: this renders live without adding a case to `TelemetryEvent`.
/// It reads only what the seam already emits — lifecycle, TTFT, throughput, context,
/// completion — so it is a falsification test of the contract, not the start of
/// Spectre itself. No benchmarking, no analysis, no storage.
///
/// Reachable only when `AppSettings.spectreEnabled` is on (default OFF): Spectre
/// incorporates at will and never blocks the app.
struct SpectreView: View {
    @Environment(\.theme) private var theme
    let vm: SpectreViewModel

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.md)]

    var body: some View {
        ZStack {
            theme.canopyWash.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    readouts
                    throughput
                    contextMeter
                    eventLog
                }
                .padding(Space.lg)
            }
        }
        .navigationTitle("Spectre")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if vm.isLive {
                        Circle().stroke(statusColor.opacity(0.5), lineWidth: 5).blur(radius: 2)
                    }
                }
                .animation(Motion.quick, value: vm.isLive)
            Text(vm.lifecycleLabel)
                .font(ChameleonType.monoSmall)
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: Space.sm)
            Text(vm.isObserving ? "Seam-1 · live" : "Seam-1 · not observing")
                .font(ChameleonType.monoSmall)
                .foregroundStyle(vm.isObserving ? theme.accentPrimary : theme.textTertiary)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .membraneSurface(cornerRadius: Radius.md, elevation: .low)
    }

    private var statusColor: Color {
        if vm.isFailed { return theme.warning }
        return vm.isLive ? theme.accentPrimary : theme.textTertiary
    }

    // MARK: - Readouts

    private var readouts: some View {
        LazyVGrid(columns: columns, spacing: Space.md) {
            tile("TTFT", vm.ttft, "firstToken")
            tile("tok/s", vm.tokensPerSecond, "throughput")
            tile("peak tok/s", vm.peakThroughput, "derived")
            tile("prompt tokens", vm.promptTokens, "completed")
            tile("generated", vm.generatedTokens, "completed")
            tile("stop reason", vm.finishReason, "completed")
            tile("context", vm.context, "context")
            tile("turns", vm.completedTurns, "completed")
        }
    }

    private func tile(_ label: String, _ value: String, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(ChameleonType.mono)
                .foregroundStyle(theme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            // Names the Seam-1 case each number came from — the point of the exercise.
            Text(".\(source)")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.accentSecondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .membraneSurface(cornerRadius: Radius.md, elevation: .low)
    }

    // MARK: - Throughput sparkline

    @ViewBuilder
    private var throughput: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("THROUGHPUT · last \(vm.samples.count) samples")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Sparkline(values: vm.samples, tint: theme.accentPrimary, baseline: theme.hairline)
                .frame(height: 56)
                .animation(Motion.quick, value: vm.samples.count)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .membraneSurface(cornerRadius: Radius.md, elevation: .low)
    }

    // MARK: - Context meter

    @ViewBuilder
    private var contextMeter: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("CONTEXT WINDOW")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Text(vm.context)
                    .font(ChameleonType.monoSmall)
                    .foregroundStyle(theme.textSecondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceInset)
                    Capsule()
                        .fill(theme.accentPrimary)
                        .frame(width: geometry.size.width * (vm.contextFraction ?? 0))
                }
            }
            .frame(height: 6)
            .animation(Motion.quick, value: vm.contextFraction ?? 0)
        }
        .padding(Space.md)
        .membraneSurface(cornerRadius: Radius.md, elevation: .low)
    }

    // MARK: - Event log

    @ViewBuilder
    private var eventLog: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("SEAM-1 EVENTS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)

            if vm.events.isEmpty {
                Text("No events yet. Send a message in Chat to see the seam fire.")
                    .font(ChameleonType.caption)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.vertical, Space.sm)
            } else {
                ForEach(vm.events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(".\(event.label)")
                            .font(ChameleonType.monoSmall)
                            .foregroundStyle(theme.accentSecondary)
                            .frame(width: 86, alignment: .leading)
                        Text(event.detail)
                            .font(ChameleonType.monoSmall)
                            .foregroundStyle(theme.textSecondary)
                        Spacer(minLength: Space.sm)
                        Text(event.at, format: .dateTime.hour().minute().second())
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .membraneSurface(cornerRadius: Radius.md, elevation: .low)
    }
}

/// A minimal line chart over a value series. Lives here rather than in DesignSystem
/// because Spectre is its only consumer; promote it if a second surface needs one.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color
    let baseline: Color

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if values.count < 2 {
                Rectangle()
                    .fill(baseline)
                    .frame(height: 0.8)
                    .position(x: size.width / 2, y: size.height / 2)
            } else {
                let lowest = values.min() ?? 0
                let highest = values.max() ?? 1
                // A flat series would divide by zero; give it a nominal band.
                let span = highest - lowest < 0.001 ? 1 : highest - lowest
                let points = values.enumerated().map { index, value in
                    CGPoint(
                        x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                        y: size.height * (1 - CGFloat((value - lowest) / span)))
                }
                ZStack {
                    Path { path in
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.addLine(to: CGPoint(x: 0, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0)],
                        startPoint: .top, endPoint: .bottom))

                    Path { $0.addLines(points) }
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
    }
}
