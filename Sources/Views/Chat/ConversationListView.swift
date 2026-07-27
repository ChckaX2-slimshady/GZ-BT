import SwiftUI

/// The persistence proof surface (§4.7): every stored conversation, with title,
/// relative timestamp and message count. New / open / delete — no redesign.
///
/// Every visual value is a DesignSystem token; the layer table forbids hardcoded
/// colors, spacing and radii.
struct ConversationListView: View {
    @Environment(\.theme) private var theme

    let store: ConversationStore
    let currentID: UUID?
    let onOpen: (Conversation) -> Void
    let onNew: () -> Void
    let onDelete: (Conversation) -> Void

    @State private var pendingDeletion: Conversation?

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.conversations.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(theme.surfaceBase.opacity(0.55))
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion { onDelete(pendingDeletion) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletion.map { "“\($0.title)” and its messages will be removed." } ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Text("Conversations")
                .font(ChameleonType.caption)
                .foregroundStyle(theme.textTertiary)
            Spacer(minLength: Space.sm)
            Button(action: onNew) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accentPrimary)
            }
            .buttonStyle(.plain)
            .help("New conversation")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.8) }
    }

    private var emptyState: some View {
        VStack(spacing: Space.xs) {
            Text("No conversations yet")
                .font(ChameleonType.caption)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Space.xs) {
                ForEach(store.conversations) { conversation in
                    row(conversation)
                }
            }
            .padding(Space.sm)
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let isCurrent = conversation.id == currentID
        return Button {
            onOpen(conversation)
        } label: {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(conversation.title)
                    .font(ChameleonType.callout)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: Space.xs) {
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(ChameleonType.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                    Text("·")
                        .font(ChameleonType.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                    Text("\(conversation.messageCount) msg")
                        .font(ChameleonType.monoSmall)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.md)
            .membraneSurface(cornerRadius: Radius.md, elevation: isCurrent ? .medium : .low)
            .overlay(alignment: .leading) {
                if isCurrent {
                    Rectangle()
                        .fill(theme.accentPrimary)
                        .frame(width: 2)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) { pendingDeletion = conversation }
        }
    }
}
