import Foundation

public struct DocumentPipeline: Sendable {
    private let parser: any DocumentParser
    private let extractor: DocumentExtractor
    private let indexer: DocumentIndexer

    public init(parser: any DocumentParser, extractor: DocumentExtractor, indexer: DocumentIndexer) {
        self.parser = parser
        self.extractor = extractor
        self.indexer = indexer
    }

    public func process(url: URL, messageId: String) async throws -> ParsedDocument {
        let document = try await parser.parse(url: url, messageId: messageId)
        let fields = try await extractor.extract(from: document)
        try await indexer.index(document: document, fields: fields)
        return document
    }
}

public struct LiteParseDocumentParser: DocumentParser {
    public init() {}
    public func parse(url: URL, messageId: String) async throws -> ParsedDocument {
        guard ProcessInfo.processInfo.environment["SENANI_LITEPARSE_ENABLED"] != nil else {
            throw LiteParseError.notConfigured
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return ParsedDocument(id: url.lastPathComponent, messageId: messageId, filename: url.lastPathComponent, kind: url.pathExtension, text: text)
    }
}

public enum LiteParseError: Error, Equatable {
    case notConfigured
}
