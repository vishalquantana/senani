import Testing
@testable import SenaniApp
import SenaniRules
import SenaniStore

private func entry(_ action: Action, _ msgId: String, _ trigger: Trigger,
                   _ outcome: Outcome, at: Double) -> AuditEntry {
    AuditEntry(record: ActionRecord(action: action, messageId: msgId, trigger: trigger, outcome: outcome),
               loggedAt: at)
}

@Test func mapsOutcomeToLabel() {
    #expect(ActivityMapping.outcomeLabel(.executed) == "Executed")
    #expect(ActivityMapping.outcomeLabel(.prepared) == "Prepared")
    #expect(ActivityMapping.outcomeLabel(.queuedForApproval) == "Queued for approval")
}

@Test func mapsTriggerToLabel() {
    #expect(ActivityMapping.triggerLabel(.rule(id: "reply-drafter")) == "Reply Drafter")
    #expect(ActivityMapping.triggerLabel(.chat(turnId: "t1")) == "Assistant (chat)")
}

@Test func mapsAuditEntryToActivityEntry() {
    let e = entry(.label("Invoices"), "m1", .rule(id: "triage"), .executed, at: 100)
    let a = ActivityMapping.activity(from: e)
    #expect(a.actionSummary == "Apply label “Invoices”")
    #expect(a.messageId == "m1")
    #expect(a.triggerLabel == "Triage")
    #expect(a.outcomeLabel == "Executed")
    #expect(a.loggedAt == 100)
}

@Test func timelineIsNewestFirst() {
    let entries = [
        entry(.archive, "m1", .rule(id: "triage"), .executed, at: 100),
        entry(.reply(body: "hi"), "m2", .rule(id: "reply-drafter"), .queuedForApproval, at: 300),
        entry(.markRead, "m3", .rule(id: "triage"), .executed, at: 200),
    ]
    let timeline = ActivityMapping.timeline(from: entries)
    #expect(timeline.map(\.loggedAt) == [300, 200, 100])  // newest first
    #expect(timeline.first?.messageId == "m2")
}
