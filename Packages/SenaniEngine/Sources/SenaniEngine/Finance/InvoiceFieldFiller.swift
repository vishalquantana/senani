import Foundation
import SenaniInference

/// Fills the finance fields the extractor missed by asking the model for ONLY the
/// missing keys, parsing the response through the same `FinanceFieldNormalizer`.
public struct InvoiceFieldFiller: Sendable {
    private let normalizer: FinanceFieldNormalizer

    public init(normalizer: FinanceFieldNormalizer = FinanceFieldNormalizer()) {
        self.normalizer = normalizer
    }

    static let schema: JSONSchema = .object(properties: [
        "vendor": .string,
        "invoice_number": .string,
        "amount": .string,
        "currency": .string,
        "due_date": .string
    ], required: [])

    public func fill(
        _ fields: InvoiceFields,
        documentText: String,
        generateJSON: @Sendable (String, JSONSchema) async throws -> String
    ) async throws -> InvoiceFields {
        guard fields.isSparse else { return fields }

        let raw = try await generateJSON(Self.buildPrompt(text: documentText), Self.schema)
        let modelFields = Self.parseBag(raw)
        guard !modelFields.isEmpty else { return fields }
        let normalized = normalizer.normalize(modelFields)

        return InvoiceFields(
            vendor: fields.vendor ?? normalized.vendor,
            invoiceNumber: fields.invoiceNumber ?? normalized.invoiceNumber,
            amount: fields.amount ?? normalized.amount,
            currency: fields.currency ?? normalized.currency,
            dueDate: fields.dueDate ?? normalized.dueDate
        )
    }

    static func buildPrompt(text: String) -> String {
        """
        Extract invoice fields from the document text below as JSON with keys:
        vendor, invoice_number, amount, currency, due_date (ISO YYYY-MM-DD).
        Use a JSON string value per field; omit a key if not present. Do not invent values.

        DOCUMENT TEXT:
        \(text)
        """
    }

    static func parseBag(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var bag: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String, !s.isEmpty { bag[k] = s }
            else if let n = v as? NSNumber { bag[k] = n.stringValue }
        }
        return bag
    }
}
