import SwiftUI

/// Models destination — discover local MLX models, show them, select the active
/// one. Minimal-real per Session 1: no download, no deletion, nothing more.
struct ModelsView: View {
    @Environment(\.theme) private var theme
    @State private var vm: ModelsViewModel

    init(manager: ModelManager) {
        _vm = State(initialValue: ModelsViewModel(manager: manager))
    }

    var body: some View {
        ZStack {
            theme.canopyWash.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    if vm.models.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.models) { model in
                            ModelRow(model: model, isActive: vm.isActive(model)) {
                                vm.select(model)
                            }
                        }
                    }
                }
                .padding(Space.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem {
                Button { vm.rescan() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isScanning)
                .help("Rescan for local models")
            }
        }
        .onAppear { vm.onAppear() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Models")
                .font(ChameleonType.display)
                .foregroundStyle(theme.textPrimary)
            Text("Local MLX models · select the active engine model")
                .font(ChameleonType.callout)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("No MLX models found")
                .font(ChameleonType.headline)
                .foregroundStyle(theme.textPrimary)
            Text("Add a model folder (config.json + *.safetensors + tokenizer) under:")
                .font(ChameleonType.caption)
                .foregroundStyle(theme.textSecondary)
            Text(vm.storePath)
                .font(ChameleonType.monoSmall)
                .foregroundStyle(theme.textTertiary)
                .textSelection(.enabled)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .membraneSurface(cornerRadius: Radius.lg, elevation: .low)
    }
}
