import SwiftUI

/// The Session-1 vertical slice: pick the active MLX model, type a prompt, watch
/// a streamed response with a live streaming indicator and Seam-1 metrics — all
/// in the Veiled Chameleon language.
struct ChatView: View {
    @Environment(\.theme) private var theme
    @Bindable var vm: ChatViewModel

    var body: some View {
        ZStack {
            theme.canopyWash.ignoresSafeArea()
            VStack(spacing: 0) {
                ChatMetricsBar(metrics: vm.metrics, modelName: vm.activeModelName, status: vm.status)
                transcript
                inputBar
            }
        }
        .navigationTitle("Chat")
        .task { vm.start() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Space.md) {
                    if vm.messages.isEmpty { emptyState.padding(.top, Space.xxxl) }
                    ForEach(vm.messages) { message in
                        ChatMessageRow(message: message).id(message.id)
                    }
                }
                .padding(Space.lg)
            }
            .onChange(of: vm.messages.last?.text) {
                guard let last = vm.messages.last else { return }
                withAnimation(Motion.quick) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.accentPrimary)
                .padding(.bottom, Space.xs)
            Text("On-device chat")
                .font(ChameleonType.headline)
                .foregroundStyle(theme.textPrimary)
            Text(vm.activeModelName.map { "Model · \($0)" } ?? "Select a model in the Models tab")
                .font(ChameleonType.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var inputBar: some View {
        HStack(spacing: Space.sm) {
            TextField("Message", text: $vm.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(ChameleonType.body)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1...5)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .membraneSurface(cornerRadius: Radius.lg, elevation: .low)
                .onSubmit { vm.send() }

            Button {
                if vm.isStreaming { vm.cancel() } else { vm.send() }
            } label: {
                Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: 42, height: 42)
                    .background(vm.isStreaming ? theme.warning : theme.accentPrimary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!vm.isStreaming && !vm.canSend)
            .animation(Motion.micro, value: vm.isStreaming)
        }
        .padding(Space.md)
        .background(theme.surfaceBase.opacity(0.55))
        .overlay(alignment: .top) { Rectangle().fill(theme.hairline).frame(height: 0.8) }
    }
}
