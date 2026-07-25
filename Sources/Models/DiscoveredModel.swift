import Foundation

/// A local MLX model directory discovered by `ModelManager`. Pure data — the
/// display layer reads it, and it resolves to a `ResolvedModel` for the engine.
struct DiscoveredModel: Sendable, Identifiable, Hashable {
    let id: String            // directory name (stable)
    let name: String
    let url: URL
    let architecture: String? // config.json "model_type"
    let quantization: String? // e.g. "2-bit"
    let sizeBytes: Int64
    let contextLength: Int?   // config.json "max_position_embeddings"
}
