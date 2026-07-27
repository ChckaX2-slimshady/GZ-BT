import Foundation

/// Collects **Seam-1** events for one in-flight assistant message and materializes
/// exactly one `MessageTelemetry` row.
///
/// Seam-1 is an `AsyncStream` of an *enum*, so persisting a row means accumulating a
/// stream, not mapping a value (§4.3). This mirrors `ChatViewModel.apply(_:)` — the
/// handling that already feeds `ChatMetricsBar` — deliberately, so the store and the
/// metrics bar cannot drift into two readings of the same stream.
///
/// It is **not** a second consumer of the stream: `ChatViewModel` remains the single
/// consumer and feeds this accumulator from its existing handler. `AsyncStream`
/// supports one iterator; adding a second would split events non-deterministically.
struct TelemetryAccumulator: Equatable, Sendable {
    private(set) var ttftMs: Double?
    private(set) var tokensPerSecond: Double?
    private(set) var contextUsed: Int?
    private(set) var contextCapacity: Int?
    private(set) var promptTokens: Int?
    private(set) var tokensOut: Int?
    private(set) var finishReason: String?

    /// True once `.completed` has been seen — the signal to write the row.
    private(set) var isComplete = false

    init() {}

    /// Clear between messages. The accumulator is per-message, not per-session.
    mutating func reset() { self = TelemetryAccumulator() }

    mutating func apply(_ event: TelemetryEvent) {
        switch event {
        case .lifecycle:
            break  // no persisted column; lifecycle is a live-display concern
        case .firstToken(let ttft):
            ttftMs = ttft.milliseconds
        case .throughput(let tokensPerSecond):
            self.tokensPerSecond = tokensPerSecond
        case .context(let used, let capacity):
            contextUsed = used
            contextCapacity = capacity
        case .completed(let summary):
            // The summary is authoritative where it overlaps the incremental events,
            // exactly as ChatViewModel.apply treats it.
            tokensPerSecond = summary.tokensPerSecond
            ttftMs = summary.timeToFirstToken.milliseconds
            promptTokens = summary.promptTokens
            tokensOut = summary.generatedTokens
            finishReason = summary.stopReason
            isComplete = true
        }
    }

    /// Close the record from the **generation** stream's summary rather than waiting
    /// on the telemetry stream's `.completed`.
    ///
    /// Seam-1 telemetry and the generation stream are two independent `AsyncStream`s
    /// consumed by two different tasks, so their events have no relative ordering:
    /// a turn can finish before the telemetry task has drained `.completed`, which
    /// silently dropped telemetry rows until this was made deterministic. The engine
    /// yields the *same* `GenerationSummary` on both, so taking it from the stream we
    /// know has already arrived removes the race without touching the seam.
    ///
    /// `contextCapacity` is the model's `max_position_embeddings`, supplied by the
    /// caller for the same reason.
    mutating func complete(with summary: GenerationSummary, contextCapacity capacity: Int?) {
        apply(.completed(summary))
        // `.context(used:)` may not have landed yet. The engine defines used as
        // promptTokenCount + generationTokenCount; derive it identically.
        if contextUsed == nil {
            contextUsed = summary.promptTokens + summary.generatedTokens
        }
        if contextCapacity == nil {
            contextCapacity = capacity
        }
    }

    /// Build the row. `modelID`/`engine` come from the caller because Seam-1 carries
    /// neither — and adding them would be a seam amendment, which §7 forbids.
    func record(messageID: UUID, modelID: String, engine: String) -> MessageTelemetry {
        MessageTelemetry(
            messageID: messageID,
            modelID: modelID,
            engine: engine,
            ttftMs: ttftMs,
            tokensPerSecond: tokensPerSecond,
            contextUsed: contextUsed,
            contextCapacity: contextCapacity,
            promptTokens: promptTokens,
            tokensOut: tokensOut,
            finishReason: finishReason)
    }
}
