import Foundation

/// Storage-facing role. Wider than `ChatMessage.Role` on purpose: the schema
/// reserves `system` and `tool` for later sessions, so those rows never need a
/// migration when they arrive.
enum MessageRole: String, Equatable, Sendable {
    case user, assistant, system, tool
}

/// Lifecycle of a single message row.
///
/// `streaming` is a *durable* state, not a transient one: a row left in it is
/// how a crash mid-generation is detected on the next launch (§4.5 step 6).
enum MessageStatus: String, Equatable, Sendable {
    case complete, streaming, failed, cancelled
}

/// A message as stored. Kept separate from `ChatMessage` (the presentation type)
/// rather than contorting the domain model, per §4.1.
struct PersistedMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    var role: MessageRole
    var content: String
    var createdAt: Date
    /// Monotonic within a conversation. Ordering key — *not* `createdAt`, because
    /// two messages can share a sub-millisecond timestamp.
    var sequence: Int
    var status: MessageStatus
}
