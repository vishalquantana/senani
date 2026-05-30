import Foundation
import SenaniInference

public struct DocumentExtractor: Sendable {
    private let generator: any TextGenerator

    public init(generator: any TextGenerator) {
        self.generator = generator
    }

    public func extract(from document: ParsedDocument) async throws -> ExtractedFields {
        let schema = JSONSchema.object(properties: ["fields": .object(properties: [:], required: [])], required: ["fields"])
        let raw = try await generator.generateJSON(
            prompt: "Extract key business fields from this document as JSON fields:\n\(document.text)",
            schema: schema
        )
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = object["fields"] as? [String: String]
        else {
            return ExtractedFields(fields: [:])
        }
        return ExtractedFields(fields: fields)
    }
}
