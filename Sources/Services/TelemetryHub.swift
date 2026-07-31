import Foundation
import Observation

/// The **single** consumer of `InferenceEngine.telemetry` (Seam-1), and the fan-out
/// point for everything that wants those events.
///
/// `AsyncStream` supports exactly one iterator: a second `for await` over the same
/// stream splits events non-deterministically between the two. Session 1 had one
/// consumer (`ChatViewModel`, feeding `ChatMetricsBar`); Spectre is the second. Rather
/// than amend the seam to vend another stream — which BUILD_SESSION_2 §4.3 explicitly
/// reserves for TyPod — the subscription moves here and is re-broadcast.
///
/// Owned by `AppEnvironment` and started at launch, **not** by a view. Spectre must
/// render live without the user having visited Chat first; if the subscription lived
/// in `ChatView.task`, opening Spectre on a fresh launch would show a dead dashboard.
///
/// Layer: **Services**. It holds no engine reference beyond the stream and adds no
/// case to `TelemetryEvent` — the S2.5 exit criterion.
@MainActor
@Observable
final class TelemetryHub {

    // MARK: - Live snapshot

    private(set) var lifecycle: EngineLifecycle = .idle
    private(set) var ttft: Duration?
    private(set) var tokensPerSecond: Double?
    private(set) var contextUsed: Int?
    private(set) var contextCapacity: Int?
    private(set) var promptTokens: Int?
    private(set) var generatedTokens: Int?
    private(set) var finishReason: String?

    /// Completed turns observed this run.
    private(set) var completedTurns = 0
    /// Wall-clock of the most recent `.completed`, for a "last seen" readout.
    private(set) var lastCompletedAt: Date?

    /// Rolling tok/s samples, oldest first — the sparkline series. Capped so a long
    /// session cannot grow this without bound.
    private(set) var throughputSamples: [Double] = []
    static let sampleLimit = 60

    /// Every event seen this run, newest first, for the live event log. Capped.
    private(set) var recentEvents: [Entry] = []
    static let eventLimit = 40

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let detail: String
        let at: Date
    }

    /// True once the stream is being consumed — lets the UI distinguish "engine idle"
    /// from "nothing is listening".
    private(set) var isObserving = false

    // MARK: - Fan-out

    private var sinks: [UUID: (TelemetryEvent) -> Void] = [:]
    private var task: Task<Void, Never>?

    init() {}

    /// Stop consuming. Not called in the app — the hub is owned by `AppEnvironment`
    /// for the process lifetime — but tests need a way to tear the task down.
    /// (Deliberately not a `deinit`: touching main-actor state from a nonisolated
    /// `deinit` is exactly the isolation violation CLAUDE.md Gotcha #4 warns about.)
    func stop() {
        task?.cancel()
        task = nil
        isObserving = false
    }

    /// Begin consuming Seam-1. Idempotent — later calls are ignored, so this can be
    /// called from the composition root without guarding at every call site.
    func start(_ engine: any InferenceEngine) {
        guard task == nil else { return }
        isObserving = true
        let telemetry = engine.telemetry
        task = Task { [weak self] in
            for await event in telemetry {
                guard let self else { break }
                self.ingest(event)
            }
            self?.isObserving = false
        }
    }

    /// Register a downstream consumer. Returns a token for `removeSink`.
    ///
    /// Sinks receive every event in order, on the main actor. This is what keeps
    /// `ChatViewModel`'s Session-2 handling — metrics bar plus the persistence
    /// accumulator — working unchanged now that it no longer owns the subscription.
    @discardableResult
    func addSink(_ sink: @escaping (TelemetryEvent) -> Void) -> UUID {
        let token = UUID()
        sinks[token] = sink
        return token
    }

    func removeSink(_ token: UUID) {
        sinks[token] = nil
    }

    // MARK: - Private

    private func ingest(_ event: TelemetryEvent) {
        apply(event)
        for sink in sinks.values { sink(event) }
    }

    private func apply(_ event: TelemetryEvent) {
        switch event {
        case .lifecycle(let value):
            lifecycle = value
            record("lifecycle", Self.describe(value))

        case .firstToken(let value):
            ttft = value
            record("firstToken", String(format: "%.0f ms", value.milliseconds))

        case .throughput(let value):
            tokensPerSecond = value
            appendSample(value)
            record("throughput", String(format: "%.1f tok/s", value))

        case .context(let used, let capacity):
            contextUsed = used
            contextCapacity = capacity
            record("context", "\(used) / \(capacity)")

        case .completed(let summary):
            tokensPerSecond = summary.tokensPerSecond
            ttft = summary.timeToFirstToken
            promptTokens = summary.promptTokens
            generatedTokens = summary.generatedTokens
            finishReason = summary.stopReason
            appendSample(summary.tokensPerSecond)
            completedTurns += 1
            lastCompletedAt = Date()
            record("completed",
                   "\(summary.generatedTokens) tok · \(String(format: "%.1f", summary.tokensPerSecond)) tok/s · \(summary.stopReason)")
        }
    }

    private func appendSample(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        throughputSamples.append(value)
        if throughputSamples.count > Self.sampleLimit {
            throughputSamples.removeFirst(throughputSamples.count - Self.sampleLimit)
        }
    }

    private func record(_ label: String, _ detail: String) {
        recentEvents.insert(Entry(label: label, detail: detail, at: Date()), at: 0)
        if recentEvents.count > Self.eventLimit {
            recentEvents.removeLast(recentEvents.count - Self.eventLimit)
        }
    }

    static func describe(_ lifecycle: EngineLifecycle) -> String {
        switch lifecycle {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded: "ready"
        case .generating: "generating"
        case .unloaded: "unloaded"
        case .failed(let message): "failed: \(message)"
        }
    }
}
