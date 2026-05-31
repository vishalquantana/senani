import Testing
import Foundation
@testable import SenaniApp
import SenaniRules
import SenaniStore

private func sampleMessage(id: String = "m1", from: String = "Mark <mark@acme.com>",
                           subject: String = "Pricing enquiry",
                           body: String = "Hi, what does the Pro tier cost? Thanks, Mark") -> Message {
    Message(id: id, from: from, to: ["me@x.com"], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t1", date: Date(timeIntervalSince1970: 1_700_000_000), isFromUser: false)
}

@Test func summarizesEachActionKind() {
    #expect(ApprovalMapping.actionSummary(.reply(body: "Sure!")) == "Send reply")
    #expect(ApprovalMapping.actionSummary(.send(body: "Done")) == "Send email")
    #expect(ApprovalMapping.actionSummary(.forward(to: "x@y.com", body: "fyi")) == "Forward to x@y.com")
    #expect(ApprovalMapping.actionSummary(.label("Invoices")) == "Apply label “Invoices”")
    #expect(ApprovalMapping.actionSummary(.archive) == "Archive")
    #expect(ApprovalMapping.actionSummary(.markSpam) == "Mark as spam")
}

@Test func proposingAgentLabelComesFromTrigger() {
    #expect(ApprovalMapping.proposingAgent(.rule(id: "reply-drafter")) == "Reply Drafter")
    #expect(ApprovalMapping.proposingAgent(.rule(id: "triage")) == "Triage")
    #expect(ApprovalMapping.proposingAgent(.rule(id: "custom-agent")) == "Custom Agent")
    #expect(ApprovalMapping.proposingAgent(.chat(turnId: "t-9")) == "Assistant (chat)")
}

@Test func snippetIsTrimmedAndTruncated() {
    let long = String(repeating: "word ", count: 60)
    let snip = ApprovalMapping.snippet(from: long)
    #expect(snip.count <= 140)
    #expect(snip.hasSuffix("…"))
}

@Test func buildsACardFromAStoredProposal() {
    let proposal = Proposal(action: .reply(body: "Our Pro tier is $199/yr."),
                            message: sampleMessage(),
                            trigger: .rule(id: "reply-drafter"))
    let card = ApprovalMapping.card(from: StoredProposal(id: "ap-1", proposal: proposal))
    #expect(card.id == "ap-1")
    #expect(card.actionSummary == "Send reply")
    #expect(card.kind == .outbound)
    #expect(card.sender == "Mark <mark@acme.com>")
    #expect(card.subject == "Pricing enquiry")
    #expect(card.proposingAgent == "Reply Drafter")
    #expect(card.messageId == "m1")
}

@Test func cardsPreservePendingOrder() {
    let p1 = StoredProposal(id: "a", proposal: Proposal(action: .archive, message: sampleMessage(id: "m1"), trigger: .rule(id: "triage")))
    let p2 = StoredProposal(id: "b", proposal: Proposal(action: .reply(body: "hi"), message: sampleMessage(id: "m2"), trigger: .rule(id: "reply-drafter")))
    let cards = ApprovalMapping.cards(from: [p1, p2])
    #expect(cards.map(\.id) == ["a", "b"])   // pending() already orders by created_at,id — mapping must not reorder
}
