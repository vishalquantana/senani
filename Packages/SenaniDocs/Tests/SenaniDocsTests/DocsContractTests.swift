import Foundation
import SenaniInference
import SenaniStore
import Testing
@testable import SenaniDocs

@Suite struct DocsContractTests {
    @Test func extractsChunksIndexesAndSearches() async throws {
        let database = try SenaniDatabase.inMemory()
        let vector = InMemoryVectorIndex()
        let embedder = FakeEmbedder()
        let doc = ParsedDocument(id: "d1", messageId: "m1", filename: "invoice.pdf", kind: "pdf", text: "Invoice total is 120 dollars due tomorrow.")
        let extractor = DocumentExtractor(generator: FakeTextGenerator(json: #"{"fields":{"total":"120","due":"tomorrow"}}"#))
        let fields = try await extractor.extract(from: doc)
        #expect(fields.fields["total"] == "120")

        let indexer = DocumentIndexer(database: database, embedder: embedder, vectorIndex: vector, now: { 1 })
        try await indexer.index(document: doc, fields: fields)

        let search = DocumentSearch(database: database, embedder: embedder, vectorIndex: vector)
        #expect(try search.fields(named: "total") == [DocumentFieldHit(documentId: "d1", name: "total", value: "120")])
        let hits = try await search.semantic(query: "total", k: 1)
        #expect(hits.first?.documentId == "d1")
        #expect(hits.first?.text.contains("Invoice total") == true)
    }

    @Test func pipelineComposesParserExtractorIndexer() async throws {
        let database = try SenaniDatabase.inMemory()
        let pipeline = DocumentPipeline(
            parser: FakeParser(),
            extractor: DocumentExtractor(generator: FakeTextGenerator(json: #"{"fields":{"vendor":"Acme"}}"#)),
            indexer: DocumentIndexer(database: database, embedder: FakeEmbedder(), vectorIndex: InMemoryVectorIndex(), now: { 1 })
        )
        let document = try await pipeline.process(url: URL(fileURLWithPath: "/tmp/acme.txt"), messageId: "m1")
        #expect(document.filename == "acme.txt")
    }

    @Test func liteParseParserIsGatedWhenUnconfigured() async {
        await #expect(throws: LiteParseError.notConfigured) {
            _ = try await LiteParseDocumentParser().parse(url: URL(fileURLWithPath: "/tmp/x.pdf"), messageId: "m")
        }
    }
}

struct FakeParser: DocumentParser {
    func parse(url: URL, messageId: String) async throws -> ParsedDocument {
        ParsedDocument(id: "doc", messageId: messageId, filename: url.lastPathComponent, kind: "txt", text: "Acme document")
    }
}

struct FakeTextGenerator: TextGenerator {
    let json: String
    func generate(prompt: String, maxTokens: Int) async throws -> String { json }
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String { json }
}

struct FakeEmbedder: Embedder {
    func embed(_ text: String) async throws -> [Float] { [Float(text.count), 1] }
}
