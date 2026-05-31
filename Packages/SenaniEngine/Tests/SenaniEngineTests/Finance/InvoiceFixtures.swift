import Foundation
import Testing
@testable import SenaniEngine
import SenaniRules

/// Shared builders for the Invoice/Finance suite.
enum FIN {
    static let account = "ramesh@quantana.in"
    static let vendor = "billing@acme.com"
    /// Fixed "today" for all tests: 2026-05-31T00:00:00Z.
    static let now = Date(timeIntervalSince1970: 1_780_185_600)

    /// An INBOUND mail carrying an invoice attachment.
    static func invoiceMail(
        id: String = "m-inv",
        from: String = vendor,
        subject: String = "Invoice INV-42 — amount due",
        body: String = "Please find attached invoice INV-42. Amount due: $1,234.56. Due 2026-06-10.",
        hasAttachment: Bool = true,
        threadId: String = "t-inv",
        date: Date = now
    ) -> Message {
        Message(id: id, from: from, to: [account], subject: subject, body: body,
                hasAttachment: hasAttachment, listUnsubscribeHeader: nil, labels: [],
                threadId: threadId, date: date, isFromUser: false)
    }

    /// A plain inbound mail that is NOT an invoice (no attachment, no cues).
    static func ordinaryMail(threadId: String = "t-x") -> Message {
        Message(id: "m-ord", from: "friend@example.com", to: [account],
                subject: "Lunch next week?", body: "Are you free Tuesday?",
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: threadId, date: now, isFromUser: false)
    }

    /// A "full" extractor field bag (the happy path).
    static let fullFields: [String: String] = [
        "vendor": "Acme LLC",
        "invoice_number": "INV-42",
        "amount": "$1,234.56",
        "currency": "usd",
        "due_date": "2026-06-10"
    ]

    /// A SPARSE bag — extractor only got the amount; vendor/number/date are missing.
    static let sparseFields: [String: String] = ["amount": "999.00"]

    /// Builds an AgentContext with the given thread, documentFields, and invoice store.
    static func context(
        thread: [Message],
        documentFields: [String: String] = [:],
        invoices: any InvoiceStore = NullInvoiceStore()
    ) -> AgentContext {
        AgentContext(account: account, thread: thread, rules: [],
                     retrieve: { _, _ in [] }, now: now,
                     documentFields: documentFields,
                     pipeline: NullPipelineStore(),
                     invoices: invoices)
    }
}

@Suite struct InvoiceFixturesSelfTests {
    @Test func fixturesBuild() {
        #expect(FIN.invoiceMail().hasAttachment == true)
        #expect(FIN.ordinaryMail().isFromUser == false)
        #expect(FIN.fullFields["invoice_number"] == "INV-42")
        #expect(FIN.sparseFields.count == 1)
    }
}
