import Foundation
import Observation

/// Presentation state for the Models destination. Wraps `ModelManager` and
/// `ModelDownloader` (Services) so the view never touches discovery internals, the
/// filesystem, or `HubApi`, and never references visual tokens.
@MainActor
@Observable
final class ModelsViewModel {
    private let manager: ModelManager
    private let downloader: ModelDownloader
    private let engine: any InferenceEngine

    /// Bound to the repo-id field.
    var repoIDInput: String = ""
    /// The model the user has asked to delete, pending confirmation.
    var pendingDeletion: DiscoveredModel?

    /// Known-good MLX repos, verified against live Hub listings this session: each
    /// one's file set satisfies the discovery predicate. The alternative is asking the
    /// user to type an exact string (§4.7).
    static let starterRepoIDs = [
        "mlx-community/Llama-3.2-1B-Instruct-4bit",
        "mlx-community/Qwen2.5-3B-Instruct-4bit",
        "prism-ml/Ternary-Bonsai-1.7B-mlx-2bit",
    ]

    init(manager: ModelManager, downloader: ModelDownloader, engine: any InferenceEngine) {
        self.manager = manager
        self.downloader = downloader
        self.engine = engine
    }

    // MARK: - Discovery

    var models: [DiscoveredModel] { manager.models }
    var isScanning: Bool { manager.isScanning }
    var storePath: String { manager.root.path(percentEncoded: false) }

    func onAppear() async {
        if manager.models.isEmpty { await manager.scan() }
        await downloader.refreshAvailableBytes()
    }

    func rescan() async { await manager.scan() }

    func isActive(_ model: DiscoveredModel) -> Bool { manager.activeModelID == model.id }

    func select(_ model: DiscoveredModel) { manager.activeModelID = model.id }

    // MARK: - Disk accounting (§4.5)

    var storeTotalBytes: Int64 { manager.models.reduce(0) { $0 + $1.sizeBytes } }
    var availableBytes: Int64? { downloader.availableBytes }

    // MARK: - Download

    var downloadState: ModelDownloadState { downloader.state }
    var downloadProgress: ModelDownloadProgress { downloader.progress }
    var downloadPlan: ModelDownloadPlan? { downloader.plan }
    var isDownloading: Bool { downloader.isBusy }
    var canStartDownload: Bool {
        !downloader.isBusy && !repoIDInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Progress as it can honestly be reported: a percentage and a file count.
    /// See `ModelDownloader.completedFiles` for why there is no byte counter.
    var downloadPercent: Int { Int((downloader.progress.fractionCompleted * 100).rounded()) }
    var completedFiles: Int { downloader.completedFiles }
    var totalFiles: Int { downloader.totalFiles }

    func startDownload() {
        downloader.download(repoID: repoIDInput)
    }

    func startDownload(repoID: String) {
        repoIDInput = repoID
        downloader.download(repoID: repoID)
    }

    func cancelDownload() { downloader.cancel() }

    func dismissDownloadOutcome() { downloader.dismissOutcome() }

    // MARK: - Delete (§4.5)

    /// Deletes a model, unloading the engine first.
    ///
    /// **The unload is forced, not chosen.** `MLXInferenceEngine` keeps `container`
    /// and `loaded` private and `InferenceEngine` exposes no accessor for what is
    /// loaded, so a refuse-if-loaded rule would require adding a read property to the
    /// protocol — which §5 forbids this session. `unload()` is already on the
    /// protocol, so it is called unconditionally.
    ///
    /// What this prevents: MLX keeps weights resident, so `generate()` would keep
    /// working from RAM against a deleted directory while `reconcileSelection()` had
    /// already silently repointed `activeModelID` at a different model — and
    /// `TelemetryHub.lifecycle` reports `.loaded` with no model identity, so nothing
    /// in the app could tell which model produced the output.
    ///
    /// Telemetry rows are **not** deleted. See `ModelManager.delete`.
    func confirmDeletion() async {
        guard let model = pendingDeletion else { return }
        pendingDeletion = nil
        await engine.unload()
        do {
            try await manager.delete(model)
            await downloader.refreshAvailableBytes()
            Log.models.notice(
                "deleted model=\(model.id, privacy: .public) reclaimed=\(model.sizeBytes, privacy: .public)")
        } catch {
            Log.models.error(
                "delete failed model=\(model.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func requestDeletion(of model: DiscoveredModel) { pendingDeletion = model }

    func cancelDeletion() { pendingDeletion = nil }
}
