import Foundation

/// A persisted chat thread. Layer: **Models** — a domain value type that depends
/// on nothing above it and knows nothing about SQL.
struct Conversation: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Last model used in this conversation.
    var modelID: String?
    /// Forward slot for HATS (S4). Never written this session.
    var personaID: String?
    var archived: Bool
    /// Derived by the list query, not a stored column.
    var messageCount: Int

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        updatedAt: Date,
        modelID: String? = nil,
        personaID: String? = nil,
        archived: Bool = false,
        messageCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelID = modelID
        self.personaID = personaID
        self.archived = archived
        self.messageCount = messageCount
    }

    /// Auto-title from the first ~6 words of the first user message (§4.7).
    /// No LLM call — titling by model is out of scope this session.
    static func autoTitle(from text: String) -> String {
        let words = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return "New conversation" }
        let kept = words.prefix(6)
        let title = kept.joined(separator: " ")
        // Ellipsis only when something was actually cut — a message that is exactly
        // six words long is not truncated.
        return words.count > kept.count ? title + "…" : title
    }
}
