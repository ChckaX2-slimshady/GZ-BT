import Observation

/// Presentation state for the Models destination. Wraps `ModelManager` (Services)
/// so the view never touches discovery internals or the filesystem, and never
/// references visual tokens.
@MainActor
@Observable
final class ModelsViewModel {
    private let manager: ModelManager

    init(manager: ModelManager) {
        self.manager = manager
    }

    var models: [DiscoveredModel] { manager.models }
    var isScanning: Bool { manager.isScanning }
    var storePath: String { ModelManager.modelsRoot.path(percentEncoded: false) }

    func onAppear() {
        if manager.models.isEmpty { manager.scan() }
    }

    func rescan() { manager.scan() }

    func isActive(_ model: DiscoveredModel) -> Bool { manager.activeModelID == model.id }

    func select(_ model: DiscoveredModel) { manager.activeModelID = model.id }
}
