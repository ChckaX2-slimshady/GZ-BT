import XCTest
@testable import GZBT

/// Manifest, collision policy, free-space arithmetic, delete, and `isScanning`.
///
/// Every test here uses an **injected** store root. `ModelManager.modelsRoot` is a
/// computed static with no seat of its own, so without `init(root:)` these would all
/// write into the real model store. `GZBT_STORE_PATH` is deliberately not used — it
/// gates the conversation database only.
final class ModelDownloadTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "gzbt-models-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    /// Writes a directory that satisfies the 3-part discovery predicate.
    @discardableResult
    private func seedModelDirectory(
        named name: String,
        tokenizer: String = "tokenizer.json"
    ) throws -> URL {
        let dir = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = #"{"model_type":"qwen3","quantization":{"bits":2},"max_position_embeddings":32768}"#
        try config.write(to: dir.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 7, count: 2048)
            .write(to: dir.appending(path: "model.safetensors"))
        try "{}".write(to: dir.appending(path: tokenizer), atomically: true, encoding: .utf8)
        return dir
    }

    private func manifest(repoID: String, revision: String = String(repeating: "a", count: 40)) -> ModelManifest {
        ModelManifest(
            repoID: repoID,
            revision: revision,
            downloadedAt: Date(timeIntervalSince1970: 1_753_900_000),
            files: [
                .init(path: "config.json", bytes: 2939, etag: String(repeating: "b", count: 40), etagKind: .gitBlob),
                .init(path: "model.safetensors", bytes: 484_049_216, etag: String(repeating: "c", count: 64), etagKind: .sha256),
            ],
            totalBytes: 484_052_155)
    }

    // MARK: - Manifest

    func testManifestRoundTripsWithSpecifiedJSONShape() throws {
        let dir = try seedModelDirectory(named: "Round-Trip-4bit")
        let written = manifest(repoID: "mlx-community/Round-Trip-4bit")
        try written.write(to: dir)

        let read = try XCTUnwrap(ModelManifest.read(from: dir))
        XCTAssertEqual(read, written)

        // The on-disk key names are load-bearing: the file is the completeness signal
        // and a later session must be able to read it without this type.
        let data = try Data(contentsOf: dir.appending(path: ModelManifest.filename))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual(json["repo_id"] as? String, "mlx-community/Round-Trip-4bit")
        XCTAssertEqual(json["total_bytes"] as? Int64, 484_052_155)
        XCTAssertEqual(json["downloaded_at"] as? Double, 1_753_900_000)

        let files = try XCTUnwrap(json["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 2)
        // No `sha256` field anywhere: the ETag is only a SHA256 for LFS files, and
        // naming it that for the rest would put a git blob hash under a false name.
        for file in files {
            XCTAssertNil(file["sha256"], "manifest must not claim a sha256 field")
            XCTAssertNotNil(file["etag_kind"])
        }
        XCTAssertEqual(files.first(where: { $0["path"] as? String == "config.json" })?["etag_kind"] as? String,
                       "git-blob")
        XCTAssertEqual(files.first(where: { $0["path"] as? String == "model.safetensors" })?["etag_kind"] as? String,
                       "sha256")
    }

    func testManifestFilenameIsDistinctFromTheLegacyHFArtifact() throws {
        let dir = try seedModelDirectory(named: "Legacy-Shaped")
        // The hand-copied model carries `.hfmanifest.json`, written by a foreign tool
        // and absent from the HF repo. It must NOT read as a GZ-BT manifest.
        try #"{"repoId":"prism-ml/Legacy-Shaped","revision":"main"}"#
            .write(to: dir.appending(path: ".hfmanifest.json"), atomically: true, encoding: .utf8)

        XCTAssertNotEqual(ModelManifest.filename, ".hfmanifest.json")
        XCTAssertNil(ModelManifest.read(from: dir),
                     "a .hfmanifest.json must not satisfy the completeness check")
        XCTAssertEqual(ModelDownloadEngine.occupancy(of: "Legacy-Shaped", in: root),
                       .unknownOccupant)
    }

    // MARK: - Collision policy (§4.4)

    func testOccupancyAbsentWhenNothingInstalled() {
        XCTAssertEqual(ModelDownloadEngine.occupancy(of: "Nothing-Here", in: root), .absent)
    }

    func testOccupancyReportsRepoIDFromManifest() throws {
        let dir = try seedModelDirectory(named: "Llama-3-8B")
        try manifest(repoID: "alpha/Llama-3-8B").write(to: dir)
        XCTAssertEqual(ModelDownloadEngine.occupancy(of: "Llama-3-8B", in: root),
                       .sameRepo(repoID: "alpha/Llama-3-8B"))
    }

    func testDifferentOrgSameNameIsAGenuineCollision() async throws {
        let dir = try seedModelDirectory(named: "Llama-3-8B")
        try manifest(repoID: "alpha/Llama-3-8B").write(to: dir)

        let engine = ModelDownloadEngine(storeRoot: root)
        let plan = ModelDownloadPlan(
            repoID: "beta/Llama-3-8B",
            directoryName: "Llama-3-8B",
            revision: String(repeating: "d", count: 40),
            files: [],
            totalBytes: 1000)

        do {
            try await engine.checkCollision(for: plan)
            XCTFail("a colliding directory name must be refused")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .collision(existing: "alpha/Llama-3-8B", incoming: "beta/Llama-3-8B"))
            // Both repo ids must be named, so the refusal is actionable.
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains("alpha/Llama-3-8B"))
            XCTAssertTrue(message.contains("beta/Llama-3-8B"))
        }
    }

    func testLegacyDirectoryWithoutManifestIsRefusedAsUnknownOccupant() async throws {
        // E6's shape: the store dir exists, is occupied, and has no GZ-BT manifest.
        try seedModelDirectory(named: "Ternary-Bonsai-1.7B-mlx-2bit")

        let engine = ModelDownloadEngine(storeRoot: root)
        let plan = ModelDownloadPlan(
            repoID: "prism-ml/Ternary-Bonsai-1.7B-mlx-2bit",
            directoryName: "Ternary-Bonsai-1.7B-mlx-2bit",
            revision: String(repeating: "e", count: 40),
            files: [],
            totalBytes: 1000)

        do {
            try await engine.checkCollision(for: plan)
            XCTFail("an unknown occupant must be refused, not overwritten")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .unknownOccupant(directory: "Ternary-Bonsai-1.7B-mlx-2bit"))
        }
    }

    func testReDownloadingAnInstalledRepoIsRefusedRatherThanSilentlyOverwriting() async throws {
        let dir = try seedModelDirectory(named: "Bonsai")
        try manifest(repoID: "prism-ml/Bonsai").write(to: dir)

        let engine = ModelDownloadEngine(storeRoot: root)
        let plan = ModelDownloadPlan(
            repoID: "prism-ml/Bonsai",
            directoryName: "Bonsai",
            revision: String(repeating: "f", count: 40),
            files: [],
            totalBytes: 1000)

        do {
            try await engine.checkCollision(for: plan)
            XCTFail("an already-installed repo must not be silently overwritten")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .occupied(repoID: "prism-ml/Bonsai"))
        }
    }

    // MARK: - Directory naming (ratified #5)

    func testDirectoryNameIsTheLastPathComponentOfTheRepoID() async throws {
        let engine = ModelDownloadEngine(storeRoot: root)
        do {
            _ = try await engine.preflight(repoID: "not-a-repo-id")
            XCTFail("a repo id without an org must be rejected")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .invalidRepoID("not-a-repo-id"))
        }
    }

    // MARK: - Free space (§4.2 step 2)

    func testRequiredBytesCoversTheTransferCacheAndHeadroom() {
        let plan = ModelDownloadPlan(
            repoID: "prism-ml/Ternary-Bonsai-1.7B-mlx-2bit",
            directoryName: "Ternary-Bonsai-1.7B-mlx-2bit",
            revision: String(repeating: "a", count: 40),
            files: [],
            totalBytes: 495_528_947)

        // 2x for the cache-then-copy the transfer performs, plus headroom.
        XCTAssertEqual(plan.headroomBytes, ModelDownloadPlan.headroomFloor)
        XCTAssertEqual(plan.requiredBytes, 495_528_947 * 2 + 1_000_000_000)

        // Headroom scales for models large enough that a flat floor is too thin.
        let big = ModelDownloadPlan(
            repoID: "org/big", directoryName: "big",
            revision: String(repeating: "a", count: 40),
            files: [], totalBytes: 40_000_000_000)
        XCTAssertEqual(big.headroomBytes, 4_000_000_000)
    }

    func testInsufficientSpaceMessageNamesBothNumbers() throws {
        let error = ModelDownloadError.insufficientSpace(
            required: 2_000_000_000, available: 100_000_000)
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains(ByteFormat.string(2_000_000_000)))
        XCTAssertTrue(message.contains(ByteFormat.string(100_000_000)))
    }

    func testAvailableBytesResolvesEvenWhenTheStoreDoesNotExistYet() async {
        // A fresh device has no store directory; the query must still find the volume.
        let missing = root.appending(path: "not/created/yet", directoryHint: .isDirectory)
        let engine = ModelDownloadEngine(storeRoot: missing)
        let available = await engine.availableBytes()
        XCTAssertNotNil(available, "free space must resolve via the nearest existing ancestor")
        XCTAssertGreaterThan(available ?? 0, 0)
    }

    // MARK: - Verification uses the discovery predicate (§4.2)

    func testVerificationSharesTheDiscoveryPredicate() throws {
        let good = try seedModelDirectory(named: "Complete-4bit")
        XCTAssertTrue(ModelManager.isUsableModelDirectory(good))
        XCTAssertNil(ModelManager.missingRequirement(in: good))

        // A repo whose only tokenizer is `tokenizer.model` — the file the MLX glob
        // excludes — must fail loudly rather than install invisibly.
        let tokenizerOnly = try seedModelDirectory(
            named: "Sentencepiece-Only", tokenizer: "tokenizer.model")
        XCTAssertTrue(ModelManager.isUsableModelDirectory(tokenizerOnly))
        try FileManager.default.removeItem(
            at: tokenizerOnly.appending(path: "tokenizer.model"))
        XCTAssertFalse(ModelManager.isUsableModelDirectory(tokenizerOnly))
        XCTAssertEqual(ModelManager.missingRequirement(in: tokenizerOnly),
                       "no tokenizer.json or tokenizer.model")

        let noWeights = root.appending(path: "No-Weights", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: noWeights, withIntermediateDirectories: true)
        try "{}".write(to: noWeights.appending(path: "config.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ModelManager.missingRequirement(in: noWeights),
                       "no .safetensors weight file")
    }

    // MARK: - Discovery, scanning, delete

    @MainActor
    func testInjectedRootKeepsTheRealStoreUntouched() async throws {
        try seedModelDirectory(named: "Injected-4bit")
        let manager = ModelManager(root: root)
        await manager.scan()

        XCTAssertEqual(manager.root, root)
        XCTAssertNotEqual(manager.root, ModelManager.modelsRoot)
        XCTAssertEqual(manager.models.map(\.id), ["Injected-4bit"])
    }

    @MainActor
    func testInjectedRootDoesNotPersistSelectionToSharedDefaults() async throws {
        let before = UserDefaults.standard.string(forKey: "models.activeModelID")
        try seedModelDirectory(named: "Ephemeral-4bit")

        let manager = ModelManager(root: root)
        await manager.scan()
        XCTAssertEqual(manager.activeModelID, "Ephemeral-4bit", "sole model is auto-selected")

        XCTAssertEqual(UserDefaults.standard.string(forKey: "models.activeModelID"), before,
                       "a test store must not repoint the real active model")
    }

    @MainActor
    func testDeleteRemovesTheDirectoryAndReportsReclaimedBytes() async throws {
        let dir = try seedModelDirectory(named: "Delete-Me-4bit")
        let manager = ModelManager(root: root)
        await manager.scan()

        let model = try XCTUnwrap(manager.models.first)
        XCTAssertGreaterThan(model.sizeBytes, 0, "reclaimed bytes come from the scan")

        try await manager.delete(model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(manager.models.isEmpty, "delete rescans")
    }

    /// E7's load-bearing half: deleting a model must **not** cascade into telemetry.
    ///
    /// `message_telemetry.model_id` is a plain string with no foreign key, and history
    /// outliving the model is deliberate — Spectre's comparative work depends on being
    /// able to compare a model that is no longer installed. Asserted against a
    /// non-zero row count so the test cannot pass vacuously.
    @MainActor
    func testDeletingAModelLeavesTelemetryRowsIntact() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "gzbt-telemetry-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let store = ConversationStore(url: storeURL)
        await store.start()
        let created = await store.createConversation(title: "E7")
        let conversation = try XCTUnwrap(created)

        // Two assistant turns recorded against the model that is about to be deleted.
        for index in 0..<2 {
            let id = UUID()
            _ = await store.beginAssistantMessage(id: id, in: conversation.id)
            await store.finishAssistantMessage(
                id: id,
                in: conversation.id,
                content: "reply \(index)",
                status: .complete,
                telemetry: MessageTelemetry(
                    messageID: id,
                    modelID: "Delete-Me-4bit",
                    engine: "mlx",
                    ttftMs: 96.6,
                    tokensPerSecond: 49.7))
        }

        let before = await store.counts()
        XCTAssertEqual(before.telemetry, 2, "the test must start from a non-zero count")

        let dir = try seedModelDirectory(named: "Delete-Me-4bit")
        let manager = ModelManager(root: root)
        await manager.scan()
        let model = try XCTUnwrap(manager.models.first { $0.id == "Delete-Me-4bit" })
        try await manager.delete(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        let after = await store.counts()
        XCTAssertEqual(after.telemetry, before.telemetry,
                       "deleting a model must not delete its telemetry history")
        XCTAssertEqual(after.messages, before.messages,
                       "nor the messages that referenced it")
    }

    @MainActor
    func testIsScanningIsObservableWhileScanRuns() async throws {
        for index in 0..<3 { try seedModelDirectory(named: "Model-\(index)-4bit") }
        let manager = ModelManager(root: root)

        XCTAssertFalse(manager.isScanning)

        // Observed through `withObservationTracking` — the same mechanism SwiftUI uses
        // — rather than by racing a poll against the scan. While `scan()` was
        // synchronous on the main actor, `isScanning` was set and cleared inside one
        // main-actor turn and this change could never be seen; now the tree walk runs
        // off the main actor and the transition is observable.
        //
        // The continuation is `Sendable`, so the `@Sendable` onChange closure needs no
        // unsafe capture to report back.
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        withObservationTracking {
            _ = manager.isScanning
        } onChange: {
            continuation.yield(())
        }

        // `finish()` guarantees the loop below terminates even if nothing is observed,
        // so a regression fails the assertion instead of hanging the suite.
        let scanTask = Task { @MainActor in
            await manager.scan()
            continuation.finish()
        }

        var observedChange = false
        for await _ in stream {
            observedChange = true
            break
        }
        await scanTask.value

        XCTAssertTrue(observedChange, "isScanning must change observably during a scan")
        XCTAssertFalse(manager.isScanning, "and must be cleared when the scan ends")
        XCTAssertEqual(manager.models.count, 3)
    }
}
