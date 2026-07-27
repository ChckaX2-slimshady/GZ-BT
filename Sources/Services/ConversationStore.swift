import Foundation
import Observation

/// The app-facing persistence surface: the sole owner of chat storage, mirroring
/// `ModelManager`'s role for models (§4.1). `ChatViewModel` talks to this and never
/// sees SQL.
///
/// `@MainActor @Observable` per ARCHITECTURE's concurrency rule for Services, but it
/// holds **no** SQLite state: every statement runs inside `ConversationDatabase`, an
/// actor, so a write cannot block token streaming (§8).
///
/// Built once in `AppEnvironment` — never in SwiftUI `@State`, which is recreated and
/// would yield multiple connections to the same file.
@MainActor
@Observable
final class ConversationStore {
    private(set) var conversations: [Conversation] = []
    private(set) var isReady = false
    /// Surfaced rather than swallowed: a store that failed to open is a red result.
    private(set) var lastError: String?
    /// Crash artifacts reclaimed by the launch sweep (§4.5 step 6).
    private(set) var reclaimedOnLaunch = 0

    private var database: ConversationDatabase?
    private let url: URL?

    /// `url` is injectable so tests get a temporary file instead of the real store.
    init(url: URL? = nil) {
        self.url = url
    }

    /// Open, migrate, sweep, and load. Idempotent — safe to call from `.task`.
    func start() async {
        guard database == nil else { return }
        do {
            let location = try url ?? ConversationDatabase.defaultURL()
            let database = try ConversationDatabase(url: location)
            // §4.6 requires the resolved absolute path be observable at launch;
            // the exit criteria run `sqlite3` against exactly this path.
            Log.store.notice("store opened path=\(location.path, privacy: .public)")

            reclaimedOnLaunch = try await database.sweepInterruptedMessages()
            if reclaimedOnLaunch > 0 {
                Log.store.notice(
                    "reclaimed \(self.reclaimedOnLaunch, privacy: .public) interrupted message(s) → failed")
            }

            self.database = database
            conversations = try await database.conversations()
            isReady = true
        } catch {
            lastError = "\(error)"
            Log.store.error("store failed to open: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Conversations

    @discardableResult
    func createConversation(title: String = "New conversation") async -> Conversation? {
        guard let database else { return nil }
        let now = Date()
        let conversation = Conversation(title: title, createdAt: now, updatedAt: now)
        do {
            try await database.insert(conversation)
            await refresh()
            return conversation
        } catch {
            report(error)
            return nil
        }
    }

    func delete(_ conversation: Conversation) async {
        guard let database else { return }
        do {
            try await database.deleteConversation(id: conversation.id)
            await refresh()
        } catch {
            report(error)
        }
    }

    func messages(in conversationID: UUID) async -> [PersistedMessage] {
        guard let database else { return [] }
        do {
            return try await database.messages(in: conversationID)
        } catch {
            report(error)
            return []
        }
    }

    func refresh() async {
        guard let database else { return }
        do {
            conversations = try await database.conversations()
        } catch {
            report(error)
        }
    }

    // MARK: - Message write path (§4.5)

    /// Step 1 — the user's message is complete the moment it is sent.
    ///
    /// `id` is supplied by the caller so the on-screen message and its row share one
    /// identity; the view must not wait on a database round-trip to render.
    @discardableResult
    func appendUserMessage(_ text: String, id: UUID, to conversationID: UUID) async -> PersistedMessage? {
        await append(id: id, role: .user, content: text, status: .complete, to: conversationID)
    }

    /// Step 2 — the assistant row lands immediately, empty and `streaming`, so a
    /// crash between here and completion is detectable on next launch.
    @discardableResult
    func beginAssistantMessage(id: UUID, in conversationID: UUID) async -> PersistedMessage? {
        await append(id: id, role: .assistant, content: "", status: .streaming, to: conversationID)
    }

    /// Steps 4/5 — one transaction: final content, terminal status, telemetry row.
    ///
    /// Tokens are buffered in memory by the caller and written **once** here; there is
    /// deliberately no per-token write.
    func finishAssistantMessage(
        id: UUID,
        in conversationID: UUID,
        content: String,
        status: MessageStatus,
        telemetry: MessageTelemetry?
    ) async {
        guard let database else { return }
        do {
            try await database.finishMessage(
                id: id,
                content: content,
                status: status,
                telemetry: telemetry,
                conversationID: conversationID,
                touchedAt: Date())
            await refresh()
        } catch {
            report(error)
        }
    }

    /// Set the auto-title once, from the first user message (§4.7).
    func setTitle(_ title: String, for conversationID: UUID) async {
        guard let database else { return }
        do {
            try await database.updateConversation(
                id: conversationID, title: title, modelID: nil, touchedAt: Date())
            await refresh()
        } catch {
            report(error)
        }
    }

    func setModel(_ modelID: String, for conversationID: UUID) async {
        guard let database else { return }
        do {
            try await database.updateConversation(
                id: conversationID, title: nil, modelID: modelID, touchedAt: Date())
        } catch {
            report(error)
        }
    }

    // MARK: - Test/diagnostic reads

    func telemetry(for messageID: UUID) async -> MessageTelemetry? {
        guard let database else { return nil }
        return try? await database.telemetry(for: messageID)
    }

    func orphanCounts() async -> (messages: Int, telemetry: Int) {
        guard let database else { return (0, 0) }
        return (try? await database.orphanCounts()) ?? (0, 0)
    }

    func counts() async -> (conversations: Int, messages: Int, telemetry: Int, streaming: Int) {
        guard let database else { return (0, 0, 0, 0) }
        return (try? await database.counts()) ?? (0, 0, 0, 0)
    }

    // MARK: - Private

    private func append(
        id: UUID,
        role: MessageRole,
        content: String,
        status: MessageStatus,
        to conversationID: UUID
    ) async -> PersistedMessage? {
        guard let database else { return nil }
        do {
            let sequence = try await database.nextSequence(in: conversationID)
            let message = PersistedMessage(
                id: id,
                conversationID: conversationID,
                role: role,
                content: content,
                createdAt: Date(),
                sequence: sequence,
                status: status)
            try await database.insert(message)
            return message
        } catch {
            report(error)
            return nil
        }
    }

    private func report(_ error: Error) {
        lastError = "\(error)"
        Log.store.error("store error: \(String(describing: error), privacy: .public)")
    }
}
