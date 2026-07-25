import SwiftUI

/// One chat message as a membrane bubble; user trails right, assistant leads left.
struct ChatMessageRow: View {
    @Environment(\.theme) private var theme
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: Space.xl) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Text(isUser ? "You" : "HATS")
                        .font(ChameleonType.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                    if message.isStreaming { StreamingIndicatorView() }
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(ChameleonType.body)
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .padding(Space.md)
                        .membraneSurface(cornerRadius: Radius.lg, elevation: isUser ? .medium : .low)
                }
            }

            if !isUser { Spacer(minLength: Space.xl) }
        }
    }
}
