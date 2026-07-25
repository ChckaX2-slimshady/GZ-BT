import Foundation

/// A model that `ModelManager` has resolved to a concrete on-disk location.
///
/// The inference engine receives one of these — it never scans the filesystem
/// itself. Discovery/selection is the Services layer's job.
struct ResolvedModel: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let contextLength: Int?

    init(id: String, name: String, url: URL, contextLength: Int? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.contextLength = contextLength
    }
}
