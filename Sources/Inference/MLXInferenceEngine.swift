import Foundation
import MLXLLM
import MLXLMCommon

/// MLX Swift binding of `InferenceEngine`.
///
/// Wraps a `ModelContainer` — a `Sendable` serial-access box, deliberately NOT
/// an `actor`/`ObservableObject` — behind *our* actor. All MLX work runs off the
/// main actor inside `container.perform`; only `Sendable` values cross back out.
/// MLX `Generation` values are translated into our neutral `GenerationEvent` /
/// `TelemetryEvent` so no MLX type leaks past the seam.
actor MLXInferenceEngine: InferenceEngine {

    nonisolated let telemetry: AsyncStream<TelemetryEvent>
    private let tele: AsyncStream<TelemetryEvent>.Continuation

    private var container: ModelContainer?
    private var loaded: ResolvedModel?
    private var current: Task<Void, Never>?
    private var contextCapacity: Int?

    init() {
        (telemetry, tele) = AsyncStream<TelemetryEvent>.makeStream()
        tele.yield(.lifecycle(.idle))
    }

    func load(_ model: ResolvedModel, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        #if targetEnvironment(simulator)
        // MLX needs a Metal GPU; the iOS Simulator has none, so loading would abort.
        // Fail gracefully instead of crashing — real devices and macOS run normally.
        tele.yield(.lifecycle(.failed("simulator")))
        throw InferenceError.unsupportedEnvironment(
            "On-device inference needs a real device — the iOS Simulator has no Metal GPU for MLX.")
        #else
        tele.yield(.lifecycle(.loading))
        let configuration = ModelConfiguration(directory: model.url)
        do {
            container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { p in
                progress?(p.fractionCompleted)
            }
            loaded = model
            contextCapacity = model.contextLength
            tele.yield(.lifecycle(.loaded))
        } catch {
            container = nil
            loaded = nil
            tele.yield(.lifecycle(.failed(Self.describe(error))))
            throw error
        }
        #endif
    }

    func unload() async {
        current?.cancel(); current = nil
        container = nil; loaded = nil
        tele.yield(.lifecycle(.unloaded))
    }

    func cancel() async {
        current?.cancel(); current = nil
    }

    func generate(_ request: GenerationRequest) -> AsyncStream<GenerationEvent> {
        let (stream, out) = AsyncStream<GenerationEvent>.makeStream()
        guard let container else {
            out.yield(.failed("No model loaded"))
            out.finish()
            return stream
        }
        let tele = self.tele
        let messages = request.messages
        let cfg = request.config
        let capacity = contextCapacity

        let task = Task {
            tele.yield(.lifecycle(.generating))
            let params = GenerateParameters(
                maxTokens: cfg.maxTokens,
                temperature: Float(cfg.temperature),
                topP: Float(cfg.topP))
            do {
                try await container.perform { (context: ModelContext) in
                    let chat: [Chat.Message] = messages.map { turn in
                        switch turn.role {
                        case .system: .system(turn.text)
                        case .user: .user(turn.text)
                        case .assistant: .assistant(turn.text)
                        }
                    }
                    let input = try await context.processor.prepare(input: UserInput(chat: chat))
                    let gen: AsyncStream<Generation> = try MLXLMCommon.generate(
                        input: input, cache: nil, parameters: params, context: context)

                    let start = ContinuousClock.now
                    var firstAt: ContinuousClock.Instant?
                    for await item in gen {
                        if Task.isCancelled { break }
                        switch item {
                        case .chunk(let text):
                            if firstAt == nil {
                                let now = ContinuousClock.now
                                firstAt = now
                                tele.yield(.firstToken(ttft: start.duration(to: now)))
                            }
                            out.yield(.token(text))
                        case .info(let info):
                            let contextUsed = info.promptTokenCount + info.generationTokenCount
                            if let capacity {
                                tele.yield(.context(used: contextUsed, capacity: capacity))
                            }
                            let summary = GenerationSummary(
                                promptTokens: info.promptTokenCount,
                                generatedTokens: info.generationTokenCount,
                                tokensPerSecond: info.tokensPerSecond,
                                promptTokensPerSecond: info.promptTokensPerSecond,
                                timeToFirstToken: firstAt.map { start.duration(to: $0) }
                                    ?? .seconds(info.promptTime),
                                totalTime: start.duration(to: .now),
                                stopReason: "\(info.stopReason)")
                            tele.yield(.throughput(tokensPerSecond: info.tokensPerSecond))
                            tele.yield(.completed(summary))
                            out.yield(.completed(summary))
                        case .toolCall:
                            break  // tool calling is out of scope for Session 1
                        }
                    }
                }
            } catch {
                out.yield(.failed(Self.describe(error)))
                tele.yield(.lifecycle(.failed(Self.describe(error))))
            }
            tele.yield(.lifecycle(.loaded))
            out.finish()
        }
        current = task
        return stream
    }

    private static func describe(_ error: Error) -> String { String(describing: error) }
}
