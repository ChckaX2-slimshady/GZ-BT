import Foundation

/// GZ-BT's own record of a downloaded model, written into the store directory
/// **after** the move and verification succeed (BUILD_SESSION_3 §4.3). Its presence
/// is the completeness signal (ratified decision #7); a partial download never
/// reaches the store, so a directory carrying this file is known-good.
///
/// **The filename is load-bearing and must be matched exactly.** The hand-copied
/// legacy model already contains a `.hfmanifest.json` written by whatever tool
/// originally fetched it — that file is *not* in the HF repo and no `HubApi`
/// download reproduces it (`HubApi` writes `.cache/huggingface/download/*.metadata`
/// sidecars instead). A loose "does it have a manifest?" check would read the legacy
/// directory as complete and invert §4.4's collision asymmetry, so completeness is
/// keyed on `Self.filename` and nothing else.
///
/// Layer: **Models** — inert, `Sendable`, no behaviour beyond coding.
struct ModelManifest: Codable, Sendable, Equatable {
    /// Exact filename. Deliberately distinct from `.hfmanifest.json`.
    static let filename = ".gzbt-model.json"
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// The load-bearing field: what makes collisions detectable (§4.4) and what
    /// preserves the org attribution that the directory name drops.
    let repoID: String
    /// The commit SHA `HubApi` resolved, not the branch name that was requested.
    let revision: String
    let downloadedAt: Date
    let files: [Entry]
    let totalBytes: Int64

    /// What HuggingFace's `ETag` actually is for a given file.
    ///
    /// `HubApi` only verifies content when `isValidSHA256(etag)` holds — i.e. for
    /// LFS files, which in practice is exactly the weight files. For everything
    /// else the ETag is a 40-hex git blob hash and nothing checks it. Naming the
    /// field `sha256` for all files would have put a git blob hash under a false
    /// name; Gotcha #5 aimed at our own artifact.
    enum ETagKind: String, Codable, Sendable {
        case sha256
        case gitBlob = "git-blob"
        case unknown
    }

    struct Entry: Codable, Sendable, Equatable {
        let path: String
        let bytes: Int64
        let etag: String?
        let etagKind: ETagKind

        enum CodingKeys: String, CodingKey {
            case path
            case bytes
            case etag
            case etagKind = "etag_kind"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case repoID = "repo_id"
        case revision
        case downloadedAt = "downloaded_at"
        case files
        case totalBytes = "total_bytes"
    }

    init(
        schemaVersion: Int = ModelManifest.currentSchemaVersion,
        repoID: String,
        revision: String,
        downloadedAt: Date,
        files: [Entry],
        totalBytes: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.repoID = repoID
        self.revision = revision
        self.downloadedAt = downloadedAt
        self.files = files
        self.totalBytes = totalBytes
    }

    // MARK: - Coding

    /// Epoch seconds, matching §4.3's example. Not `Date`'s default 2001 reference
    /// epoch — the legacy `.hfmanifest.json` uses that and it reads as a wrong year.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Reads the manifest from a model directory. `nil` means *absent* — which
    /// §4.3 defines as "legacy, assume complete" — and is not an error.
    static func read(from directory: URL) -> ModelManifest? {
        let url = directory.appending(path: filename, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(ModelManifest.self, from: data)
    }

    func write(to directory: URL) throws {
        let url = directory.appending(path: Self.filename, directoryHint: .notDirectory)
        try Self.encoder().encode(self).write(to: url, options: .atomic)
    }
}
