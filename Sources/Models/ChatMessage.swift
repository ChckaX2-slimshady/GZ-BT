import Foundation

/// A message shown in the Chat view. Presentation-facing domain model.
///
/// `id` is injectable so a message restored from the store keeps its persisted
/// identity instead of being reissued a fresh one on every launch.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }

    let id: UUID
    let role: Role
    var text: String
    var status: MessageStatus

    /// Retained as the view-facing spelling — `ChatView`, `ChatMessageRow` and the
    /// Session-1 tests all read it — but now derived from the persisted status so
    /// there is a single source of truth.
    var isStreaming: Bool { status == .streaming }

    init(id: UUID = UUID(), role: Role, text: String, status: MessageStatus = .complete) {
        self.id = id
        self.role = role
        self.text = text
        self.status = status
    }

    /// Restore a stored row for display. `system`/`tool` rows have no Session-2 UI,
    /// so they are dropped rather than rendered as something they are not.
    init?(_ persisted: PersistedMessage) {
        let role: Role
        switch persisted.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .system, .tool: return nil
        }
        // A row still marked `streaming` at load time is a crash artifact the launch
        // sweep has already reclaimed; never render it as live.
        let status: MessageStatus = persisted.status == .streaming ? .failed : persisted.status

        // Tokens are buffered in memory and written once at completion, so a process
        // killed mid-stream leaves an empty row. Say so rather than rendering an
        // unexplained empty turn.
        let text = persisted.content.isEmpty && (status == .failed || status == .cancelled)
            ? "⚠︎ Interrupted before a reply was generated."
            : persisted.content

        self.init(id: persisted.id, role: role, text: text, status: status)
    }
}
