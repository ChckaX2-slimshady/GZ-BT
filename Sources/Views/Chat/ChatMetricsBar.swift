import SwiftUI

/// The Chat metrics strip — fed by **Seam-1** telemetry (TTFT, tokens/sec,
/// generated tokens) plus model/status. This is the current consumer of the
/// telemetry stream that Spectre will later tap.
struct ChatMetricsBar: View {
    @Environment(\.theme) private var theme
    let metrics: ChatMetrics
    let modelName: String?
    let status: ChatViewModel.Status

    var body: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.xs) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText)
                    .font(ChameleonType.monoSmall)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            metric("TTFT", ttftText)
            divider
            metric("tok/s", tpsText)
            divider
            metric("tokens", tokensText)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.8) }
    }

    private var divider: some View {
        Rectangle().fill(theme.hairline).frame(width: 0.8, height: 20)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(ChameleonType.monoSmall)
                .foregroundStyle(theme.accentPrimary)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(minWidth: 50)
    }

    private var statusColor: Color {
        switch status {
        case .ready: theme.accentPrimary
        case .loading: theme.accentSecondary
        case .error: theme.warning
        case .noModel: theme.textTertiary
        }
    }

    private var statusText: String {
        switch status {
        case .ready: modelName ?? "Ready"
        case .loading: "Loading \(modelName ?? "model")…"
        case .error(let message): "Error: \(message)"
        case .noModel: "No model selected"
        }
    }

    private var ttftText: String { metrics.ttft.map { String(format: "%.0f ms", $0.milliseconds) } ?? "—" }
    private var tpsText: String { metrics.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—" }
    private var tokensText: String { metrics.generatedTokens.map(String.init) ?? "—" }
}
