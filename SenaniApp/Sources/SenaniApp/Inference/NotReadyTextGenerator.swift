import SenaniInference
import SenaniRules

/// The generator the app starts with, before a model is chosen/downloaded.
/// Every call fails loudly so UI can prompt the user to pick a model — it never
/// silently returns empty text. Replaced by MLXTextGenerator once a model is installed.
public struct NotReadyTextGenerator: TextGenerator {
    public init() {}

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        throw InferenceError.modelNotLoaded
    }

    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        throw InferenceError.modelNotLoaded
    }
}
