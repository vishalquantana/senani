import SenaniInference

/// The live `generator` before a model is chosen. Every call throws
/// `InferenceError.modelNotLoaded`. The MLX model-picker plan replaces this
/// with a real `MLXTextGenerator` once weights are on disk; UI that reaches a
/// generate call before then surfaces "no model selected".
public struct NotReadyTextGenerator: TextGenerator {
    public init() {}
    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        throw InferenceError.modelNotLoaded
    }
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        throw InferenceError.modelNotLoaded
    }
}
