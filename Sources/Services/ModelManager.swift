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
        didSet { UserDefaults.standard.set(activeModelID, forKey: Self.activeKey) }
    }

    private static let activeKey = "models.activeModelID"

    static var modelsRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "GZ-BT/Models", directoryHint: .isDirectory)
    }

    init() {
        activeModelID = UserDefaults.standard.string(forKey: Self.activeKey)
    }

    var activeModel: DiscoveredModel? {
        guard let activeModelID else { return nil }
        return models.first { $0.id == activeModelID }
    }

    /// Hand a discovered model to the engine as a resolved location.
    func resolve(_ model: DiscoveredModel) -> ResolvedModel {
        ResolvedModel(id: model.id, name: model.name, url: model.url, contextLength: model.contextLength)
    }

    func scan() {
        isScanning = true
        defer { isScanning = false }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.modelsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            models = []
            reconcileSelection()
            return
        }

        models = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(Self.inspect)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        reconcileSelection()
    }

    private func reconcileSelection() {
        if let id = activeModelID, models.contains(where: { $0.id == id }) { return }
        activeModelID = models.count == 1 ? models.first?.id : activeModelID
        if let id = activeModelID, !models.contains(where: { $0.id == id }) {
            activeModelID = models.first?.id
        }
    }

    /// A directory qualifies as an MLX model if it has config.json, a
    /// `.safetensors` weight file, and a tokenizer.
    private static func inspect(_ dir: URL) -> DiscoveredModel? {
        let fm = FileManager.default
        let configURL = dir.appending(path: "config.json")
        guard fm.fileExists(atPath: configURL.path),
              let names = try? fm.contentsOfDirectory(atPath: dir.path),
              names.contains(where: { $0.hasSuffix(".safetensors") }),
              names.contains("tokenizer.json") || names.contains("tokenizer.model")
        else { return nil }

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

    private static func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
