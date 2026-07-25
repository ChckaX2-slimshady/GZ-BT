import Foundation

/// A message shown in the Chat view. Presentation-facing domain model.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var isStreaming: Bool = false
}
