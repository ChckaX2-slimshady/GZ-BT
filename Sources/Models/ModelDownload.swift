import Foundation

/// A `Sendable` snapshot of a `Foundation.Progress`.
///
/// `HubApi.snapshot`'s `progressHandler` is `@escaping (Progress) -> Void` — **not**
/// `@Sendable` — and `Progress` is not `Sendable`. Under
/// `SWIFT_STRICT_CONCURRENCY: complete` the handler is therefore built and invoked
/// only in a non-isolated context, where the live `Progress` is converted to one of
/// these and discarded. `Progress` itself never crosses an isolation boundary.
struct ModelDownloadProgress: Sendable, Equatable {
    var fractionCompleted: Double
    var completedUnitCount: Int64
    var totalUnitCount: Int64

    static let zero = ModelDownloadProgress(
        fractionCompleted: 0, completedUnitCount: 0, totalUnitCount: 0)
}

/// The result of the metadata-only preflight (§4.2 step 1).
///
/// Produced by `HubApi.getFilenames` (one GET) + `HubApi.getFileMetadata` (one HEAD
/// per file). Neither downloads content, which is what lets the free-space check and
/// the collision check run *before* any byte is transferred.
struct ModelDownloadPlan: Sendable, Equatable {
    let repoID: String
    /// Directory name in the store: the last path component of the repo id
    /// (ratified decision #5).
    let directoryName: String
    /// The commit SHA the Hub resolved, not the branch that was asked for.
    let revision: String
    let files: [ModelManifest.Entry]
    let totalBytes: Int64

    /// Bytes that must be free before the download is allowed to start.
    ///
    /// `2 ×` because the transfer is not a single write: `HubClient` stores the body
    /// into its cache blob and then **copies** it to the materialized snapshot
    /// directory (S3_RECON §3.3), so both exist at once. Ratified decision #6 keeps
    /// the cache, so this doubling is accepted rather than engineered away. The move
    /// from there into the store is a same-volume rename and costs nothing further.
    var requiredBytes: Int64 { totalBytes * 2 + headroomBytes }

    /// Headroom above the download itself, so a model can never be the thing that
    /// fills the volume. 1 GB floor, or 10% of the transfer for models large enough
    /// to need more. A number chosen and recorded (DECISIONS #37) rather than an
    /// unexplained constant.
    static let headroomFloor: Int64 = 1_000_000_000

    var headroomBytes: Int64 { max(Self.headroomFloor, totalBytes / 10) }
}

/// What is currently sitting at the target directory in the store (§4.4).
enum ModelStoreOccupancy: Sendable, Equatable {
    /// Nothing there — proceed.
    case absent
    /// A GZ-BT manifest whose `repo_id` matches: the same model.
    case sameRepo(repoID: String)
    /// A GZ-BT manifest naming a different repo: a genuine collision.
    case differentRepo(existing: String)
    /// A directory with **no** GZ-BT manifest — the legacy case. Discovery treats
    /// manifest-absent as "assume complete", so this is an unknown occupant and a
    /// download must refuse rather than overwrite something it cannot account for.
    case unknownOccupant
}

enum ModelDownloadError: LocalizedError, Equatable {
    case invalidRepoID(String)
    case insufficientSpace(required: Int64, available: Int64)
    case collision(existing: String, incoming: String)
    case unknownOccupant(directory: String)
    case occupied(repoID: String)
    case verificationFailed(directory: String, reason: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRepoID(let id):
            "\"\(id)\" is not a HuggingFace repo id. Expected the form org/name."
        case .insufficientSpace(let required, let available):
            """
            Not enough free space. This model needs \(ByteFormat.string(required)) \
            (download plus its transfer cache and headroom) but only \
            \(ByteFormat.string(available)) is available.
            """
        case .collision(let existing, let incoming):
            """
            \"\(incoming)\" would be stored under the same folder name as \
            \"\(existing)\", which is already installed. Both repos end in the same \
            name. Delete the installed one first — renaming would break the active \
            model selection and existing telemetry history.
            """
        case .unknownOccupant(let directory):
            """
            A folder named \"\(directory)\" already exists in the model store but was \
            not downloaded by GZ-BT, so its contents cannot be verified. Delete it \
            first if you want to replace it.
            """
        case .occupied(let repoID):
            "\(repoID) is already installed. Delete it first to re-download."
        case .verificationFailed(let directory, let reason):
            "The download completed but \"\(directory)\" is not a usable model: \(reason)"
        case .cancelled:
            "Download cancelled."
        }
    }
}

/// The downloader's observable state. One download at a time — S3 ships repo-id
/// entry, not a queue (§3 puts queues out of scope).
/// Live progress is a **separate** observable property on `ModelDownloader`, not a
/// payload here: the progress pump and the lifecycle transitions are written by two
/// different tasks, and folding them into one value makes them race.
enum ModelDownloadState: Sendable, Equatable {
    case idle
    case preflighting(repoID: String)
    case downloading(repoID: String)
    case installing(repoID: String)
    case finished(repoID: String, directoryName: String)
    case failed(repoID: String, message: String)

    var isBusy: Bool {
        switch self {
        case .preflighting, .downloading, .installing: true
        case .idle, .finished, .failed: false
        }
    }

    /// Only a running transfer can be cancelled; preflight is a handful of HEADs.
    var isCancellable: Bool {
        if case .downloading = self { return true }
        return false
    }

    var repoID: String? {
        switch self {
        case .idle: nil
        case .preflighting(let id), .downloading(let id), .installing(let id): id
        case .finished(let id, _): id
        case .failed(let id, _): id
        }
    }
}
