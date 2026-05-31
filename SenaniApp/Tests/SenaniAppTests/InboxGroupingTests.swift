import Testing
import Foundation
import SenaniRules
import SenaniStore
@testable import SenaniApp

@Test func groupingsByLeadBookingProposal() {
    let m1 = Message(id: "m1", from: "a", to: [], subject: "S", body: "B",
                    hasAttachment: false, listUnsubscribeHeader: nil,
                    labels: ["Senani/Category/Lead"], threadId: "t1", date: Date(), isFromUser: false)
    let m2 = Message(id: "m2", from: "b", to: [], subject: "S", body: "B",
                    hasAttachment: false, listUnsubscribeHeader: nil,
                    labels: ["Senani/Category/Booking"], threadId: "t2", date: Date(), isFromUser: false)
    
    let sections = InboxGrouping.group([m1, m2])
    #expect(sections.count == 2)
    #expect(sections[0].category.title == "Lead")
    #expect(sections[1].category.title == "Booking")
}

@Test func groupingSortsByPriority() {
    let now = Date()
    let low = Message(id: "low", from: "a", to: [], subject: "S", body: "B",
                     hasAttachment: false, listUnsubscribeHeader: nil,
                     labels: ["Senani/Category/Lead", "Senani/Priority/Low"],
                     threadId: "t1", date: now, isFromUser: false)
    let high = Message(id: "high", from: "b", to: [], subject: "S", body: "B",
                      hasAttachment: false, listUnsubscribeHeader: nil,
                      labels: ["Senani/Category/Lead", "Senani/Priority/High"],
                      threadId: "t2", date: now.addingTimeInterval(-100), isFromUser: false)
    
    let sections = InboxGrouping.group([low, high])
    #expect(sections.first?.messages.map(\.id) == ["high", "low"])
}

@Test func rowsDeriveSenderSnippetCategoryPriorityAndStatus() {
    let message = Message(id: "m1",
                          from: "\"Acme Ops\" <ops@acme.com>",
                          to: [],
                          subject: "",
                          body: "  First line\n\nsecond line with extra spacing.  ",
                          hasAttachment: false,
                          listUnsubscribeHeader: nil,
                          labels: ["Senani/Category/Renewal", "Senani/Priority/Low"],
                          threadId: "t1",
                          date: Date(timeIntervalSince1970: 10),
                          isFromUser: false)
    let audit = AuditEntry(
        record: ActionRecord(
            action: .draft(body: "Draft"),
            messageId: "m1",
            trigger: .rule(id: "reply-drafter"),
            outcome: .prepared
        ),
        loggedAt: 10
    )

    let row = InboxGrouping.buildRow(message: message, auditEntries: [audit])

    #expect(row.senderName == "Acme Ops")
    #expect(row.subject == "(No subject)")
    #expect(row.snippet == "First line second line with extra spacing.")
    #expect(row.category == .other("Renewal"))
    #expect(row.priority == .low)
    #expect(row.status == .drafted)
}

@Test func queuedApprovalTakesPrecedenceOverDraftedAuditStatus() {
    let message = Message(id: "m1", from: "a@b.com", to: [], subject: "S", body: "B",
                          hasAttachment: false, listUnsubscribeHeader: nil,
                          labels: ["Senani/Category/Lead"],
                          threadId: "t1", date: Date(), isFromUser: false)
    let proposal = StoredProposal(
        id: "ap-m1",
        proposal: Proposal(action: .reply(body: "Reply"),
                           message: message,
                           trigger: .rule(id: "reply-drafter"))
    )
    let audit = AuditEntry(
        record: ActionRecord(action: .draft(body: "Draft"),
                             messageId: "m1",
                             trigger: .rule(id: "reply-drafter"),
                             outcome: .prepared),
        loggedAt: 1
    )

    #expect(InboxGrouping.status(for: message, approvals: [proposal], auditEntries: [audit]) == .queued)
}

@MainActor
@Test func viewModelRefreshesSelectionThreadAndProcessAction() async {
    let message = Message(id: "m1", from: "lead@acme.com", to: [], subject: "Pricing", body: "Interested",
                          hasAttachment: false, listUnsubscribeHeader: nil,
                          labels: ["Senani/Category/Lead", "Senani/Priority/High"],
                          threadId: "t1", date: Date(timeIntervalSince1970: 10), isFromUser: false)
    final class Counter { var value = 0 }
    let counter = Counter()
    let vm = InboxCockpitViewModel(
        messages: { [message] },
        thread: { _ in [message] },
        approvals: { [] },
        auditEntries: { [] },
        process: { counter.value += 1 }
    )

    let selection = await vm.refresh(selectedMessageID: nil)

    #expect(selection == "m1")
    #expect(vm.sections.first?.rows.map(\.id) == ["m1"])
    #expect(vm.selectedThread.map(\.id) == ["m1"])

    let afterProcess = await vm.processInbox(selectedMessageID: selection)
    #expect(afterProcess == "m1")
    #expect(counter.value == 1)
}
