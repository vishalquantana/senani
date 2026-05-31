import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct InvoiceDetectorTests {
    private let detector = InvoiceDetector()

    @Test func detectsFromDocFieldsWithMonetaryAmount() {
        let m = FIN.invoiceMail(subject: "Documents", body: "See attached.")
        #expect(detector.isInvoice(m, documentFields: ["amount": "$500.00"]) == true)
    }

    @Test func detectsFromSubjectCueWithoutDoc() {
        let m = FIN.invoiceMail(subject: "Your receipt from Acme", body: "Thanks!", hasAttachment: false)
        #expect(detector.isInvoice(m, documentFields: [:]) == true)
    }

    @Test func detectsAmountDuePhraseInBody() {
        let m = FIN.invoiceMail(subject: "Statement", body: "Total amount due: 1200", hasAttachment: false)
        #expect(detector.isInvoice(m, documentFields: [:]) == true)
    }

    @Test func ignoresOutboundMail() {
        var m = FIN.invoiceMail()
        m = Message(id: m.id, from: m.from, to: m.to, subject: m.subject, body: m.body,
                    hasAttachment: m.hasAttachment, listUnsubscribeHeader: nil, labels: [],
                    threadId: m.threadId, date: m.date, isFromUser: true)   // user SENDING
        #expect(detector.isInvoice(m, documentFields: ["amount": "500"]) == false)
    }

    @Test func ignoresOrdinaryInboundMail() {
        #expect(detector.isInvoice(FIN.ordinaryMail(), documentFields: [:]) == false)
    }

    @Test func docFieldWithoutMonetaryValueIsNotEnoughAlone() {
        // A bag with only a non-monetary field and no keyword cue is not an invoice.
        let m = FIN.invoiceMail(subject: "Hi", body: "no cues here", hasAttachment: true)
        #expect(detector.isInvoice(m, documentFields: ["sender": "Acme"]) == false)
    }
}
