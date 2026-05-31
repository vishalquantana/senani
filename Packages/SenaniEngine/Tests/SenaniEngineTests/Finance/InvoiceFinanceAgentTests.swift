import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct InvoiceFinanceAgentWakesForTests {
    private func agent() -> InvoiceFinanceAgent { InvoiceFinanceAgent() }

    @Test func wakesForInvoiceWithDocAmount() {
        let m = FIN.invoiceMail(subject: "Docs", body: "see attached")
        let ctx = FIN.context(thread: [m], documentFields: ["amount": "$500"])
        #expect(agent().wakesFor(m, context: ctx) == true)
    }

    @Test func wakesForInvoiceViaSubjectCue() {
        let m = FIN.invoiceMail(subject: "Your receipt", hasAttachment: false)
        let ctx = FIN.context(thread: [m])
        #expect(agent().wakesFor(m, context: ctx) == true)
    }

    @Test func doesNotWakeForOrdinaryMail() {
        let m = FIN.ordinaryMail()
        let ctx = FIN.context(thread: [m])
        #expect(agent().wakesFor(m, context: ctx) == false)
    }

    @Test func identityAndAutonomy() {
        let a = agent()
        #expect(a.id == "invoice-finance")
        #expect(a.autonomy == .prepare)
    }
}

@Suite struct InvoiceFinanceAgentProposalsTests {
    private func agent(reminders: Bool = false, windowDays: Int = 7) -> InvoiceFinanceAgent {
        InvoiceFinanceAgent(remindOnDueSoon: reminders, dueSoonWindowDays: windowDays)
    }

    @Test func persistsInvoiceRecordAndEmitsInvoiceLabel() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail()
        let ctx = FIN.context(thread: [m], documentFields: FIN.fullFields, invoices: store)

        let actions = try await agent().proposals(for: m, context: ctx, tools: tools(FakeTextGenerator(response: "{}")))

        #expect(actions.contains(.label("Senani/Finance/Invoice")))
        let saved = try #require(try store.all().first)
        #expect(saved.vendor == "Acme LLC")
        #expect(saved.invoiceNumber == "INV-42")
        #expect(saved.amount == 1234.56)
        #expect(saved.currency == "USD")
        #expect(saved.messageId == "m-inv")
    }

    @Test func emitsDueSoonLabelWhenWithinWindow() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail()
        let ctx = FIN.context(thread: [m], documentFields: FIN.fullFields, invoices: store)
        // due in 10 days; 14-day window ⇒ DueSoon
        let actions = try await agent(windowDays: 14).proposals(for: m, context: ctx,
                        tools: tools(FakeTextGenerator(response: "{}")))
        #expect(actions.contains(.label("Senani/Finance/DueSoon")))
    }

    @Test func noDueSoonLabelWhenOutsideWindow() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail()
        let ctx = FIN.context(thread: [m], documentFields: FIN.fullFields, invoices: store)
        // due in 10 days; 7-day window ⇒ NOT DueSoon
        let actions = try await agent(windowDays: 7).proposals(for: m, context: ctx,
                        tools: tools(FakeTextGenerator(response: "{}")))
        #expect(!actions.contains(.label("Senani/Finance/DueSoon")))
    }

    @Test func sparseFieldsTriggerGenerateJSONFallback() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail(body: "raw invoice text")
        let modelJSON = #"{ "vendor": "Globex", "invoice_number": "G-9", "due_date": "2026-06-03" }"#
        let ctx = FIN.context(thread: [m], documentFields: FIN.sparseFields, invoices: store)

        _ = try await agent(windowDays: 14).proposals(for: m, context: ctx,
                tools: tools(FakeTextGenerator(response: modelJSON)))

        let saved = try #require(try store.all().first)
        #expect(saved.vendor == "Globex")
        #expect(saved.invoiceNumber == "G-9")
        #expect(saved.amount == 999.0)
        #expect(saved.dueDate != nil)
    }

    @Test func nonInvoiceMailMakesNoChangeAndNoActions() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.ordinaryMail()
        let ctx = FIN.context(thread: [m], invoices: store)

        let actions = try await agent().proposals(for: m, context: ctx,
                        tools: tools(FakeTextGenerator(response: "{}")))

        #expect(actions.isEmpty)
        #expect(try store.all().isEmpty)
    }

    @Test func optionalReminderIsOutboundAndOnlyWhenEnabledAndDueSoon() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail()
        let ctx = FIN.context(thread: [m], documentFields: FIN.fullFields, invoices: store)

        let actions = try await agent(reminders: true, windowDays: 14)
            .proposals(for: m, context: ctx, tools: tools(FakeTextGenerator(response: "{}")))
        let replies = actions.filter { $0.actionClass == .outbound }
        #expect(replies.count == 1)

        let none = try await agent(reminders: true, windowDays: 7)
            .proposals(for: m, context: ctx, tools: tools(FakeTextGenerator(response: "{}")))
        #expect(none.filter { $0.actionClass == .outbound }.isEmpty)
    }
}
