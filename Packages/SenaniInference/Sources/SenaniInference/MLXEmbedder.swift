import Foundation

public final class MLXEmbedder: Embedder, @unchecked Sendable {
    private let modelPath: String

    public init(modelPath: String) {
        self.modelPath = modelPath
    }

    public func embed(_ text: String) async throws -> [Float] {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw InferenceError.modelNotLoaded
        }
        throw InferenceError.generationFailed("MLX runtime is not linked in this build")
    }
}
