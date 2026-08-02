import Foundation
import Observation

/// Owns model discovery and selection. This is the **only** type that scans the
/// filesystem for models — inference engines receive a resolved URL and never
/// look at disk themselves.
///
/// Discovery root is GZ-BT's own store:
///   macOS (dev, non-sandboxed) → ~/Library/Application Support/GZ-BT/Models
///   iOS → app-sandbox Application Support/GZ-BT/Models
@MainActor
@Observable
final class ModelManager {
    private(set) var models: [DiscoveredModel] = []
    private(set) var isScanning = false

    var activeModelID: String? {
        didSet {
            guard persistsSelection else { return }
            UserDefaults.standard.set(activeModelID, forKey: Self.activeKey)
        }
    }

    private static let activeKey = "models.activeModelID"

    /// The real store location. Still a computed static — it is what
    /// `ModelsViewModel` displays and what the exit-criteria commands `ls`.
    static var modelsRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "GZ-BT/Models", directoryHint: .isDirectory)
    }

    /// This manager's store root.
    ///
    /// Injectable for exactly the reason `ConversationStore.init(url:)` is: without a
    /// seat here, every downloader/manifest/collision test would write into the real
    /// model store. `GZBT_STORE_PATH` is **not** the mechanism — it gates the
    /// conversation database only (`AppEnvironment.swift:34`) and is not extended here.
    nonisolated let root: URL

    /// An injected root is a test/ephemeral store, so selection is not persisted to
    /// the shared `UserDefaults` key — otherwise a test run would silently repoint
    /// the user's active model.
    private let persistsSelection: Bool

    init(root: URL? = nil) {
        self.root = root ?? Self.modelsRoot
        self.persistsSelection = (root == nil)
        self.activeModelID = persistsSelection
            ? UserDefaults.standard.string(forKey: Self.activeKey)
            : nil
    }

    var activeModel: DiscoveredModel? {
        guard let activeModelID else { return nil }
        return models.first { $0.id == activeModelID }
    }

    /// Hand a discovered model to the engine as a resolved location.
    func resolve(_ model: DiscoveredModel) -> ResolvedModel {
        ResolvedModel(id: model.id, name: model.name, url: model.url, contextLength: model.contextLength)
    }

    /// Rescan the store.
    ///
    /// `async` because `directorySize` walks every file of every candidate directory
    /// with a `FileManager.enumerator`. Held on the main actor that is one full tree
    /// walk per model per scan, and S3 makes N models one tap away — so the walk runs
    /// off the main actor and `isScanning` becomes observably `true` while it does
    /// (E9). This is a forced consequence of adding downloads, not opportunism.
    func scan() async {
        isScanning = true
        defer { isScanning = false }

        let root = self.root
        models = await Task.detached { Self.discover(in: root) }.value
        reconcileSelection()
    }

    /// Remove a model's directory from the store.
    ///
    /// **The caller must `unload()` the engine first** — see `ModelsViewModel.delete`.
    /// Telemetry rows are deliberately left alone: `message_telemetry.model_id` is a
    /// plain string with no foreign key, and history outliving the model is what makes
    /// Spectre's comparative work possible.
    func delete(_ model: DiscoveredModel) async throws {
        try FileManager.default.removeItem(at: model.url)
        await scan()
    }

    private func reconcileSelection() {
        if let id = activeModelID, models.contains(where: { $0.id == id }) { return }
        activeModelID = models.count == 1 ? models.first?.id : activeModelID
        if let id = activeModelID, !models.contains(where: { $0.id == id }) {
            activeModelID = models.first?.id
        }
    }

    // MARK: - Discovery (nonisolated: runs off the main actor)

    private nonisolated static func discover(in root: URL) -> [DiscoveredModel] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(Self.inspect)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The discovery predicate, on its own so there is exactly one definition of
    /// "this directory is a usable MLX model".
    ///
    /// `ModelDownloadEngine` verifies a freshly-moved directory against **this**
    /// function before writing the manifest (§4.2). That is what makes the download
    /// glob safe: `MLXLMCommon`'s `["*.safetensors","*.json","*.jinja"]` excludes
    /// `tokenizer.model`, and if a repo ever needed that file the miss surfaces here
    /// as a loud failure instead of an invisible model.
    ///
    /// A directory qualifies iff it has config.json, a `.safetensors` weight file,
    /// and a tokenizer.
    nonisolated static func isUsableModelDirectory(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appending(path: "config.json").path),
              let names = try? fm.contentsOfDirectory(atPath: dir.path),
              names.contains(where: { $0.hasSuffix(".safetensors") }),
              names.contains("tokenizer.json") || names.contains("tokenizer.model")
        else { return false }
        return true
    }

    /// Names the first unmet requirement, for a specific failure message.
    nonisolated static func missingRequirement(in dir: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appending(path: "config.json").path) else {
            return "no config.json"
        }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return "directory is unreadable"
        }
        guard names.contains(where: { $0.hasSuffix(".safetensors") }) else {
            return "no .safetensors weight file"
        }
        guard names.contains("tokenizer.json") || names.contains("tokenizer.model") else {
            return "no tokenizer.json or tokenizer.model"
        }
        return nil
    }

    private nonisolated static func inspect(_ dir: URL) -> DiscoveredModel? {
        guard isUsableModelDirectory(dir) else { return nil }

        let configURL = dir.appending(path: "config.json")
        var architecture: String?
        var quantization: String?
        var contextLength: Int?
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            architecture = json["model_type"] as? String
            if let q = json["quantization"] as? [String: Any], let bits = q["bits"] as? Int {
                quantization = "\(bits)-bit"
            }
            contextLength = (json["max_position_embeddings"] as? Int)
                ?? ((json["text_config"] as? [String: Any])?["max_position_embeddings"] as? Int)
        }

        return DiscoveredModel(
            id: dir.lastPathComponent,
            name: dir.lastPathComponent,
            url: dir,
            architecture: architecture,
            quantization: quantization,
            sizeBytes: directorySize(dir),
            contextLength: contextLength)
    }

    nonisolated static func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
