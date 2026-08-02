import XCTest
@testable import GZBT

/// Live network tests: real downloads against the HuggingFace Hub.
///
/// **Opt-in.** Every test here skips unless `GZBT_LIVE_DOWNLOAD=1` is set, so the
/// default suite (and CI) never depends on the network, on Hub availability, or on
/// ~500 MB of transfer. Run them deliberately:
///
/// ```
/// GZBT_LIVE_DOWNLOAD=1 xcodebuild test -scheme GZ-BT-Tests \
///   -destination 'platform=macOS' -only-testing:GZ-BTTests/ModelDownloadLiveTests
/// ```
///
/// They produce the E1–E7 evidence: real byte counts, real elapsed times, and the
/// real on-disk layout. Everything lands in a temporary store — the developer's real
/// model store is never written to.
final class ModelDownloadLiveTests: XCTestCase {

    /// The smallest starter repo (495.5 MB across the MLX glob).
    private static let repoID = "prism-ml/Ternary-Bonsai-1.7B-mlx-2bit"
    private static let directoryName = "Ternary-Bonsai-1.7B-mlx-2bit"

    private var root: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["GZBT_LIVE_DOWNLOAD"] == "1",
            "live download tests are opt-in; set GZBT_LIVE_DOWNLOAD=1")
        root = FileManager.default.temporaryDirectory
            .appending(path: "gzbt-live-\(UUID().uuidString)/Models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: - E1 / E2 — download, layout, manifest, load, generate

    @MainActor
    func test_E1_E2_downloadThenLayoutManifestLoadAndGenerate() async throws {
        let manager = ModelManager(root: root)
        let downloader = ModelDownloader(manager: manager)

        let engine = ModelDownloadEngine(storeRoot: root)
        let plan = try await engine.preflight(repoID: Self.repoID)
        print("======== E1 PREFLIGHT (metadata only, no bytes transferred) ========")
        print("repo:        \(plan.repoID)")
        print("directory:   \(plan.directoryName)")
        print("revision:    \(plan.revision)")
        print("files:       \(plan.files.count)")
        print("total bytes: \(plan.totalBytes) (\(ByteFormat.string(plan.totalBytes)))")
        print("required:    \(plan.requiredBytes) (\(ByteFormat.string(plan.requiredBytes))) = 2x + headroom")
        for file in plan.files.sorted(by: { $0.bytes > $1.bytes }) {
            print(String(format: "  %-32@ %12d  %@ %@",
                         file.path as NSString, file.bytes,
                         file.etagKind.rawValue, file.etag ?? "-"))
        }

        XCTAssertEqual(plan.directoryName, Self.directoryName)
        XCTAssertEqual(plan.revision.count, 40, "a resolved commit sha, not a branch name")
        XCTAssertGreaterThan(plan.totalBytes, 400_000_000)

        let started = ContinuousClock.now
        downloader.download(repoID: Self.repoID)
        await waitUntil(seconds: 1800) { !downloader.state.isBusy }
        let elapsed = started.duration(to: .now)

        if case .failed(_, let message) = downloader.state {
            XCTFail("download failed: \(message)")
            return
        }
        guard case .finished(_, let directoryName) = downloader.state else {
            XCTFail("unexpected terminal state: \(downloader.state)")
            return
        }

        let installed = root.appending(path: directoryName, directoryHint: .isDirectory)
        print("======== E2 STORE LAYOUT ========")
        print("store root: \(root.path)")
        let names = try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted()
        for name in names {
            let size = (try? FileManager.default
                .attributesOfItem(atPath: installed.appending(path: name).path)[.size] as? Int64) ?? 0
            print(String(format: "  %-36@ %12d", name as NSString, size ?? 0))
        }
        print("elapsed: \(elapsed)")

        // Directory name is the last path component; the manifest carries the full id.
        XCTAssertEqual(directoryName, Self.directoryName)
        let manifest = try XCTUnwrap(ModelManifest.read(from: installed),
                                     "manifest must exist after a successful download")
        print("======== E2 MANIFEST (\(ModelManifest.filename)) ========")
        print(String(data: try ModelManifest.encoder().encode(manifest), encoding: .utf8) ?? "-")

        XCTAssertEqual(manifest.repoID, Self.repoID, "repo_id preserves the org the dir name drops")
        XCTAssertEqual(manifest.revision, plan.revision)
        XCTAssertEqual(manifest.schemaVersion, ModelManifest.currentSchemaVersion)
        XCTAssertFalse(manifest.files.isEmpty)
        XCTAssertTrue(manifest.files.contains { $0.etagKind == .sha256 },
                      "weight files are LFS and carry a real sha256")
        XCTAssertTrue(manifest.files.contains { $0.etagKind == .gitBlob },
                      "small files carry a git blob hash, recorded as such")

        // HubApi's sidecar directory must not have been carried into the store.
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appending(path: ".cache").path),
                       ".cache must not be installed into the model store")

        // It appears in the Models list...
        await manager.scan()
        XCTAssertEqual(manager.models.map(\.id), [Self.directoryName])
        let discovered = try XCTUnwrap(manager.models.first)
        XCTAssertEqual(discovered.architecture, "qwen3")
        XCTAssertEqual(discovered.quantization, "2-bit")

        // ...loads, and generates.
        let inference = MLXInferenceEngine()
        try await inference.load(manager.resolve(discovered), progress: nil)
        var reply = ""
        for await event in await inference.generate(GenerationRequest(
            messages: [ChatTurn(role: .user, text: "Say hi in one short sentence.")])) {
            if case .token(let token) = event { reply += token }
            if case .failed(let message) = event { XCTFail("generation failed: \(message)") }
        }
        await inference.unload()

        print("======== E1 GENERATION FROM THE DOWNLOADED MODEL ========")
        print("reply: \(reply)")
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - E4 — cancel

    @MainActor
    func test_E4_cancelLeavesNoPartialDirectoryInTheStore() async throws {
        clearHubCacheForRepo()  // cold, so the transfer is long enough to interrupt

        let manager = ModelManager(root: root)
        let downloader = ModelDownloader(manager: manager)

        downloader.download(repoID: Self.repoID)
        // Triggered on real bytes on disk, not the file-weighted progress fraction.
        await waitUntil(seconds: 600) { self.bytesOnDiskForRepo() > 50_000_000 }
        let atCancel = bytesOnDiskForRepo()
        print("======== E4 CANCEL ========")
        print("bytes on disk at cancel: \(atCancel) (\(ByteFormat.string(atCancel)))")
        print("progress at cancel: \(downloader.completedFiles)/\(downloader.totalFiles) files, "
              + String(format: "%.1f%%", downloader.progress.fractionCompleted * 100))
        downloader.cancel()
        await waitUntil(seconds: 300) { !downloader.state.isBusy }

        print("terminal state: \(downloader.state)")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        print("store contents after cancel: \(contents)")

        XCTAssertFalse(contents.contains(Self.directoryName),
                       "a cancelled download must leave no directory in the store")
        await manager.scan()
        XCTAssertTrue(manager.models.isEmpty, "and nothing discoverable")

        // Cache-cleanup behaviour, recorded either way (E4).
        print("---- cache state after cancel ----")
        printCacheState()
    }

    // MARK: - E3 — resume vs restart

    /// Interrupts past 50 MB, restarts, and measures whether the second attempt
    /// continues from the bytes already on disk or starts over.
    ///
    /// Recon predicts **restart**: `HubApi` computes `incompleteDestination` and never
    /// passes it to `downloadFile` (`HubApi.swift:823–827` vs `:849–856`), and
    /// swift-huggingface's resume path is gated behind a `try?` HEAD inside the
    /// ETag+cache branch. Whatever happens, it is reported with byte counts — a
    /// restart is a finding, not a failure, and is not to be dressed up as a resume.
    @MainActor
    func test_E3_resumeOrRestartAfterInterruption() async throws {
        clearHubCacheForRepo()

        let manager = ModelManager(root: root)
        let downloader = ModelDownloader(manager: manager)

        print("======== E3 RESUME ========")
        print("cache bytes at start (cold): \(hubCacheBytesForRepo())")

        // ---- first attempt: interrupt past 50 MB of REAL bytes ----
        //
        // The trigger is bytes actually on disk, not `progress.fractionCompleted`:
        // that fraction is file-weighted, so "past 50 MB" derived from it can mean
        // anything from 2,939 B to 484 MB depending on which file finished first.
        downloader.download(repoID: Self.repoID)
        await waitUntil(seconds: 600) { self.bytesOnDiskForRepo() > 50_000_000 }
        let onDiskAtCancel = bytesOnDiskForRepo()
        downloader.cancel()
        await waitUntil(seconds: 300) { !downloader.state.isBusy }

        let retainedAfterCancel = bytesOnDiskForRepo()
        print("-- after interruption --")
        print("bytes on disk at cancel:  \(onDiskAtCancel) (\(ByteFormat.string(onDiskAtCancel)))")
        print("bytes on disk after cancel: \(retainedAfterCancel) (\(ByteFormat.string(retainedAfterCancel)))")
        for entry in hubCacheFilesForRepo() { print("   cache: \(entry)") }

        // ---- second attempt: does it continue or start over? ----
        let restarted = ContinuousClock.now
        downloader.download(repoID: Self.repoID)

        // Sample early: if the transfer resumes, the on-disk byte count stays at or
        // above what the interruption left behind. If it restarts, it drops toward 0.
        var minimumObserved = retainedAfterCancel
        let samplingDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < samplingDeadline && downloader.state.isBusy {
            minimumObserved = min(minimumObserved, bytesOnDiskForRepo())
            try? await Task.sleep(for: .milliseconds(250))
        }

        await waitUntil(seconds: 1800) { !downloader.state.isBusy }
        let secondElapsed = restarted.duration(to: .now)

        print("-- second attempt --")
        print("lowest cache byte count observed after restart: \(minimumObserved) "
              + "(\(ByteFormat.string(minimumObserved)))")
        print("elapsed second attempt: \(secondElapsed)")
        print("terminal state: \(downloader.state)")

        // Two independent discriminators, both on real bytes:
        //  1. did the bytes present at cancel survive the cancellation, and
        //  2. did the retry start from them rather than from zero.
        let retainedFraction = onDiskAtCancel > 0
            ? Double(retainedAfterCancel) / Double(onDiskAtCancel)
            : 0
        let resumed = retainedFraction > 0.5 && minimumObserved >= retainedAfterCancel
            && retainedAfterCancel > 50_000_000

        print("retained/at-cancel: \(retainedAfterCancel)/\(onDiskAtCancel) "
              + String(format: "= %.4f", retainedFraction))
        print("low-water after restart: \(minimumObserved) B")
        print("VERDICT: \(resumed ? "RESUMED" : "RESTARTED")")
        print("""
              NOTE: compare the second-attempt elapsed time against the cold-start \
              baseline measured in E1 (50.3 s for this repo). A genuine resume of a \
              transfer already \(ByteFormat.string(onDiskAtCancel)) in must be \
              substantially faster than a cold start; a comparable time is a restart.
              """)

        // The download must still succeed either way; that is the assertion. Whether it
        // resumed is recorded as a measurement, not asserted, because the honest answer
        // is the one the run produces.
        guard case .finished = downloader.state else {
            XCTFail("the retried download must still complete: \(downloader.state)")
            return
        }
        await manager.scan()
        XCTAssertEqual(manager.models.map(\.id), [Self.directoryName])
    }

    // MARK: - E5 — free space

    @MainActor
    func test_E5_insufficientSpaceIsRefusedBeforeAnyWrite() async throws {
        // The volume has far more than a 495 MB model needs, so the refusal is proved
        // against the arithmetic rather than by filling the disk: a plan whose total
        // exceeds the volume must be refused, and refused before anything is written.
        let engine = ModelDownloadEngine(storeRoot: root)
        let reportedAvailable = await engine.availableBytes()
        let available = try XCTUnwrap(reportedAvailable)

        let plan = ModelDownloadPlan(
            repoID: "mlx-community/Impossibly-Large-4bit",
            directoryName: "Impossibly-Large-4bit",
            revision: String(repeating: "a", count: 40),
            files: [],
            totalBytes: available)  // 2x + headroom cannot fit

        print("======== E5 FREE SPACE ========")
        print("available: \(available) (\(ByteFormat.string(available)))")
        print("required:  \(plan.requiredBytes) (\(ByteFormat.string(plan.requiredBytes)))")

        do {
            _ = try await engine.download(plan: plan) { _ in }
            XCTFail("must refuse when the volume cannot hold the transfer")
        } catch let error as ModelDownloadError {
            guard case .insufficientSpace(let required, let reported) = error else {
                XCTFail("expected insufficientSpace, got \(error)")
                return
            }
            print("refused: \(error.errorDescription ?? "")")
            XCTAssertEqual(required, plan.requiredBytes)
            XCTAssertGreaterThan(reported, 0)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "no partial write may occur on refusal")
    }

    /// E3, sharpened: interrupt **during** the 484 MB weight file rather than between
    /// files, and see whether the partial bytes survive.
    ///
    /// `test_E3_resume…` interrupts wherever the >50 MB-on-disk trigger fires, and on
    /// this repo that is always *after* `model.safetensors` has completed and been
    /// committed — so it measures completed-file reuse. This one cancels on a timer,
    /// mid-file, which is the case that actually matters for foreground-only iOS: if a
    /// user backgrounds the app 80% through the weight file, do they lose it?
    @MainActor
    func test_E3b_interruptMidWeightFile() async throws {
        clearHubCacheForRepo()

        let manager = ModelManager(root: root)
        let downloader = ModelDownloader(manager: manager)

        print("======== E3b MID-FILE INTERRUPTION ========")
        downloader.download(repoID: Self.repoID)
        await waitUntil(seconds: 120) { downloader.state.isCancellable }

        // ~15 s into a transfer that takes ~50 s cold: solidly inside the big file.
        try? await Task.sleep(for: .seconds(15))
        let fractionAtCancel = downloader.progress.fractionCompleted
        print("cancelling mid-transfer at \(String(format: "%.1f%%", fractionAtCancel * 100)) "
              + "(\(downloader.completedFiles)/\(downloader.totalFiles) files complete)")
        print("visible bytes on disk at cancel: \(bytesOnDiskForRepo())")
        print("partial/incomplete files anywhere under the cache or downloadBase:")
        for entry in partialFileCandidates() { print("   \(entry)") }

        downloader.cancel()
        await waitUntil(seconds: 300) { !downloader.state.isBusy }

        let retained = bytesOnDiskForRepo()
        print("-- after mid-file cancel --")
        print("bytes retained: \(retained) (\(ByteFormat.string(retained)))")
        for entry in hubCacheFilesForRepo() { print("   cache: \(entry)") }

        // ---- retry, cold-ish: how much had to be fetched again? ----
        let restarted = ContinuousClock.now
        downloader.download(repoID: Self.repoID)
        await waitUntil(seconds: 1800) { !downloader.state.isBusy }
        let elapsed = restarted.duration(to: .now)

        print("-- retry after mid-file interruption --")
        print("elapsed: \(elapsed)  (cold baseline for this repo: ~50.3 s from E1)")
        print("terminal state: \(downloader.state)")
        print("""
              READ THIS AS: if the retry takes about as long as a cold start, the \
              partial weight-file bytes were discarded and the transfer restarted \
              from zero — which is what S3_RECON §2.3 predicts, since HubApi builds \
              `incompleteDestination` and never passes it to downloadFile.
              """)

        guard case .finished = downloader.state else {
            XCTFail("the retried download must still complete: \(downloader.state)")
            return
        }
        await manager.scan()
        XCTAssertEqual(manager.models.map(\.id), [Self.directoryName])
    }

    // MARK: - E6 — collision against the REAL store

    /// The legacy hand-copied `Ternary-Bonsai-1.7B-mlx-2bit` sits in the real store with
    /// no GZ-BT manifest, so §4.4's "unknown occupant → refuse" branch is reachable with
    /// no setup at all.
    ///
    /// This runs `preflight` (metadata only) and then the collision check **against the
    /// real `ModelManager.modelsRoot`** — deliberately not `download`, so there is no code
    /// path by which a failure of the policy could touch the developer's working model.
    @MainActor
    func test_E6_collisionRefusesAgainstTheRealStore() async throws {
        let realRoot = ModelManager.modelsRoot
        try XCTSkipUnless(
            FileManager.default.fileExists(
                atPath: realRoot.appending(path: Self.directoryName).path),
            "the legacy model is not present in the real store")

        print("======== E6 COLLISION (real store) ========")
        print("store root: \(realRoot.path)")
        print("occupant:   \(Self.directoryName)")
        print("occupancy:  \(ModelDownloadEngine.occupancy(of: Self.directoryName, in: realRoot))")

        let engine = ModelDownloadEngine(storeRoot: realRoot)
        let plan = try await engine.preflight(repoID: Self.repoID)
        XCTAssertEqual(plan.directoryName, Self.directoryName,
                       "the repo id must reduce onto the occupied directory name")

        do {
            try await engine.checkCollision(for: plan)
            XCTFail("§4.4 must refuse an unknown occupant")
        } catch let error as ModelDownloadError {
            print("refused: \(error.errorDescription ?? "")")
            XCTAssertEqual(error, .unknownOccupant(directory: Self.directoryName))
        }

        // And the legacy directory is untouched.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: realRoot.appending(path: Self.directoryName)
                .appending(path: "model.safetensors").path))
        XCTAssertNil(ModelManifest.read(
            from: realRoot.appending(path: Self.directoryName)),
            "the legacy .hfmanifest.json must not read as a GZ-BT manifest")
    }

    // MARK: - Helpers

    /// Looks for partially-written artifacts anywhere the transfer might stage them.
    private func partialFileCandidates() -> [String] {
        var out: [String] = []
        let bases = [
            hubCacheRepoDirectory,
            root.deletingLastPathComponent().appending(path: "Downloads", directoryHint: .isDirectory),
            URL(fileURLWithPath: NSTemporaryDirectory()),
        ]
        for base in bases {
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            var scanned = 0
            for case let url as URL in walker {
                scanned += 1
                if scanned > 4000 { break }
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let name = url.lastPathComponent
                if size > 1_000_000 || name.contains("incomplete") || name.hasSuffix(".tmp") {
                    out.append("\(url.path) = \(size)")
                }
            }
        }
        return out
    }

    /// `~/.cache/huggingface/hub/models--<org>--<name>` — `HubCache.default` on macOS
    /// (`CacheLocationProvider.swift:196–219`).
    ///
    /// The tests read and clear this directly rather than injecting a cache: pointing
    /// `HubApi` at a temporary `HubCache` would require `import HuggingFace`, and that
    /// module is only transitively visible. Ratified #2 declared swift-transformers
    /// precisely to stop relying on undeclared transitive modules, so the test manages
    /// the (regenerable) cache instead of the production type growing a seat for it.
    private var hubCacheRepoDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory)
            .appending(path: "models--" + Self.repoID.replacingOccurrences(of: "/", with: "--"),
                       directoryHint: .isDirectory)
    }

    private func clearHubCacheForRepo() {
        let directory = hubCacheRepoDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            print("[cache] clearing \(directory.path) (was \(hubCacheBytesForRepo()) B)")
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func hubCacheBytesForRepo() -> Int64 {
        ModelManager.directorySize(hubCacheRepoDirectory)
    }

    /// Every byte on disk for this repo: the shared HF cache blob store plus the
    /// materialized snapshot under `downloadBase`. Used instead of
    /// `progress.fractionCompleted` because that fraction is file-weighted and cannot
    /// be converted to bytes.
    private func bytesOnDiskForRepo() -> Int64 {
        let downloads = root.deletingLastPathComponent()
            .appending(path: "Downloads", directoryHint: .isDirectory)
        return hubCacheBytesForRepo() + ModelManager.directorySize(downloads)
    }

    private func hubCacheFilesForRepo() -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: hubCacheRepoDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size > 0 else { continue }
            out.append("\(url.lastPathComponent) = \(size)")
        }
        return out
    }

    private func printCacheState() {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory),
            root.deletingLastPathComponent()
                .appending(path: "Downloads", directoryHint: .isDirectory),
        ]
        for base in candidates {
            guard FileManager.default.fileExists(atPath: base.path) else {
                print("  (absent) \(base.path)")
                continue
            }
            var total: Int64 = 0
            var incomplete: [String] = []
            if let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in walker {
                    let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    total += size
                    if url.lastPathComponent.contains("incomplete") {
                        incomplete.append("\(url.lastPathComponent) = \(size)")
                    }
                }
            }
            print("  \(base.path) total=\(total) (\(ByteFormat.string(total)))")
            for entry in incomplete { print("    incomplete: \(entry)") }
        }
    }

    @MainActor
    private func waitUntil(seconds: Double, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
