import Foundation
import MLX
import SenaniInference
import SenaniInferenceEmbeddingGemmaMLX
import Testing

@Suite struct EmbeddingGemmaMLXSmokeTests {
    @Test func localModelProducesNormalizedEmbedding() async throws {
        guard let modelPath = Self.modelPath(),
              FileManager.default.fileExists(atPath: modelPath)
        else {
            return
        }

        let vector = try await Device.withDefaultDevice(.cpu) {
            let embedder = try await EmbeddingGemmaMLXEmbedder(modelPath: modelPath)
            return try await embedder.embed("Senani keeps Gmail AI inference on device.")
        }
        let norm = vector.reduce(Float(0)) { partial, value in
            partial + value * value
        }.squareRoot()

        #expect(vector.count == EmbeddingDimension.full.rawValue)
        #expect(abs(norm - 1) < 0.001)
    }

    private static func modelPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SENANI_EMBEDDINGGEMMA_MODEL_PATH"], !path.isEmpty {
            return path
        }

        var packageRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            packageRoot.deleteLastPathComponent()
        }
        return packageRoot
            .appendingPathComponent("Models/embeddinggemma-300m-4bit", isDirectory: true)
            .path
    }
}
