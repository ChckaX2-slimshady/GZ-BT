import XCTest
@testable import GZBT

/// Proves the Services-layer discovery finds the seeded Bonsai MLX model in
/// GZ-BT's own store (config.json + *.safetensors + tokenizer).
final class ModelDiscoveryTests: XCTestCase {

    @MainActor
    func testDiscoversSeededBonsaiModel() async throws {
        let manager = ModelManager()
        await manager.scan()

        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: ModelManager.modelsRoot.path),
            "model store not present at \(ModelManager.modelsRoot.path)")

        XCTAssertFalse(manager.models.isEmpty,
                       "expected >=1 MLX model under \(ModelManager.modelsRoot.path)")

        let bonsai = manager.models.first { $0.id.localizedCaseInsensitiveContains("bonsai") }
        XCTAssertNotNil(bonsai, "Bonsai model not discovered; found \(manager.models.map(\.id))")

        if let bonsai {
            XCTAssertEqual(bonsai.architecture, "qwen3")
            XCTAssertEqual(bonsai.quantization, "2-bit")
            XCTAssertGreaterThan(bonsai.sizeBytes, 100_000_000)  // ~462 MB
            print("DISCOVERY: \(bonsai.id) arch=\(bonsai.architecture ?? "?") "
                  + "quant=\(bonsai.quantization ?? "?") size=\(ByteFormat.string(bonsai.sizeBytes))")
        }
    }
}
