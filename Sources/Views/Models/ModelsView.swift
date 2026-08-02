import SwiftUI

/// Models destination — download models by repo id, show what is installed, select
/// the active one, and delete. No new navigation destination (§4.7).
struct ModelsView: View {
    @Environment(\.theme) private var theme
    @State private var vm: ModelsViewModel

    init(manager: ModelManager, downloader: ModelDownloader, engine: any InferenceEngine) {
        _vm = State(initialValue: ModelsViewModel(
            manager: manager, downloader: downloader, engine: engine))
    }

    var body: some View {
        ZStack {
            theme.canopyWash.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    downloadCard
                    if vm.models.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.models) { model in
                            ModelRow(
                                model: model,
                                isActive: vm.isActive(model),
                                onSelect: { vm.select(model) },
                                onDelete: { vm.requestDeletion(of: model) })
                        }
                    }
                    storeFooter
                }
                .padding(Space.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem {
                Button { Task { await vm.rescan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isScanning)
                .help("Rescan for local models")
            }
        }
        .task { await vm.onAppear() }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { vm.pendingDeletion != nil },
                set: { if !$0 { vm.cancelDeletion() } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await vm.confirmDeletion() } }
            Button("Cancel", role: .cancel) { vm.cancelDeletion() }
        } message: {
            if let model = vm.pendingDeletion {
                Text("Frees \(ByteFormat.string(model.sizeBytes)). "
                     + "Chat history that used this model is kept.")
            }
        }
    }

    private var deletionTitle: String {
        vm.pendingDeletion.map { "Delete \($0.name)?" } ?? "Delete model?"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Models")
                .font(ChameleonType.display)
                .foregroundStyle(theme.textPrimary)
            Text("Download MLX models by repo id · select the active engine model")
                .font(ChameleonType.callout)
                .foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: - Download

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Add a model")
                .font(ChameleonType.headline)
                .foregroundStyle(theme.textPrimary)

            HStack(spacing: Space.sm) {
                TextField("org/model-name", text: $vm.repoIDInput)
                    .textFieldStyle(.plain)
                    .font(ChameleonType.mono)
                    .foregroundStyle(theme.textPrimary)
                    .padding(Space.sm)
                    .background(theme.surfaceInset, in: RoundedRectangle(
                        cornerRadius: Radius.sm, style: .continuous))
                    .disabled(vm.isDownloading)
                    .onSubmit { if vm.canStartDownload { vm.startDownload() } }
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif

                Button("Download") { vm.startDownload() }
                    .disabled(!vm.canStartDownload)
            }

            starterList

            #if os(iOS)
            // The transfer dies if the app is backgrounded: `useBackgroundSession: true`
            // aborts the process, so S3 ships foreground-only.
            Label("Keep GZ-BT open during the download.", systemImage: "exclamationmark.triangle")
                .font(ChameleonType.caption)
                .foregroundStyle(theme.warning)
            #endif

            downloadStatus
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .membraneSurface(cornerRadius: Radius.lg, elevation: .medium)
    }

    private var starterList: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Known-good")
                .font(ChameleonType.caption)
                .foregroundStyle(theme.textTertiary)
            ForEach(ModelsViewModel.starterRepoIDs, id: \.self) { repoID in
                Button { vm.startDownload(repoID: repoID) } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12))
                        Text(repoID)
                            .font(ChameleonType.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(theme.accentSecondary)
                }
                .buttonStyle(.plain)
                .disabled(vm.isDownloading)
            }
        }
    }

    @ViewBuilder
    private var downloadStatus: some View {
        switch vm.downloadState {
        case .idle:
            EmptyView()

        case .preflighting(let repoID):
            statusLine("Checking \(repoID)…", systemImage: "magnifyingglass",
                       tint: theme.textSecondary)

        case .downloading(let repoID):
            VStack(alignment: .leading, spacing: Space.xs) {
                ProgressView(value: vm.downloadProgress.fractionCompleted)
                    .tint(theme.accentPrimary)
                HStack {
                    Text(repoID)
                        .font(ChameleonType.monoSmall)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.sm)
                    if let plan = vm.downloadPlan {
                        // Percent + files, never a byte counter: HubApi's progress is
                        // file-weighted, so a derived byte figure would be fiction.
                        Text("\(vm.downloadPercent)% · \(vm.completedFiles)/\(vm.totalFiles) files "
                             + "· \(ByteFormat.string(plan.totalBytes))")
                            .font(ChameleonType.monoSmall)
                            .foregroundStyle(theme.textTertiary)
                    }
                    Button("Cancel") { vm.cancelDownload() }
                        .font(ChameleonType.caption)
                }
            }

        case .installing(let repoID):
            statusLine("Installing \(repoID)…", systemImage: "shippingbox",
                       tint: theme.textSecondary)

        case .finished(_, let directoryName):
            statusLine("Installed \(directoryName).", systemImage: "checkmark.circle.fill",
                       tint: theme.accentPrimary)

        case .failed(_, let message):
            VStack(alignment: .leading, spacing: Space.xs) {
                statusLine(message, systemImage: "exclamationmark.triangle.fill",
                           tint: theme.warning)
                Button("Dismiss") { vm.dismissDownloadOutcome() }
                    .font(ChameleonType.caption)
            }
        }
    }

    private func statusLine(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(ChameleonType.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Store

    private var storeFooter: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("\(vm.models.count) installed · \(ByteFormat.string(vm.storeTotalBytes))")
                    .font(ChameleonType.caption)
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: Space.sm)
                if let available = vm.availableBytes {
                    Text("\(ByteFormat.string(available)) free")
                        .font(ChameleonType.caption)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Text(vm.storePath)
                .font(ChameleonType.monoSmall)
                .foregroundStyle(theme.textTertiary)
                .textSelection(.enabled)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .membraneSurface(cornerRadius: Radius.md, elevation: .low)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("No MLX models found")
                .font(ChameleonType.headline)
                .foregroundStyle(theme.textPrimary)
            Text("Download one above, or add a model folder "
                 + "(config.json + *.safetensors + tokenizer) under the path below.")
                .font(ChameleonType.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .membraneSurface(cornerRadius: Radius.lg, elevation: .low)
    }
}
