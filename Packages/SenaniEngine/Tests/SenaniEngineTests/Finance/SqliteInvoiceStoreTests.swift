import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

@Suite struct SqliteInvoiceStoreTests {
    private func store() throws -> SqliteInvoiceStore {
        try SqliteInvoiceStore(database: SenaniDatabase.inMemory())
    }

    private func record(_ id: String, amount: Double? = 100, currency: String? = "USD",
                        due: Date? = FIN.now) -> InvoiceRecord {
        InvoiceRecord(id: id, messageId: "m-\(id)", vendor: "Acme LLC",
                      invoiceNumber: "INV-\(id)", amount: amount, currency: currency,
                      dueDate: due, capturedAt: FIN.now)
    }

    @Test func upsertThenFetchRoundTrips() throws {
        let s = try store()
        try s.upsert(record("1", amount: 1234.56, currency: "EUR"))
        let got = try #require(try s.fetch(id: "1"))
        #expect(got.vendor == "Acme LLC")
        #expect(got.invoiceNumber == "INV-1")
        #expect(got.amount == 1234.56)
        #expect(got.currency == "EUR")
        #expect(got.dueDate == FIN.now)
    }

    @Test func upsertReplacesSameId() throws {
        let s = try store()
        try s.upsert(record("1", amount: 100))
        try s.upsert(record("1", amount: 200))
        #expect(try s.all().count == 1)
        #expect(try s.fetch(id: "1")?.amount == 200)
    }

    @Test func nilAmountAndDueDatePersistAsNull() throws {
        let s = try store()
        try s.upsert(record("2", amount: nil, currency: nil, due: nil))
        let got = try #require(try s.fetch(id: "2"))
        #expect(got.amount == nil)
        #expect(got.currency == nil)
        #expect(got.dueDate == nil)
    }

    @Test func dueSoonFiltersByWindow() throws {
        let s = try store()
        try s.upsert(record("soon", due: FIN.now.addingTimeInterval(3 * 86_400)))
        try s.upsert(record("later", due: FIN.now.addingTimeInterval(30 * 86_400)))
        try s.upsert(record("none", due: nil))
        let soon = try s.dueSoon(asOf: FIN.now, within: 7 * 86_400)
        #expect(Set(soon.map { $0.id }) == ["soon"])
    }

    @Test func twoStoresShareTheTableOnOneDatabase() throws {
        let db = try SenaniDatabase.inMemory()
        let a = try SqliteInvoiceStore(database: db)
        try a.upsert(record("1"))
        let b = try SqliteInvoiceStore(database: db)   // re-creates table IF NOT EXISTS (idempotent)
        #expect(try b.fetch(id: "1")?.invoiceNumber == "INV-1")
    }
}
