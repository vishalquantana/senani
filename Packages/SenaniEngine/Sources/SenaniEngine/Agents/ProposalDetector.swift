import Foundation
import SenaniRules

/// The result of detecting an outbound proposal/quote: presence means "this is a proposal";
/// `value` is the monetary amount if one could be extracted (nil otherwise).
public struct ProposalSignal: Sendable, Equatable {
    public let value: Double?
    public init(value: Double?) { self.value = value }
}

/// Pure detector: decides whether an OUTBOUND message is a proposal/quote and extracts its value.
/// No I/O, no async — fully unit-testable. The Orchestrator supplies `documentFields` from
/// SenaniDocs.DocumentExtractor (empty when there is no parsed attachment).
public struct ProposalDetector: Sendable {
    public init() {}

    /// Keyword cues in the subject/body that mark a proposal or quote.
    static let keywords = ["proposal", "quote", "quotation", "estimate",
                           "statement of work", "sow"]
    /// Document-field keys that carry the deal value, in preference order.
    static let valueKeys = ["total", "grand_total", "quote_total", "amount",
                            "value", "price", "subtotal"]

    /// Returns a signal if `message` (must be outbound) is a proposal/quote, else nil.
    public func detect(_ message: Message, documentFields: [String: String]) -> ProposalSignal? {
        guard message.isFromUser else { return nil }   // only the user emailing OUT a proposal

        let docValue = extractValue(from: documentFields)
        let hasKeyword = matchesKeyword(message.subject) || matchesKeyword(message.body)

        // Proposal if doc fields has a value OR we see a keyword.
        guard docValue != nil || hasKeyword else { return nil }

        let value = docValue ?? extractCurrency(from: message.body)
        return ProposalSignal(value: value)
    }

    // MARK: - Pure helpers

    func matchesKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return Self.keywords.contains { lower.contains($0) }
    }

    /// Picks the first value-bearing document field (by preference order) and parses a number.
    func extractValue(from fields: [String: String]) -> Double? {
        let lowered = Dictionary(fields.map { ($0.key.lowercased(), $0.value) },
                                 uniquingKeysWith: { a, _ in a })
        for key in Self.valueKeys {
            if let raw = lowered[key], let v = Self.parseAmount(raw) { return v }
        }
        return nil
    }

    /// Finds the first currency-looking number in free text (e.g. "$8,500", "8500.00").
    func extractCurrency(from body: String) -> Double? {
        // Match an optional currency symbol then a grouped/decimal number.
        guard let regex = try? NSRegularExpression(
            pattern: #"[$€£]?\s?\d{1,3}(?:[,\d]{0,})(?:\.\d{1,2})?"#) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        let matches = regex.matches(in: body, range: range)
        for m in matches {
            guard let r = Range(m.range, in: body) else { continue }
            if let v = Self.parseAmount(String(body[r])), v >= 100 { return v }  // ignore tiny ints
        }
        return nil
    }

    /// Strips currency symbols and grouping separators, then parses a Double.
    static func parseAmount(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }
}
