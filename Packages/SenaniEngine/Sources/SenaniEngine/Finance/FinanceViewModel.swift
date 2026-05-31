import Foundation

/// Pure, SwiftUI-free view model for the Finance screen.
public struct FinanceViewModel: Sendable {
    public struct Row: Sendable, Identifiable, Equatable {
        public let id: String
        public let vendor: String?
        public let invoiceNumber: String?
        public let amount: Double?
        public let currency: String?
        public let dueDate: Date?
        public let isDueSoon: Bool
    }

    public let rows: [Row]
    public let totalsByCurrency: [String: Double]

    public init(store: any InvoiceStore, now: Date, dueSoonWindowDays: Int = 7) throws {
        let window = TimeInterval(dueSoonWindowDays) * 86_400
        let records = try store.all()

        func dueSoon(_ d: Date?) -> Bool {
            guard let d else { return false }
            return d >= now && d <= now.addingTimeInterval(window)
        }

        let sorted = records.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l == r ? lhs.id < rhs.id : l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.id < rhs.id
            }
        }

        self.rows = sorted.map { r in
            Row(id: r.id, vendor: r.vendor, invoiceNumber: r.invoiceNumber,
                amount: r.amount, currency: r.currency, dueDate: r.dueDate,
                isDueSoon: dueSoon(r.dueDate))
        }

        var totals: [String: Double] = [:]
        for r in records {
            guard let amount = r.amount, let ccy = r.currency else { continue }
            totals[ccy, default: 0] += amount
        }
        self.totalsByCurrency = totals
    }
}
