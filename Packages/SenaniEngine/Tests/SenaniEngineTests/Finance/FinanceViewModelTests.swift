import Testing
import Foundation
@testable import SenaniEngine

@Suite struct FinanceViewModelTests {
    private func rec(_ id: String, amount: Double?, currency: String?, due: Date?) -> InvoiceRecord {
        InvoiceRecord(id: id, messageId: "m-\(id)", vendor: "V-\(id)", invoiceNumber: id,
                      amount: amount, currency: currency, dueDate: due, capturedAt: FIN.now)
    }

    @Test func buildsRowsSortedByDueDateUndatedLast() throws {
        let store = InMemoryInvoiceStore([
            rec("a", amount: 100, currency: "USD", due: FIN.now.addingTimeInterval(20 * 86_400)),
            rec("b", amount: 50, currency: "USD", due: FIN.now.addingTimeInterval(2 * 86_400)),
            rec("c", amount: 10, currency: "USD", due: nil)
        ])
        let vm = try FinanceViewModel(store: store, now: FIN.now, dueSoonWindowDays: 7)
        #expect(vm.rows.map { $0.id } == ["b", "a", "c"])  // soonest first, undated last
    }

    @Test func flagsDueSoonRows() throws {
        let store = InMemoryInvoiceStore([
            rec("soon", amount: 100, currency: "USD", due: FIN.now.addingTimeInterval(3 * 86_400)),
            rec("later", amount: 100, currency: "USD", due: FIN.now.addingTimeInterval(30 * 86_400))
        ])
        let vm = try FinanceViewModel(store: store, now: FIN.now, dueSoonWindowDays: 7)
        let byId = Dictionary(uniqueKeysWithValues: vm.rows.map { ($0.id, $0) })
        #expect(byId["soon"]?.isDueSoon == true)
        #expect(byId["later"]?.isDueSoon == false)
    }

    @Test func totalsAreGroupedByCurrency() throws {
        let store = InMemoryInvoiceStore([
            rec("a", amount: 100, currency: "USD", due: nil),
            rec("b", amount: 50, currency: "USD", due: nil),
            rec("c", amount: 200, currency: "EUR", due: nil),
            rec("d", amount: nil, currency: "USD", due: nil)   // nil amount ignored in totals
        ])
        let vm = try FinanceViewModel(store: store, now: FIN.now, dueSoonWindowDays: 7)
        #expect(vm.totalsByCurrency["USD"] == 150)
        #expect(vm.totalsByCurrency["EUR"] == 200)
    }

    @Test func emptyStoreYieldsEmptyViewModel() throws {
        let vm = try FinanceViewModel(store: InMemoryInvoiceStore(), now: FIN.now, dueSoonWindowDays: 7)
        #expect(vm.rows.isEmpty)
        #expect(vm.totalsByCurrency.isEmpty)
    }
}
