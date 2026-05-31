import Foundation

/// A normalized invoice/receipt persisted to the additive `invoices` table.
public struct InvoiceRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var messageId: String
    public var vendor: String?
    public var invoiceNumber: String?
    public var amount: Double?
    public var currency: String?
    public var dueDate: Date?
    public var capturedAt: Date

    public init(
        id: String,
        messageId: String,
        vendor: String?,
        invoiceNumber: String?,
        amount: Double?,
        currency: String?,
        dueDate: Date?,
        capturedAt: Date
    ) {
        self.id = id
        self.messageId = messageId
        self.vendor = vendor
        self.invoiceNumber = invoiceNumber
        self.amount = amount
        self.currency = currency
        self.dueDate = dueDate
        self.capturedAt = capturedAt
    }
}

/// Persistence seam for captured invoices/receipts.
public protocol InvoiceStore: Sendable {
    func upsert(_ record: InvoiceRecord) throws
    func fetch(id: String) throws -> InvoiceRecord?
    func all() throws -> [InvoiceRecord]
}

extension InvoiceStore {
    /// Invoices whose `dueDate` is in `[asOf, asOf + within]`.
    public func dueSoon(asOf: Date, within: TimeInterval) throws -> [InvoiceRecord] {
        let upper = asOf.addingTimeInterval(within)
        return try all().filter { rec in
            guard let due = rec.dueDate else { return false }
            return due >= asOf && due <= upper
        }
    }
}

/// No-op default.
public struct NullInvoiceStore: InvoiceStore {
    public init() {}
    public func upsert(_ record: InvoiceRecord) throws {}
    public func fetch(id: String) throws -> InvoiceRecord? { nil }
    public func all() throws -> [InvoiceRecord] { [] }
}

/// Thread-safe in-memory store.
public final class InMemoryInvoiceStore: InvoiceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: InvoiceRecord] = [:]

    public init(_ seed: [InvoiceRecord] = []) {
        for r in seed { records[r.id] = r }
    }

    public func upsert(_ record: InvoiceRecord) throws {
        lock.lock(); defer { lock.unlock() }
        records[record.id] = record
    }
    public func fetch(id: String) throws -> InvoiceRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }
    public func all() throws -> [InvoiceRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { $0.id < $1.id }
    }
}
