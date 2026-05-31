import Foundation
import GRDB
import SenaniStore

/// GRDB-backed `InvoiceStore` over the shared `SenaniDatabase`. The `invoices`
/// table is ADDITIVE: it is created with `CREATE TABLE IF NOT EXISTS` on init,
/// because the frozen `SenaniMigrations` (v1–v4) cannot be edited.
public struct SqliteInvoiceStore: InvoiceStore {
    private let database: SenaniDatabase

    public init(database: SenaniDatabase) throws {
        self.database = database
        try database.queue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS invoices (
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL,
                vendor TEXT,
                invoice_number TEXT,
                amount DOUBLE,
                currency TEXT,
                due_date DOUBLE,
                captured_at DOUBLE NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_invoices_due ON invoices(due_date)")
        }
    }

    public func upsert(_ record: InvoiceRecord) throws {
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO invoices
                    (id, message_id, vendor, invoice_number, amount, currency, due_date, captured_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    message_id = excluded.message_id,
                    vendor = excluded.vendor,
                    invoice_number = excluded.invoice_number,
                    amount = excluded.amount,
                    currency = excluded.currency,
                    due_date = excluded.due_date,
                    captured_at = excluded.captured_at
                """,
                arguments: [
                    record.id, record.messageId, record.vendor, record.invoiceNumber,
                    record.amount, record.currency,
                    record.dueDate?.timeIntervalSince1970, record.capturedAt.timeIntervalSince1970
                ])
        }
    }

    public func fetch(id: String) throws -> InvoiceRecord? {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM invoices WHERE id = ?",
                                             arguments: [id]) else { return nil }
            return Self.decode(row)
        }
    }

    public func all() throws -> [InvoiceRecord] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM invoices ORDER BY id").map(Self.decode)
        }
    }

    private static func decode(_ row: Row) -> InvoiceRecord {
        InvoiceRecord(
            id: row["id"],
            messageId: row["message_id"],
            vendor: row["vendor"],
            invoiceNumber: row["invoice_number"],
            amount: row["amount"],
            currency: row["currency"],
            dueDate: (row["due_date"] as Double?).map { Date(timeIntervalSince1970: $0) },
            capturedAt: Date(timeIntervalSince1970: row["captured_at"])
        )
    }
}
