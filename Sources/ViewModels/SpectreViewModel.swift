import Foundation
import Observation

/// Presentation state for the Spectre tab. Reads the shared `TelemetryHub` and
/// formats it — **no analysis, no Spectre internals**. S2.5 builds the view that
/// proves the seam is sufficient; what Spectre eventually *does* with the data is a
/// later decision.
///
/// Layer: **ViewModels**. Holds no visual tokens and no engine reference.
@MainActor
@Observable
final class SpectreViewModel {

    private let telemetry: TelemetryHub

    init(telemetry: TelemetryHub) {
        self.telemetry = telemetry
    }

    // MARK: - Status

    var lifecycleLabel: String { TelemetryHub.describe(telemetry.lifecycle) }
    var isObserving: Bool { telemetry.isObserving }

    var isLive: Bool {
        switch telemetry.lifecycle {
        case .generating, .loading: true
        default: false
        }
    }

    var isFailed: Bool {
        if case .failed = telemetry.lifecycle { return true }
        return false
    }

    // MARK: - Readouts

    var ttft: String { telemetry.ttft.map { String(format: "%.0f ms", $0.milliseconds) } ?? "—" }
    var tokensPerSecond: String { telemetry.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—" }
    var promptTokens: String { telemetry.promptTokens.map(String.init) ?? "—" }
    var generatedTokens: String { telemetry.generatedTokens.map(String.init) ?? "—" }
    var finishReason: String { telemetry.finishReason ?? "—" }
    var completedTurns: String { String(telemetry.completedTurns) }

    var context: String {
        guard let used = telemetry.contextUsed, let capacity = telemetry.contextCapacity else { return "—" }
        return "\(used) / \(capacity)"
    }

    /// 0...1, or nil when the engine has not reported a window yet.
    var contextFraction: Double? {
        guard let used = telemetry.contextUsed,
              let capacity = telemetry.contextCapacity,
              capacity > 0 else { return nil }
        return min(1, Double(used) / Double(capacity))
    }

    var samples: [Double] { telemetry.throughputSamples }
    var peakThroughput: String {
        telemetry.throughputSamples.max().map { String(format: "%.1f", $0) } ?? "—"
    }

    var events: [TelemetryHub.Entry] { telemetry.recentEvents }

    var hasData: Bool { telemetry.completedTurns > 0 || telemetry.tokensPerSecond != nil }
}
