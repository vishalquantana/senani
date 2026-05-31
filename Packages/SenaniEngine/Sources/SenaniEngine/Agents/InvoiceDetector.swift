import Foundation
import SenaniRules

/// Pure detector: decides whether an INBOUND message is an invoice/receipt.
public struct InvoiceDetector: Sendable {
    public init() {}

    /// Subject/body keyword cues that mark an invoice/receipt/bill.
    static let keywords = ["invoice", "receipt", "amount due", "amount owed",
                           "bill", "payment due", "statement", "remittance", "tax invoice"]
    /// Document-field keys that carry a monetary value.
    static let valueKeys = ["amount", "total", "amount_due", "grand_total",
                            "balance_due", "invoice_total", "subtotal"]

    /// Returns true if `message` looks like an invoice/receipt.
    public func isInvoice(_ message: Message, documentFields: [String: String]) -> Bool {
        guard !message.isFromUser else { return false }
        if hasMonetaryDocField(documentFields) { return true }
        return matchesKeyword(message.subject) || matchesKeyword(message.body)
    }

    func matchesKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return Self.keywords.contains { lower.contains($0) }
    }

    func hasMonetaryDocField(_ fields: [String: String]) -> Bool {
        let lowered = Dictionary(fields.map { ($0.key.lowercased(), $0.value) },
                                 uniquingKeysWith: { a, _ in a })
        for key in Self.valueKeys where FinanceFieldNormalizer.parseAmount(lowered[key]) != nil {
            return true
        }
        return false
    }
}
