import Foundation

public final class MLXTextGenerator: TextGenerator, @unchecked Sendable {
    private let modelPath: String

    public init(modelPath: String) {
        self.modelPath = modelPath
    }

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw InferenceError.modelNotLoaded
        }
        throw InferenceError.generationFailed("MLX runtime is not linked in this build")
    }

    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        _ = try GrammarMask(schema: schema)
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw InferenceError.modelNotLoaded
        }
        throw InferenceError.generationFailed("MLX runtime is not linked in this build")
    }
}
