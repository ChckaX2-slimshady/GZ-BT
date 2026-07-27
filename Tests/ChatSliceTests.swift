import XCTest
@testable import GZBT

/// End-to-end proof of the Session-1 vertical slice through the ChatViewModel:
/// select model → load → stream a reply into messages → Seam-1 metrics populate.
final class ChatSliceTests: XCTestCase {

    @MainActor
    func testChatStreamsAndReportsMetrics() async throws {
        let models = ModelManager()
        models.scan()
        try XCTSkipUnless(models.activeModel != nil,
                          "no model seeded at \(ModelManager.modelsRoot.path)")

        // A temporary store, so the suite never writes into the developer's real
        // conversation history.
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "gzbt-slice-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let store = ConversationStore(url: storeURL)
        let vm = ChatViewModel(
            engine: MLXInferenceEngine(), models: models, store: store, engineID: "mlx")
        vm.start()
        await wait(upTo: 60) { vm.status == .ready }
        XCTAssertEqual(vm.status, .ready, "model should load")

        vm.input = "Say hi in one short sentence."
        vm.send()
        await wait(upTo: 60) { !vm.isStreaming && vm.messages.count >= 2 }

        let assistant = vm.messages.last
        XCTAssertEqual(assistant?.role, .assistant)
        XCTAssertEqual(assistant?.isStreaming, false)
        XCTAssertFalse(assistant?.text.isEmpty ?? true, "assistant reply should be non-empty")
        XCTAssertNotNil(vm.metrics.tokensPerSecond, "Seam-1 should report tok/s")
        XCTAssertNotNil(vm.metrics.ttft, "Seam-1 should report TTFT")
        XCTAssertGreaterThan(vm.metrics.generatedTokens ?? 0, 0)
        XCTAssertNotNil(vm.metrics.contextUsed, "Seam-1 .context(used:) should fire")
        XCTAssertNotNil(vm.metrics.contextCapacity, "Seam-1 .context(capacity:) should fire")
        XCTAssertEqual(vm.metrics.contextCapacity, 32768, "Bonsai context capacity from max_position_embeddings")

        print("======== RUNTIME PROOF (macOS, real Bonsai MLX) ========")
        print("model:  \(vm.activeModelName ?? "—")")
        print("prompt: Say hi in one short sentence.")
        print("reply:  \(assistant?.text ?? "")")
        print("-- Seam-1 telemetry emitted --")
        print("TTFT:            \(vm.metrics.ttft.map { String(format: "%.0f ms", $0.milliseconds) } ?? "—")")
        print("tokens/sec:      \(vm.metrics.tokensPerSecond.map { String(format: "%.2f", $0) } ?? "—")")
        print("prompt tokens:   \(vm.metrics.promptTokens.map(String.init) ?? "—")")
        print("generated tokens:\(vm.metrics.generatedTokens.map(String.init) ?? "—")")
        print("context used:    \(vm.metrics.contextUsed.map(String.init) ?? "—") (Seam-1 .context)")
        print("context capacity:\(vm.metrics.contextCapacity.map(String.init) ?? "—") (Seam-1 .context)")
        print("lifecycle:       \(vm.metrics.lifecycle)")
        print("========================================================")

        // ---- Session 2: the same turn must be durable -----------------------
        let conversationID = try XCTUnwrap(vm.currentConversationID,
                                           "sending should have created a conversation")
        let counts = await store.counts()
        XCTAssertEqual(counts.messages, 2, "one user + one assistant row")
        XCTAssertEqual(counts.streaming, 0, "no row may be left mid-stream")

        let stored = await store.messages(in: conversationID)
        XCTAssertEqual(stored.map(\.role), [.user, .assistant])
        XCTAssertEqual(stored.map(\.sequence), [0, 1], "sequence is monotonic within a conversation")
        XCTAssertEqual(stored.last?.status, .complete)
        XCTAssertEqual(stored.last?.content, assistant?.text,
                       "persisted content must match what was streamed on screen")

        let assistantID = try XCTUnwrap(stored.last?.id)
        let storedTelemetry = await store.telemetry(for: assistantID)
        let telemetry = try XCTUnwrap(storedTelemetry,
                                      "every assistant message carries persisted telemetry")
        XCTAssertNotNil(telemetry.ttftMs)
        XCTAssertNotNil(telemetry.tokensPerSecond)
        XCTAssertNotNil(telemetry.contextUsed)
        XCTAssertNotNil(telemetry.contextCapacity)
        // §4.4 predicted these three would be unfillable. They are not.
        XCTAssertNotNil(telemetry.promptTokens, "§4.4: prompt_tokens IS available via .completed")
        XCTAssertNotNil(telemetry.tokensOut, "§4.4: tokens_out IS available via .completed")
        XCTAssertNotNil(telemetry.finishReason, "§4.4: finish_reason IS available via .completed")

        print("======== PERSISTED TELEMETRY (message_telemetry row) ====")
        print("model=\(telemetry.modelID) engine=\(telemetry.engine)")
        print("ttft_ms=\(telemetry.ttftMs.map { String(format: "%.1f", $0) } ?? "NULL")")
        print("tokens_per_sec=\(telemetry.tokensPerSecond.map { String(format: "%.2f", $0) } ?? "NULL")")
        print("context_used=\(telemetry.contextUsed.map(String.init) ?? "NULL")")
        print("context_capacity=\(telemetry.contextCapacity.map(String.init) ?? "NULL")")
        print("prompt_tokens=\(telemetry.promptTokens.map(String.init) ?? "NULL")   <- §4.4 predicted NULL")
        print("tokens_out=\(telemetry.tokensOut.map(String.init) ?? "NULL")         <- §4.4 predicted NULL")
        print("finish_reason=\(telemetry.finishReason ?? "NULL")                    <- §4.4 predicted NULL")
        print("schema_version=\(telemetry.schemaVersion) extra=\(telemetry.extra ?? "NULL")")
        print("========================================================")

        // ---- E1 in test form: a second store over the same file sees it all ---
        let reopened = ConversationStore(url: storeURL)
        await reopened.start()
        XCTAssertEqual(reopened.conversations.count, 1)
        let restored = await reopened.messages(in: conversationID)
        XCTAssertEqual(restored.count, 2, "transcript survives a fresh store over the same file")
        XCTAssertEqual(restored.last?.content, assistant?.text)
    }

    @MainActor
    private func wait(upTo seconds: Double, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
