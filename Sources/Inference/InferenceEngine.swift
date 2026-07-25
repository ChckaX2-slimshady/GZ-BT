import Foundation

/// The engine-neutral inference contract — the single surface the app uses to
/// run a model. No engine-specific (MLX) type ever crosses this boundary.
///
/// `telemetry` is **Seam-1**: the future Spectre integration point. Session 1
/// builds only the seam (this stream); it never builds Spectre itself.
protocol InferenceEngine: Actor {
    /// Continuous lifecycle + performance telemetry. **Seam-1.**
    nonisolated var telemetry: AsyncStream<TelemetryEvent> { get }

    /// Load a resolved model into memory. `progress` reports 0...1 while loading.
    func load(_ model: ResolvedModel, progress: (@Sendable (Double) -> Void)?) async throws

    /// Release the model and free memory.
    func unload() async

    /// Stream a generation. The returned stream yields tokens, then a final
    /// `.completed` summary (or `.failed`). Telemetry flows separately via `telemetry`.
    func generate(_ request: GenerationRequest) -> AsyncStream<GenerationEvent>

    /// Cancel the in-flight generation, if any.
    func cancel() async
}

// MARK: - Errors

enum InferenceError: LocalizedError {
    case unsupportedEnvironment(String)
    case noModelLoaded

    var errorDescription: String? {
        switch self {
        case .unsupportedEnvironment(let message): message
        case .noModelLoaded: "No model loaded."
        }
    }
}

// MARK: - Request

struct GenerationRequest: Sendable {
    var messages: [ChatTurn]
    var config: GenerationConfig

    init(messages: [ChatTurn], config: GenerationConfig = .init()) {
        self.messages = messages
        self.config = config
    }
}

/// A neutral chat turn. Deliberately free of any engine or view type.
struct ChatTurn: Sendable, Equatable {
    enum Role: Sendable { case system, user, assistant }
    var role: Role
    var text: String

    init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

// MARK: - Token stream (what Chat renders)

enum GenerationEvent: Sendable {
    case token(String)
    case completed(GenerationSummary)
    case failed(String)
}

struct GenerationSummary: Sendable, Equatable {
    var promptTokens: Int
    var generatedTokens: Int
    var tokensPerSecond: Double
    var promptTokensPerSecond: Double
    var timeToFirstToken: Duration
    var totalTime: Duration
    var stopReason: String
}

// MARK: - Seam-1 telemetry

enum EngineLifecycle: Sendable, Equatable {
    case idle, loading, loaded, generating, unloaded
    case failed(String)
}

/// Payloads emitted on Seam-1. Spectre (future) consumes these; Session 1's
/// Chat metrics bar is the only current consumer.
enum TelemetryEvent: Sendable {
    case lifecycle(EngineLifecycle)
    case firstToken(ttft: Duration)
    case throughput(tokensPerSecond: Double)
    case context(used: Int, capacity: Int)
    case completed(GenerationSummary)
}
