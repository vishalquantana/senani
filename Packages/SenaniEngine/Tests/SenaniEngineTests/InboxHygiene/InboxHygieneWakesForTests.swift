import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct InboxHygieneWakesForTests {
    private let agent = InboxHygieneAgent()

    @Test func wakesWhenListUnsubscribeHeaderPresent() {
        let m = IH.newsletter()      // has a header
        #expect(agent.wakesFor(m, context: IH.context(thread: [m])) == true)
    }

    @Test func wakesForNewsletterLabelWithRepeatSender() {
        // No header, but Newsletter-labeled AND the domain recurs in the thread → bulk.
        let thread = IH.repeatSenderThread(domain: "brand.com", count: 3)
        let target = thread.last!
        #expect(agent.wakesFor(target, context: IH.context(thread: thread)) == true)
    }

    @Test func doesNotWakeForPersonalMessageWithoutHeaderOrNewsletterLabel() {
        let m = IH.personal()        // no header, no Newsletter label
        #expect(agent.wakesFor(m, context: IH.context(thread: [m])) == false)
    }

    @Test func doesNotWakeForNewsletterLabelWithoutFrequencyOrHeader() {
        // Single Newsletter-labeled message, no header, domain appears only once → below threshold.
        let m = IH.newsletter(listUnsubscribeHeader: nil)
        #expect(agent.wakesFor(m, context: IH.context(thread: [m])) == false)
    }

    @Test func doesNotWakeForMessageSentByTheUser() {
        let m = IH.newsletter()      // header present, but pretend it is from the user
        let mine = Message(
            id: m.id, from: IH.account, to: ["x@y.com"], subject: m.subject, body: m.body,
            hasAttachment: false, listUnsubscribeHeader: m.listUnsubscribeHeader, labels: m.labels,
            threadId: m.threadId, date: m.date, isFromUser: true
        )
        #expect(agent.wakesFor(mine, context: IH.context(thread: [mine])) == false)
    }

    @Test func identityAndAutonomy() {
        #expect(agent.id == "inbox-hygiene")
        #expect(agent.autonomy == .prepare)   // declutter staged for one-click; unsubscribe always queues
    }
}
