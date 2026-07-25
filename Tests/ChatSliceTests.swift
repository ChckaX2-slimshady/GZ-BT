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

        let vm = ChatViewModel(engine: MLXInferenceEngine(), models: models)
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

        let used = (vm.metrics.promptTokens ?? 0) + (vm.metrics.generatedTokens ?? 0)
        print("======== RUNTIME PROOF (macOS, real Bonsai MLX) ========")
        print("model:  \(vm.activeModelName ?? "—")")
        print("prompt: Say hi in one short sentence.")
        print("reply:  \(assistant?.text ?? "")")
        print("-- Seam-1 telemetry emitted --")
        print("TTFT:            \(vm.metrics.ttft.map { String(format: "%.0f ms", $0.milliseconds) } ?? "—")")
        print("tokens/sec:      \(vm.metrics.tokensPerSecond.map { String(format: "%.2f", $0) } ?? "—")")
        print("prompt tokens:   \(vm.metrics.promptTokens.map(String.init) ?? "—")")
        print("generated tokens:\(vm.metrics.generatedTokens.map(String.init) ?? "—")")
        print("context used:    \(used) (prompt+generated)")
        print("context capacity:\(vm.metrics.contextCapacity.map(String.init) ?? "NOT EMITTED via Seam-1 (32768 from config.json)")")
        print("lifecycle:       \(vm.metrics.lifecycle)")
        print("========================================================")
    }

    @MainActor
    private func wait(upTo seconds: Double, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
