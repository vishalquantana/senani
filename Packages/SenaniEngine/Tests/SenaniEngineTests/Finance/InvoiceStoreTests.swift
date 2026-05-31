import Testing
import Foundation
@testable import SenaniEngine

@Suite struct InvoiceStoreTests {
    private func record(_ id: String, currency: String = "USD",
                        amount: Double = 100, due: Date? = FIN.now) -> InvoiceRecord {
        InvoiceRecord(
            id: id, messageId: "m-\(id)", vendor: "Acme LLC", invoiceNumber: "INV-\(id)",
            amount: amount, currency: currency, dueDate: due, capturedAt: FIN.now)
    }

    @Test func recordHoldsTheNormalizedShape() {
        let r = record("1", currency: "EUR", amount: 250.5)
        #expect(r.currency == "EUR")
        #expect(r.amount == 250.5)
        #expect(r.invoiceNumber == "INV-1")
    }

    @Test func inMemoryStoreUpsertsAndFetches() throws {
        let store = InMemoryInvoiceStore()
        try store.upsert(record("1"))
        #expect(try store.fetch(id: "1")?.vendor == "Acme LLC")
        #expect(try store.all().count == 1)
    }

    @Test func upsertReplacesSameId() throws {
        let store = InMemoryInvoiceStore()
        try store.upsert(record("1", amount: 100))
        try store.upsert(record("1", amount: 200))
        #expect(try store.all().count == 1)
        #expect(try store.fetch(id: "1")?.amount == 200)
    }

    @Test func dueSoonReturnsOnlyInvoicesDueWithinWindow() throws {
        let store = InMemoryInvoiceStore()
        try store.upsert(record("soon", due: FIN.now.addingTimeInterval(2 * 86_400)))   // due in 2 days
        try store.upsert(record("later", due: FIN.now.addingTimeInterval(40 * 86_400))) // due in 40 days
        try store.upsert(record("nodate", due: nil))                                     // no due date
        let soon = try store.dueSoon(asOf: FIN.now, within: 7 * 86_400)
        #expect(Set(soon.map { $0.id }) == ["soon"])
    }

    @Test func nullStoreIsANoOp() throws {
        let store: any InvoiceStore = NullInvoiceStore()
        try store.upsert(record("x"))
        #expect(try store.all().isEmpty)
        #expect(try store.fetch(id: "x") == nil)
        #expect(try store.dueSoon(asOf: FIN.now, within: 7 * 86_400).isEmpty)
    }
}
