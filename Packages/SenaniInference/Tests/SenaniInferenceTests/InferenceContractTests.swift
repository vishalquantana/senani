import Foundation
import SenaniRules
import Testing
@testable import SenaniInference

@Suite struct InferenceContractTests {
    @Test func jsonSchemaBoolArrayAndRawInitializer() {
        let schema = JSONSchema.boolArrayResults(key: "results")
        guard case let .object(properties, required) = schema else {
            Issue.record("expected object schema")
            return
        }
        #expect(required == ["results"])
        #expect(properties["results"] == .array(element: .boolean))

        let raw = #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}"#
        #expect(JSONSchema(json: raw) == .object(properties: ["ok": .boolean], required: ["ok"]))
    }

    @Test func jsonResultParserHandlesNoisyAndCoercedOutput() {
        let raw = """
        Sure:
        ```json
        {"extra":"x","results":[true, 0, "true", "false"]}
        ```
        """
        #expect(JSONResultParser.parseBoolResults(raw) == [true, false, true, false])
        #expect(JSONResultParser.parseBoolResults("not json") == nil)
        #expect(JSONResultParser.parseBoolResults(#"{"answers":[true]}"#) == nil)
    }

    @Test func promptContainsMessagePredicateAndSchemaShape() {
        let prompt = PredicatePromptBuilder.build(
            predicates: ["is asking about pricing", "mentions attachment"],
            message: Self.message(body: String(repeating: "A", count: 1_100))
        )
        #expect(prompt.contains("sender@example.com"))
        #expect(prompt.contains("Subject"))
        #expect(prompt.contains("1. is asking about pricing"))
        #expect(prompt.contains("2. mentions attachment"))
        #expect(prompt.contains("results"))
        #expect(!prompt.contains(String(repeating: "A", count: 1_100)))
        #expect(PredicatePromptBuilder.schema == .boolArrayResults(key: "results"))
    }

    @Test func fakeGeneratorAndEmbedderBehave() async throws {
        let generator = FakeTextGenerator(responses: ["free", #"{"results":[true]}"#], fallback: "fallback")
        #expect(try await generator.generate(prompt: "p1", maxTokens: 3) == "free")
        #expect(try await generator.generateJSON(prompt: "p2", schema: .boolean) == #"{"results":[true]}"#)
        #expect(try await generator.generate(prompt: "p3", maxTokens: 3) == "fallback")
        #expect(generator.prompts == ["p1", "p2", "p3"])
        #expect(generator.schemas == [nil, .boolean, nil])

        let embedder = FakeEmbedder(vector: [1, 2])
        #expect(try await embedder.embed("hello") == [1, 2])
        #expect(embedder.embedded == ["hello"])
    }

    @Test func evaluatorAlignsAndDefaultsSafely() async {
        let ok = GemmaPredicateEvaluator(generator: FakeTextGenerator(responses: [#"{"results":[true,false,true]}"#]))
        #expect(await ok.evaluate(predicates: ["a", "b", "c"], against: Self.message()) == [true, false, true])

        let emptyGenerator = FakeTextGenerator(responses: [#"{"results":[true]}"#])
        let empty = GemmaPredicateEvaluator(generator: emptyGenerator)
        #expect(await empty.evaluate(predicates: [], against: Self.message()) == [])
        #expect(emptyGenerator.prompts.isEmpty)

        let short = GemmaPredicateEvaluator(generator: FakeTextGenerator(responses: [#"{"results":[true]}"#]))
        #expect(await short.evaluate(predicates: ["a", "b"], against: Self.message()) == [true, false])

        let malformed = GemmaPredicateEvaluator(generator: FakeTextGenerator(responses: ["garbage"]))
        #expect(await malformed.evaluate(predicates: ["a", "b"], against: Self.message()) == [false, false])

        let throwing = GemmaPredicateEvaluator(generator: ThrowingGenerator())
        #expect(await throwing.evaluate(predicates: ["a"], against: Self.message()) == [false])
    }

    @Test func mlxTypesConstructAndThrowWithoutModelPath() async {
        let generator = MLXTextGenerator(modelPath: "/definitely/missing")
        let embedder = MLXEmbedder(modelPath: "/definitely/missing")
        let embeddingGemma = EmbeddingGemmaEmbedder(modelPath: "/definitely/missing")

        await #expect(throws: InferenceError.modelNotLoaded) {
            _ = try await generator.generate(prompt: "hello", maxTokens: 1)
        }
        await #expect(throws: InferenceError.modelNotLoaded) {
            _ = try await generator.generateJSON(prompt: "{}", schema: .boolArrayResults(key: "results"))
        }
        await #expect(throws: InferenceError.modelNotLoaded) {
            _ = try await embedder.embed("hello")
        }
        await #expect(throws: InferenceError.modelNotLoaded) {
            _ = try await embeddingGemma.embed("hello")
        }
    }

    @Test func embeddingGemmaConfigurationPinsExpectedModelContract() {
        #expect(EmbeddingGemmaConfiguration.defaultModelID == "mlx-community/embeddinggemma-300m-4bit")
        #expect(EmbeddingGemmaConfiguration.upstreamModelID == "google/embeddinggemma-300m")
        #expect(EmbeddingGemmaConfiguration.contextTokenLimit == 2_048)
        #expect(EmbeddingDimension.allCases.map(\.rawValue) == [768, 512, 256, 128])
    }

    @Test func embeddingVectorTruncatesAndNormalizesMRLDimensions() {
        let vector = Array(repeating: Float(1), count: 768)
        let truncated = EmbeddingVector.truncateAndNormalize(vector, dimension: .mrl128)
        #expect(truncated.count == 128)
        let norm = truncated.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 0.0001)
    }

    @Test func embeddingGemmaWrapperDelegatesAndPostProcesses() async throws {
        let backend = FakeEmbedder(vector: Array(repeating: Float(2), count: 768))
        let embedder = EmbeddingGemmaEmbedder(
            configuration: EmbeddingGemmaConfiguration(
                modelPath: "/tmp/embeddinggemma",
                outputDimension: .mrl256
            ),
            backend: backend
        )
        let vector = try await embedder.embed("hello")
        #expect(vector.count == 256)
        #expect(backend.embedded == ["hello"])
    }

    @Test func embeddingGemmaWrapperTruncatesInputToContextLimit() async throws {
        let backend = FakeEmbedder(vector: Array(repeating: Float(1), count: 768))
        let embedder = EmbeddingGemmaEmbedder(
            configuration: EmbeddingGemmaConfiguration(modelPath: "/tmp/embeddinggemma"),
            backend: backend
        )
        let longText = Array(repeating: "word", count: 2_100).joined(separator: " ")
        _ = try await embedder.embed(longText)
        #expect(backend.embedded.first?.split(whereSeparator: \.isWhitespace).count == 2_048)
    }

    static func message(body: String = "Body") -> Message {
        Message(
            id: "m1",
            from: "sender@example.com",
            to: ["me@example.com"],
            subject: "Subject",
            body: body,
            hasAttachment: false,
            listUnsubscribeHeader: nil,
            labels: ["INBOX"],
            threadId: "t1",
            date: Date(timeIntervalSince1970: 0),
            isFromUser: false
        )
    }
}

final class FakeTextGenerator: TextGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private let fallback: String
    private(set) var prompts: [String] = []
    private(set) var schemas: [JSONSchema?] = []

    init(responses: [String], fallback: String = "") {
        self.responses = responses
        self.fallback = fallback
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        next(prompt: prompt, schema: nil)
    }

    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        next(prompt: prompt, schema: schema)
    }

    private func next(prompt: String, schema: JSONSchema?) -> String {
        lock.lock()
        defer { lock.unlock() }
        prompts.append(prompt)
        schemas.append(schema)
        return responses.isEmpty ? fallback : responses.removeFirst()
    }
}

final class FakeEmbedder: Embedder, @unchecked Sendable {
    private let lock = NSLock()
    private let vector: [Float]
    private(set) var embedded: [String] = []

    init(vector: [Float] = [0, 0, 0]) {
        self.vector = vector
    }

    func embed(_ text: String) async throws -> [Float] {
        record(text)
        return vector
    }

    private func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        embedded.append(text)
    }
}

private struct ThrowingGenerator: TextGenerator {
    func generate(prompt: String, maxTokens: Int) async throws -> String {
        throw InferenceError.generationFailed("boom")
    }

    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        throw InferenceError.generationFailed("boom")
    }
}
