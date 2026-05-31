import Foundation

/// Normalized finance fields extracted from a document's raw field bag.
public struct InvoiceFields: Sendable, Equatable {
    public var vendor: String?
    public var invoiceNumber: String?
    public var amount: Double?
    public var currency: String?
    public var dueDate: Date?

    public init(vendor: String? = nil, invoiceNumber: String? = nil, amount: Double? = nil,
                currency: String? = nil, dueDate: Date? = nil) {
        self.vendor = vendor
        self.invoiceNumber = invoiceNumber
        self.amount = amount
        self.currency = currency
        self.dueDate = dueDate
    }

    public var isSparse: Bool {
        vendor == nil || invoiceNumber == nil || amount == nil || dueDate == nil
    }
}

/// Pure normalization of a raw `[String: String]` field bag into `InvoiceFields`.
public struct FinanceFieldNormalizer: Sendable {
    public init() {}

    static let vendorKeys = ["vendor", "supplier", "seller", "from", "biller", "merchant", "company"]
    static let numberKeys = ["invoice_number", "invoice_no", "invoice", "number", "inv_no", "bill_number"]
    static let amountKeys = ["amount", "total", "amount_due", "grand_total",
                             "balance_due", "invoice_total", "subtotal"]
    static let currencyKeys = ["currency", "ccy"]
    static let dueKeys = ["due_date", "due", "payment_due", "due_on", "date_due"]

    public func normalize(_ fields: [String: String]) -> InvoiceFields {
        let bag = Dictionary(fields.map { ($0.key.lowercased(), $0.value) },
                             uniquingKeysWith: { a, _ in a })
        func firstValue(_ keys: [String]) -> String? {
            for k in keys { if let v = bag[k], !v.trimmingCharacters(in: .whitespaces).isEmpty { return v } }
            return nil
        }
        let amountStr = firstValue(Self.amountKeys)
        return InvoiceFields(
            vendor: firstValue(Self.vendorKeys)?.trimmingCharacters(in: .whitespacesAndNewlines),
            invoiceNumber: firstValue(Self.numberKeys)?.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: Self.parseAmount(amountStr),
            currency: Self.normalizeCurrency(firstValue(Self.currencyKeys) ?? Self.currencySymbol(in: amountStr)),
            dueDate: Self.parseDate(firstValue(Self.dueKeys))
        )
    }

    public static func parseAmount(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "₹", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    public static func normalizeCurrency(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        switch t {
        case "$", "US$", "usd", "USD": return "USD"
        case "€", "eur", "EUR": return "EUR"
        case "£", "gbp", "GBP": return "GBP"
        case "₹", "inr", "INR", "Rs", "Rs.": return "INR"
        default:
            let upper = t.uppercased()
            return (upper.count == 3 && upper.allSatisfy { $0.isLetter }) ? upper : nil
        }
    }

    static func currencySymbol(in amount: String?) -> String? {
        guard let a = amount?.trimmingCharacters(in: .whitespaces).first else { return nil }
        switch a {
        case "$": return "$"
        case "€": return "€"
        case "£": return "£"
        case "₹": return "₹"
        default: return nil
        }
    }

    private static let formats = ["yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "dd MMM yyyy", "MMM dd, yyyy"]

    public static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
        }
        return nil
    }
}
