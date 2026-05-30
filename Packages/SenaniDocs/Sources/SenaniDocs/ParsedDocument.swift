import Foundation

public struct ParsedDocument: Sendable, Equatable {
    public let id: String
    public let messageId: String
    public let filename: String
    public let kind: String
    public let text: String

    public init(id: String, messageId: String, filename: String, kind: String, text: String) {
        self.id = id
        self.messageId = messageId
        self.filename = filename
        self.kind = kind
        self.text = text
    }
}

public protocol DocumentParser: Sendable {
    func parse(url: URL, messageId: String) async throws -> ParsedDocument
}

public struct ExtractedFields: Codable, Sendable, Equatable {
    public var fields: [String: String]
    public init(fields: [String: String]) {
        self.fields = fields
    }
}
