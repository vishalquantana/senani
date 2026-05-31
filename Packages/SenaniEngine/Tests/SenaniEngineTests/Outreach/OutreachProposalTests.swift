import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Test func outreachPipelineSeamCompiles() throws {
    let deal = Deal(id: "a@b.com", contactEmail: "a@b.com", company: "Acme", 
                    stage: .qualified, score: 70, value: nil, 
                    lastTouch: Date(timeIntervalSince1970: 0), sourceMessageId: "m1")
    #expect(deal.stage == .qualified)
}

@Suite struct OutreachProposalTests {
    @Test func buildsAnOutboundSendActionWhoseBodyIsTheDraft() {
        let p = OutreachProposal.make(
            account: OX.account, contact: "sarah@client.com",
            subject: "Quick idea for Acme", body: "Hi Sarah, ...",
            now: OX.now
        )
        #expect(p.action == .send(body: "Hi Sarah, ..."))
        #expect(p.action.actionClass == .outbound)     // ⇒ ActionRouter ALWAYS queues it
    }

    @Test func synthesizedMessageCarriesRecipientAndSubjectFromTheUser() {
        let p = OutreachProposal.make(
            account: OX.account, contact: "sarah@client.com",
            subject: "Quick idea for Acme", body: "Hi Sarah, ...",
            now: OX.now
        )
        #expect(p.message.from == OX.account)          // originates from the user
        #expect(p.message.to == ["sarah@client.com"])  // recipient travels on the Message
        #expect(p.message.subject == "Quick idea for Acme")
        #expect(p.message.body == "Hi Sarah, ...")
        #expect(p.message.isFromUser == true)
        #expect(p.message.date == OX.now)
    }

    @Test func eachOutreachGetsAFreshThreadIdNotAReply() {
        // A NEW conversation: not tied to any inbound thread; ids are unique per (contact, time).
        let a = OutreachProposal.make(account: OX.account, contact: "sarah@client.com",
                                      subject: "S", body: "B", now: OX.now)
        let b = OutreachProposal.make(account: OX.account, contact: "leo@other.com",
                                      subject: "S", body: "B", now: OX.now)
        #expect(a.message.threadId != b.message.threadId)
        #expect(a.message.id != b.message.id)
    }
}
