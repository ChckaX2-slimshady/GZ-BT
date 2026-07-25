import Foundation
import Observation

/// Presentation state for the Chat vertical slice. Drives the inference engine,
/// consumes the token stream into visible messages, and mirrors **Seam-1**
/// telemetry into `metrics`. Owns no visual tokens; runs on the main actor.
@MainActor
@Observable
final class ChatViewModel {
    enum Status: Equatable { case noModel, loading, ready, error(String) }

    var input: String = ""
    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private(set) var metrics = ChatMetrics()
    private(set) var status: Status = .noModel

    private let engine: any InferenceEngine
    private let models: ModelManager
    private var loadedModelID: String?
    private var telemetryTask: Task<Void, Never>?
    private var genTask: Task<Void, Never>?

    init(engine: any InferenceEngine, models: ModelManager) {
        self.engine = engine
        self.models = models
    }

    var activeModelName: String? { models.activeModel?.name }

    var canSend: Bool {
        status == .ready && !isStreaming
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Begin observing Seam-1 and preload the active model. Idempotent.
    func start() {
        if telemetryTask == nil {
            let telemetry = engine.telemetry
            telemetryTask = Task { [weak self] in
                for await event in telemetry { self?.apply(event) }
            }
        }
        Task { [weak self] in
            await self?.ensureModelLoaded()
            #if DEBUG
            self?.runDemoPromptIfRequested()
            #endif
        }
    }

    #if DEBUG
    /// Evidence/demo aid: if launched with `GZBT_DEMO_PROMPT`, auto-send it once
    /// so a real streamed turn can be captured. Triggers the same path as a tap.
    private func runDemoPromptIfRequested() {
        guard messages.isEmpty, status == .ready,
              let prompt = ProcessInfo.processInfo.environment["GZBT_DEMO_PROMPT"],
              !prompt.isEmpty else { return }
        input = prompt
        send()
    }
    #endif

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        let assistant = ChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id
        isStreaming = true

        let request = GenerationRequest(
            messages: turns(),
            config: GenerationConfig(maxTokens: 512, temperature: 0.7, topP: 0.95))
        let engine = self.engine

        genTask = Task { [weak self] in
            await self?.ensureModelLoaded()
            if self?.status != .ready {
                self?.fail(assistantID, "model not ready")
                return
            }
            let stream = await engine.generate(request)
            for await event in stream {
                guard let self else { break }
                switch event {
                case .token(let token): self.append(token, to: assistantID)
                case .completed: self.endStream(assistantID)
                case .failed(let message): self.fail(assistantID, message)
                }
            }
            self?.isStreaming = false
        }
    }

    func cancel() {
        genTask?.cancel()
        let engine = self.engine
        Task { await engine.cancel() }
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].isStreaming = false
        }
        isStreaming = false
    }

    // MARK: - Private

    private func turns() -> [ChatTurn] {
        var turns: [ChatTurn] = [
            ChatTurn(role: .system, text: "You are HATS, a concise, friendly on-device assistant.")
        ]
        for message in messages where !(message.role == .assistant && message.isStreaming) {
            turns.append(ChatTurn(role: message.role == .user ? .user : .assistant, text: message.text))
        }
        return turns
    }

    private func append(_ token: String, to id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text += token
    }

    private func endStream(_ id: UUID) {
        if let idx = messages.firstIndex(where: { $0.id == id }) { messages[idx].isStreaming = false }
        isStreaming = false
    }

    private func fail(_ id: UUID, _ message: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].text = messages[idx].text.isEmpty ? "⚠︎ \(message)" : messages[idx].text
            messages[idx].isStreaming = false
        }
        isStreaming = false
    }

    private func ensureModelLoaded() async {
        if models.models.isEmpty { models.scan() }
        guard let active = models.activeModel else { status = .noModel; return }
        if loadedModelID == active.id, status == .ready { return }
        status = .loading
        do {
            try await engine.load(models.resolve(active), progress: nil)
            loadedModelID = active.id
            status = .ready
        } catch {
            status = .error("\(error)")
        }
    }

    private func apply(_ event: TelemetryEvent) {
        switch event {
        case .lifecycle(let lifecycle): metrics.lifecycle = label(lifecycle)
        case .firstToken(let ttft): metrics.ttft = ttft
        case .throughput(let tps): metrics.tokensPerSecond = tps
        case .context(let used, let capacity):
            metrics.contextUsed = used
            metrics.contextCapacity = capacity
        case .completed(let summary):
            metrics.tokensPerSecond = summary.tokensPerSecond
            metrics.promptTokens = summary.promptTokens
            metrics.generatedTokens = summary.generatedTokens
            metrics.ttft = summary.timeToFirstToken
        }
    }

    private func label(_ lifecycle: EngineLifecycle) -> String {
        switch lifecycle {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded: "ready"
        case .generating: "generating"
        case .unloaded: "unloaded"
        case .failed: "error"
        }
    }
}

/// Seam-1 metrics as presented in the Chat metrics bar.
struct ChatMetrics: Equatable {
    var ttft: Duration?
    var tokensPerSecond: Double?
    var promptTokens: Int?
    var generatedTokens: Int?
    var contextUsed: Int?
    var contextCapacity: Int?
    var lifecycle: String = "idle"
}

extension Duration {
    var milliseconds: Double {
        let c = components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
