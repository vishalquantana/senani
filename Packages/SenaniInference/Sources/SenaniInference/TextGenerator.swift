public enum InferenceError: Error, Sendable, Equatable {
    case modelNotLoaded
    case generationFailed(String)
    case decodingFailed(String)
}

public protocol TextGenerator: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
}
