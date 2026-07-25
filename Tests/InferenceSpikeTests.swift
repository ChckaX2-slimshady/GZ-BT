import XCTest
@testable import GZBT

/// Inference spike (Checkpoint-2 gate): proves the real Bonsai MLX model loads
/// from GZ-BT's own model store and streams tokens through the neutral
/// `InferenceEngine` seam — with live Seam-1 telemetry. If the 2-bit ternary
/// quant cannot be loaded by this MLX build, this test fails loudly (no fake
/// green); the ratified fallback is a mainstream 4-bit Qwen3.
final class InferenceSpikeTests: XCTestCase {

    private var modelURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "GZ-BT/Models/Ternary-Bonsai-1.7B-mlx-2bit", directoryHint: .isDirectory)
    }

    func testBonsaiLoadsAndStreams() async throws {
        let url = modelURL
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.appending(path: "config.json").path),
            "Bonsai model not seeded at \(url.path)")

        let model = ResolvedModel(id: "bonsai-1.7b-2bit", name: "Ternary-Bonsai-1.7B", url: url)
        let engine = MLXInferenceEngine()

        // Observe Seam-1 in parallel.
        let telemetry = Task { () -> [String] in
            var seen: [String] = []
            for await event in engine.telemetry {
                switch event {
                case .lifecycle(let l): seen.append("lifecycle:\(l)")
                case .firstToken(let ttft): seen.append("ttft:\(ttft)")
                case .throughput(let t): seen.append("tps:\(String(format: "%.1f", t))")
                case .completed: seen.append("completed")
                case .context(let u, let c): seen.append("ctx:\(u)/\(c)")
                }
                if seen.contains("completed") { break }
            }
            return seen
        }

        try await engine.load(model, progress: nil)

        var text = ""
        var summary: GenerationSummary?
        let request = GenerationRequest(
            messages: [ChatTurn(role: .user, text: "Reply with one short friendly sentence.")],
            config: GenerationConfig(maxTokens: 48, temperature: 0.7, topP: 0.95))

        for await event in await engine.generate(request) {
            switch event {
            case .token(let t): text += t
            case .completed(let s): summary = s
            case .failed(let message): XCTFail("generation failed: \(message)")
            }
        }

        let seam1 = await telemetry.value

        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "expected non-empty streamed text")
        XCTAssertGreaterThan(summary?.generatedTokens ?? 0, 0, "expected >0 generated tokens")
        XCTAssertGreaterThan(summary?.tokensPerSecond ?? 0, 0, "expected >0 tokens/sec")
        XCTAssertTrue(seam1.contains { $0.hasPrefix("ttft:") }, "Seam-1 should report TTFT")
        XCTAssertTrue(seam1.contains("completed"), "Seam-1 should report completion")

        print("── SPIKE OUTPUT ─────────────────────────────")
        print(text)
        print("── SPIKE METRICS ────────────────────────────")
        print("generated=\(summary?.generatedTokens ?? -1) tokens, "
              + "tok/s=\(String(format: "%.2f", summary?.tokensPerSecond ?? -1)), "
              + "ttft=\(summary?.timeToFirstToken ?? .zero), stop=\(summary?.stopReason ?? "?")")
        print("── SEAM-1 EVENTS ────────────────────────────")
        print(seam1.joined(separator: " | "))
    }
}
