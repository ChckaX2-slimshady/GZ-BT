import Foundation
import Observation

/// The app-facing download surface, and the `@MainActor` façade over
/// `ModelDownloadEngine` — the same split as `ConversationStore` over
/// `ConversationDatabase`.
///
/// It holds **no** unsafe state: no `HubApi`, no `Progress`, no file handles. The
/// engine owns those inside an actor, and only `Sendable` values
/// (`ModelDownloadProgress`, `ModelDownloadPlan`, `URL`) cross back. That is what
/// lets progress reach the UI under `SWIFT_STRICT_CONCURRENCY: complete` without an
/// isolation workaround.
///
/// Layer: **Services**. `ModelsViewModel` is its only consumer.
@MainActor
@Observable
final class ModelDownloader {
    private(set) var state: ModelDownloadState = .idle
    /// Live transfer progress. Separate from `state` so the progress pump and the
    /// lifecycle transitions never race each other.
    private(set) var progress: ModelDownloadProgress = .zero
    /// The resolved plan for the transfer in flight — file count and total bytes,
    /// known before the first byte moves.
    private(set) var plan: ModelDownloadPlan?
    /// Free space on the store's volume, refreshed on demand.
    private(set) var availableBytes: Int64?

    private let engine: ModelDownloadEngine
    private let manager: ModelManager
    private var task: Task<Void, Never>?

    init(manager: ModelManager) {
        self.manager = manager
        self.engine = ModelDownloadEngine(storeRoot: manager.root)
    }

    var isBusy: Bool { state.isBusy }

    /// Files finished so far, and how many there are in total.
    ///
    /// **There is deliberately no `transferredBytes`.** `HubApi`'s snapshot `Progress`
    /// counts *files* — `Progress(totalUnitCount: filenames.count)` with one pending
    /// unit each (`HubApi.swift:942–944`) — so `fractionCompleted` is a file-weighted
    /// figure, not a byte-weighted one. Multiplying it by the preflighted total
    /// produces a number that looks like bytes and is not: measured on this repo, "1
    /// of 6 files complete" renders as 82.6 MB whether the completed file was
    /// `config.json` (2,939 B) or `model.safetensors` (484,049,216 B) — the two
    /// differ by five orders of magnitude and display identically. Since
    /// `getFilenames` returns `Array(Set<String>)` the order is not even stable
    /// between runs, so the error is not a consistent bias. A fabricated byte count
    /// shown to the user is exactly what Gotcha #5 forbids, so the UI reports
    /// completed files and a percentage, and the total size separately.
    var completedFiles: Int { Int(progress.completedUnitCount) }
    var totalFiles: Int { max(Int(progress.totalUnitCount), plan?.files.count ?? 0) }

    func refreshAvailableBytes() async {
        availableBytes = await engine.availableBytes()
    }

    /// Start a download. Ignored if one is already running — S3 ships one at a time;
    /// a queue is out of scope (§3).
    func download(repoID: String) {
        guard !state.isBusy else { return }
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        progress = .zero
        plan = nil
        state = .preflighting(repoID: trimmed)

        let (stream, continuation) = AsyncStream<ModelDownloadProgress>.makeStream()

        task = Task { [engine, manager] in
            // The pump republishes engine progress onto the main actor in order.
            // `AsyncStream` is what preserves that order; a `Task { @MainActor }` per
            // callback would not.
            let pump = Task { @MainActor [weak self] in
                for await value in stream {
                    self?.progress = value
                }
            }
            defer { pump.cancel() }

            do {
                let resolved = try await engine.preflight(repoID: trimmed)
                self.plan = resolved
                self.availableBytes = await engine.availableBytes()
                self.state = .downloading(repoID: trimmed)

                let destination = try await engine.download(plan: resolved) { value in
                    continuation.yield(value)
                }
                continuation.finish()

                self.state = .installing(repoID: trimmed)
                await manager.scan()
                await self.refreshAvailableBytes()
                self.state = .finished(
                    repoID: trimmed, directoryName: destination.lastPathComponent)
            } catch is CancellationError {
                continuation.finish()
                self.state = .failed(
                    repoID: trimmed,
                    message: ModelDownloadError.cancelled.localizedDescription)
            } catch {
                continuation.finish()
                // Reported, not swallowed: an interrupted transfer must read as
                // interrupted rather than as a generic network error (§4.7).
                Log.models.error(
                    "download failed repo=\(trimmed, privacy: .public) error=\(String(describing: error), privacy: .public)")
                self.state = .failed(
                    repoID: trimmed,
                    message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    /// Cancel the transfer in flight.
    ///
    /// `HubApi` has no cancel handle of its own — cancellation is Swift task
    /// cancellation only — so this cancels the task that owns the snapshot, and the
    /// engine treats `snapshot`'s cancelled return as a failure rather than a result.
    func cancel() {
        task?.cancel()
    }

    /// Clear a terminal state so the UI returns to accepting input.
    func dismissOutcome() {
        guard !state.isBusy else { return }
        state = .idle
        plan = nil
        progress = .zero
    }
}
