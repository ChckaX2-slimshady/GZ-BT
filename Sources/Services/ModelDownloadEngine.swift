import Foundation
import Hub

/// Owns `HubApi` and every filesystem effect of a model download.
///
/// An `actor`, for the same reason `ConversationDatabase` is one: it holds the
/// unsafe thing and nothing unsafe escapes. Here the unsafe thing is
/// `HubApi.snapshot`'s `progressHandler` — `@escaping (Progress) -> Void`, **not**
/// `@Sendable`, taking a non-`Sendable` `Progress`. Passing such a closure *into*
/// this non-isolated API from `@MainActor` code does not compile under
/// `SWIFT_STRICT_CONCURRENCY: complete`, so the handler is built inside a
/// `nonisolated` function, converts `Progress` to a `Sendable`
/// `ModelDownloadProgress` on the spot, and lets the `Progress` die there.
///
/// Its `@MainActor` façade is `ModelDownloader`, which holds no unsafe state.
///
/// Layer: **Services**. Nothing in `Inference/` may reference this type (§5), and
/// this type never loads or runs a model — it puts files on disk and hands back a
/// local URL.
actor ModelDownloadEngine {

    /// The glob passed to `HubApi.snapshot`.
    ///
    /// Chosen deliberately (§4.2 step 3 does not fix it) to match what the substrate
    /// itself uses — `MLXLMCommon/Load.swift:22–39` downloads with exactly this set —
    /// so a downloaded model is byte-for-byte the file set MLX expects. It excludes
    /// `tokenizer.model`; verified against all three starter repos, every one ships
    /// `tokenizer.json`, and `ModelManager.isUsableModelDirectory` turns any future
    /// miss into a loud failure rather than an invisible model.
    static let matchingGlobs = ["*.safetensors", "*.json", "*.jinja"]

    private let hub: HubApi
    private let storeRoot: URL
    private let downloadBase: URL

    /// `downloadBase` sits beside the store (`…/GZ-BT/Downloads`) rather than at
    /// `HubApi`'s default `Documents/huggingface`, so the completion move is a
    /// same-volume rename and not a 473 MB copy (ratified decision #6). It is
    /// deliberately *outside* `Models/` — `ModelManager.scan()` looks at the
    /// immediate children of the store, and a partially-materialized repo appearing
    /// there would be offered as loadable.
    init(storeRoot: URL, downloadBase: URL? = nil) {
        self.storeRoot = storeRoot
        self.downloadBase = downloadBase
            ?? storeRoot.deletingLastPathComponent()
                .appending(path: "Downloads", directoryHint: .isDirectory)
        // Never `useBackgroundSession: true` — it aborts the process with an
        // uncatchable NSGenericException (S3_RECON §3.1a), so no do/catch contains it.
        self.hub = HubApi(downloadBase: self.downloadBase, useBackgroundSession: false)
    }

    // MARK: - Preflight (§4.2 step 1) — metadata only, downloads nothing

    /// Resolves a repo id to its file set, total byte size, and resolved commit SHA
    /// **without transferring content**: one GET for the sibling list, one HEAD per
    /// file. This is what lets the free-space and collision checks run before any
    /// byte moves.
    func preflight(repoID rawRepoID: String) async throws -> ModelDownloadPlan {
        let repoID = rawRepoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = repoID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ModelDownloadError.invalidRepoID(repoID)
        }

        let names = try await hub.getFilenames(from: repoID, matching: Self.matchingGlobs)
        guard !names.isEmpty else {
            throw ModelDownloadError.verificationFailed(
                directory: repoID, reason: "the repo has no files matching an MLX model")
        }

        var files: [ModelManifest.Entry] = []
        var total: Int64 = 0
        var revisions = Set<String>()

        // Resolved one filename at a time, using the name itself as the glob.
        //
        // `FileMetadata` carries no filename, and the two calls cannot be zipped by
        // index: `getFilenames` returns `Array(Set<String>)` (HubApi.swift:535), whose
        // order is not stable between calls, and for an LFS file `location` points at
        // a content-addressed CDN object whose last component is a hash, not the name.
        // Querying per name is a few extra small GETs and makes the pairing exact.
        for name in names.sorted() {
            let metas = try await hub.getFileMetadata(
                from: repoID, revision: "main", matching: [name])
            guard let item = metas.first, metas.count == 1 else {
                throw ModelDownloadError.verificationFailed(
                    directory: repoID,
                    reason: "the Hub returned \(metas.count) metadata entries for \(name)")
            }

            let bytes = Int64(item.size ?? 0)
            total += bytes
            if let commit = item.commitHash { revisions.insert(commit) }

            let kind: ModelManifest.ETagKind
            if let etag = item.etag {
                // Only LFS files carry a SHA256 here, and only those does `HubApi`
                // actually verify. Everything else is a 40-hex git blob hash.
                kind = hub.isValidSHA256(etag) ? .sha256 : .gitBlob
            } else {
                kind = .unknown
            }
            files.append(ModelManifest.Entry(
                path: name, bytes: bytes, etag: item.etag, etagKind: kind))
        }

        guard let revision = revisions.first, revisions.count == 1 else {
            throw ModelDownloadError.verificationFailed(
                directory: repoID,
                reason: revisions.isEmpty
                    ? "the Hub returned no commit for this repo"
                    : "the Hub returned \(revisions.count) different commits for one revision")
        }

        return ModelDownloadPlan(
            repoID: repoID,
            directoryName: String(parts[1]),
            revision: revision,
            files: files,
            totalBytes: total)
    }

    // MARK: - Free space (§4.2 step 2)

    /// Bytes available on the store's volume.
    ///
    /// `volumeAvailableCapacityForImportantUsage` on **both** platforms: S3_RECON §3.2
    /// verified the key is `macos(10.13)+ / ios(11.0)+`, so the difference between the
    /// platforms is semantic, not API. This key reports space including what the
    /// system expects to reclaim by purging caches, which is the right question for a
    /// user-initiated download the user is waiting on.
    ///
    /// The queried URL must be on the target volume, so the store root is used (or its
    /// nearest existing ancestor, since the store may not exist yet on a fresh device).
    func availableBytes() -> Int64? {
        var probe = storeRoot
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return nil }
            probe = parent
        }
        let values = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Collision policy (§4.4)

    func occupancy(of directoryName: String) -> ModelStoreOccupancy {
        Self.occupancy(of: directoryName, in: storeRoot)
    }

    nonisolated static func occupancy(of directoryName: String, in storeRoot: URL) -> ModelStoreOccupancy {
        let target = storeRoot.appending(path: directoryName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: target.path) else { return .absent }
        // Presence of *our* manifest, matched on the exact filename, is the only
        // completeness signal. `.hfmanifest.json` is a foreign artifact and must not
        // satisfy this check.
        guard let manifest = ModelManifest.read(from: target) else { return .unknownOccupant }
        return .sameRepo(repoID: manifest.repoID)
    }

    /// Applies §4.4 to a plan, throwing the specific refusal.
    func checkCollision(for plan: ModelDownloadPlan) throws {
        switch occupancy(of: plan.directoryName) {
        case .absent:
            return
        case .sameRepo(let repoID) where repoID == plan.repoID:
            throw ModelDownloadError.occupied(repoID: repoID)
        case .sameRepo(let repoID):
            throw ModelDownloadError.collision(existing: repoID, incoming: plan.repoID)
        case .differentRepo(let existing):
            throw ModelDownloadError.collision(existing: existing, incoming: plan.repoID)
        case .unknownOccupant:
            throw ModelDownloadError.unknownOccupant(directory: plan.directoryName)
        }
    }

    // MARK: - Download (§4.2 steps 3–5)

    /// Downloads, verifies, moves into the store, then writes the manifest **last**.
    ///
    /// Returns the final store directory.
    func download(
        plan: ModelDownloadPlan,
        onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        try checkCollision(for: plan)

        if let available = availableBytes(), available < plan.requiredBytes {
            throw ModelDownloadError.insufficientSpace(
                required: plan.requiredBytes, available: available)
        }

        // The resolved commit SHA, not "main": it pins exactly what preflight
        // measured, so the manifest cannot describe a different revision than the one
        // on disk. `snapshot` does forward `revision` to its own file listing
        // (HubApi.swift:941) — unlike `getFileMetadata`, which does not (:1108).
        let materialized = try await Self.runSnapshot(
            hub: hub,
            repoID: plan.repoID,
            revision: plan.revision,
            globs: Self.matchingGlobs,
            onProgress: onProgress)

        // `snapshot` returns the destination **normally** when the task is cancelled
        // (HubApi.swift:966–968) rather than throwing, so a cancelled transfer would
        // otherwise look like a success and get moved into the store as a partial model.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: materialized)
            throw ModelDownloadError.cancelled
        }

        // Verify BEFORE the move and before the manifest: "files arrived" is not
        // verification. This is the same predicate discovery uses, so a directory that
        // passes here is a directory the app can actually load.
        if let missing = ModelManager.missingRequirement(in: materialized) {
            throw ModelDownloadError.verificationFailed(
                directory: plan.directoryName, reason: missing)
        }

        let destination = try install(materialized: materialized, plan: plan)

        // Manifest last, always: written early, a crash mid-move leaves a directory
        // that looks complete and isn't.
        let manifest = ModelManifest(
            repoID: plan.repoID,
            revision: plan.revision,
            downloadedAt: Date(),
            files: plan.files,
            totalBytes: plan.totalBytes)
        try manifest.write(to: destination)

        return destination
    }

    /// Moves the materialized repo into the store under its final name.
    private func install(materialized: URL, plan: ModelDownloadPlan) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        let destination = storeRoot.appending(
            path: plan.directoryName, directoryHint: .isDirectory)

        // Re-checked here, not just at the top: preflight and completion are minutes
        // apart for a 473 MB transfer.
        guard !fm.fileExists(atPath: destination.path) else {
            throw ModelDownloadError.unknownOccupant(directory: plan.directoryName)
        }

        // Drop HubApi's sidecar directory: it describes the cache layout, not a model,
        // and `.cache` inside the store would be carried around forever.
        try? fm.removeItem(at: materialized.appending(path: ".cache", directoryHint: .isDirectory))

        // Same volume by construction (downloadBase sits beside the store), so this is
        // a rename. Cross-volume — an external SSD store — would be a real copy and
        // would pay the doubling; recorded, not solved.
        try fm.moveItem(at: materialized, to: destination)
        return destination
    }

    /// The one place a non-`Sendable` `Progress` exists.
    ///
    /// `nonisolated` so the handler closure is formed outside any actor's isolation
    /// domain — that is what makes this compile under strict concurrency with no
    /// `@unchecked Sendable`, no `nonisolated(unsafe)`, and no access-control change.
    /// `Progress` is converted to a `Sendable` snapshot here and never escapes.
    private nonisolated static func runSnapshot(
        hub: HubApi,
        repoID: String,
        revision: String,
        globs: [String],
        onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        try await hub.snapshot(from: repoID, revision: revision, matching: globs) { progress in
            onProgress(ModelDownloadProgress(
                fractionCompleted: progress.fractionCompleted,
                completedUnitCount: progress.completedUnitCount,
                totalUnitCount: progress.totalUnitCount))
        }
    }
}
