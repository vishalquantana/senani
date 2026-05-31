import SenaniInference

/// App-local fake generator for previews and UI tests (SenaniInference ships no
/// fake). Returns a fixed canned response for every call.
public struct FakeTextGenerator: TextGenerator {
    private let response: String
    public init(response: String = #"{ "tool_calls": [], "reply": "" }"#) {
        self.response = response
    }
    public func generate(prompt: String, maxTokens: Int) async throws -> String { response }
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String { response }
}

/// App-local fake embedder for previews and UI tests. Returns a deterministic
/// fixed-width zero vector so the in-memory vector index can accept inserts.
public struct FakeEmbedder: Embedder {
    private let dimension: Int
    public init(dimension: Int = 768) { self.dimension = dimension }
    public func embed(_ text: String) async throws -> [Float] {
        Array(repeating: 0, count: dimension)
    }
}
