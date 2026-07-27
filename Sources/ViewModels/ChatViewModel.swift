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

    /// The conversation currently open in the transcript. `nil` until the store is
    /// ready or a conversation is selected.
    private(set) var currentConversationID: UUID?

    private let engine: any InferenceEngine
    private let models: ModelManager
    private let store: ConversationStore
    /// `mlx` | `llamacpp` | `remote:<provider>`. Supplied by the composition root —
    /// `InferenceEngine` deliberately gains no identity property (§7 forbids a
    /// contract amendment this session).
    private let engineID: String

    private var loadedModelID: String?
    private var telemetryTask: Task<Void, Never>?
    private var genTask: Task<Void, Never>?

    /// Seam-1 events for the in-flight assistant message. Fed from `apply(_:)` — the
    /// existing single stream consumer — so no second iterator is created (§4.3).
    private var accumulator = TelemetryAccumulator()

    init(
        engine: any InferenceEngine,
        models: ModelManager,
        store: ConversationStore,
        engineID: String = "mlx"
    ) {
        self.engine = engine
        self.models = models
        self.store = store
        self.engineID = engineID
    }

    var activeModelName: String? { models.activeModel?.name }

    var canSend: Bool {
        status == .ready && !isStreaming
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Begin observing Seam-1, open the store, restore the latest transcript, and
    /// preload the active model. Idempotent.
    func start() {
        if telemetryTask == nil {
            let telemetry = engine.telemetry
            telemetryTask = Task { [weak self] in
                for await event in telemetry { self?.apply(event) }
            }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.store.start()
            await self.restoreLatestConversation()
            await self.ensureModelLoaded()
            #if DEBUG
            self.runDemoPromptIfRequested()
            #endif
        }
    }

    /// Reopen the most recently updated conversation so the transcript survives a
    /// restart (E1). A fresh install has none; the first `send()` creates one.
    private func restoreLatestConversation() async {
        guard currentConversationID == nil,
              let latest = store.conversations.first else { return }
        await open(latest)
    }

    /// Load a conversation's history into the transcript (§4.7).
    func open(_ conversation: Conversation) async {
        guard !isStreaming else { return }
        currentConversationID = conversation.id
        messages = await store.messages(in: conversation.id).compactMap(ChatMessage.init)
    }

    /// Start a new, empty conversation. The row is created lazily on first send, so
    /// tapping "new" repeatedly cannot litter the store with empty threads.
    func newConversation() {
        guard !isStreaming else { return }
        currentConversationID = nil
        messages = []
        metrics = ChatMetrics(lifecycle: metrics.lifecycle)
    }

    func delete(_ conversation: Conversation) async {
        await store.delete(conversation)
        if currentConversationID == conversation.id {
            currentConversationID = nil
            messages = []
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

        let user = ChatMessage(role: .user, text: text)
        let assistantID = UUID()
        messages.append(user)
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: "", status: .streaming))
        isStreaming = true
        accumulator.reset()

        let request = GenerationRequest(
            messages: turns(),
            config: GenerationConfig(maxTokens: 512, temperature: 0.7, topP: 0.95))
        let engine = self.engine

        genTask = Task { [weak self] in
            guard let self else { return }

            // §4.5 steps 1–2: both rows land before a token is generated, so a crash
            // mid-stream leaves a detectable `streaming` row rather than nothing.
            let conversationID = await self.ensureConversation(titledFrom: text)
            if let conversationID {
                await self.store.appendUserMessage(text, id: user.id, to: conversationID)
                await self.store.beginAssistantMessage(id: assistantID, in: conversationID)
            }

            await self.ensureModelLoaded()
            guard self.status == .ready else {
                // No generation ran, so there is no summary and no telemetry row.
                await self.finish(assistantID, status: .failed, note: "model not ready", summary: nil)
                return
            }
            if let conversationID, let modelID = self.models.activeModel?.id {
                await self.store.setModel(modelID, for: conversationID)
            }

            // §4.5 step 3: tokens accumulate in the in-memory message. No per-token write.
            var terminal: MessageStatus = .complete
            var failure: String?
            var summary: GenerationSummary?
            let stream = await engine.generate(request)
            for await event in stream {
                switch event {
                case .token(let token): self.append(token, to: assistantID)
                case .completed(let generated):
                    terminal = .complete
                    summary = generated
                case .failed(let message):
                    terminal = .failed
                    failure = message
                }
            }
            if Task.isCancelled { terminal = .cancelled }
            await self.finish(assistantID, status: terminal, note: failure, summary: summary)
        }
    }

    func cancel() {
        guard isStreaming else { return }
        genTask?.cancel()
        let engine = self.engine
        Task { await engine.cancel() }
        // The generation task's `finish` writes the cancelled row; this only stops
        // the UI showing a live indicator while that unwinds.
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].status = .cancelled
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

    /// The conversation to write into, creating one on the first send and titling it
    /// from the first ~6 words of that message (§4.7). No LLM call for titling.
    private func ensureConversation(titledFrom text: String) async -> UUID? {
        if let currentConversationID { return currentConversationID }
        guard let conversation = await store.createConversation(
            title: Conversation.autoTitle(from: text)) else { return nil }
        currentConversationID = conversation.id
        return conversation.id
    }

    /// §4.5 steps 4/5 — end the turn in the UI and commit it in one transaction.
    private func finish(
        _ id: UUID,
        status: MessageStatus,
        note: String?,
        summary: GenerationSummary?
    ) async {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            if messages[idx].text.isEmpty, let note {
                messages[idx].text = "⚠︎ \(note)"
            }
            messages[idx].status = status
        }
        isStreaming = false

        let buffered = messages.first { $0.id == id }?.text ?? ""

        // Close the record from the generation stream's summary. Waiting on the
        // telemetry stream's own `.completed` raced with this method and dropped rows.
        if let summary {
            accumulator.complete(
                with: summary, contextCapacity: models.activeModel?.contextLength)
        }

        // Telemetry only exists for a turn that actually reached `.completed`;
        // a cancelled or failed turn writes the message row and no telemetry row.
        let telemetry = accumulator.isComplete
            ? accumulator.record(
                messageID: id,
                modelID: models.activeModel?.id ?? "unknown",
                engine: engineID)
            : nil

        if let conversationID = currentConversationID {
            await store.finishAssistantMessage(
                id: id,
                in: conversationID,
                content: buffered,
                status: status,
                telemetry: telemetry)
        }
        accumulator.reset()
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
        // Single stream consumer, two readers of the same events: the metrics bar
        // (via `metrics`) and the store (via `accumulator`). See §4.3.
        accumulator.apply(event)
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
            // Runtime proof for gate item G1 — device numbers are not observable
            // from a headless build otherwise. `.public` or the device logs redact it.
            Log.telemetry.notice("""
                SEAM1 completed model=\(self.models.activeModel?.name ?? "?", privacy: .public) \
                ttft_ms=\(summary.timeToFirstToken.milliseconds, privacy: .public) \
                tok_s=\(summary.tokensPerSecond, privacy: .public) \
                prompt_tokens=\(summary.promptTokens, privacy: .public) \
                generated_tokens=\(summary.generatedTokens, privacy: .public) \
                stop_reason=\(summary.stopReason, privacy: .public)
                """)
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
