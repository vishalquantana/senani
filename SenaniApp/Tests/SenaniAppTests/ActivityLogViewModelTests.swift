import Testing
import Foundation
@testable import SenaniApp
import SenaniRules
import SenaniStore

private func msg(_ id: String) -> Message {
    Message(id: id, from: "a@b.com", to: ["me@x.com"], subject: "S", body: "B",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t", date: Date(), isFromUser: false)
}

@MainActor
@Test func refreshLoadsNewestFirstFromPreviewAudit() async throws {
    let env = AppEnvironment.preview()
    // PersistentAuditLog uses an injected now(); preview() should advance it, but
    // to control ordering deterministically we record three entries and rely on
    // insertion order for ties — assert newest-first by the store's logged_at.
    await env.audit.record(ActionRecord(action: .archive, messageId: "m1", trigger: .rule(id: "triage"), outcome: .executed))
    await env.audit.record(ActionRecord(action: .reply(body: "hi"), messageId: "m2", trigger: .rule(id: "reply-drafter"), outcome: .queuedForApproval))
    await env.audit.record(ActionRecord(action: .markRead, messageId: "m3", trigger: .chat(turnId: "c1"), outcome: .executed))

    let vm = ActivityLogViewModel(environment: env)
    await vm.refresh()
    #expect(vm.entries.count == 3)
    // Newest first: m3 was recorded last.
    #expect(vm.entries.first?.messageId == "m3")
    #expect(vm.entries.first?.triggerLabel == "Assistant (chat)")
    #expect(vm.entries.first?.outcomeLabel == "Executed")
    #expect(vm.entries.map(\.messageId) == ["m3", "m2", "m1"])
}

@MainActor
@Test func refreshOverFakePortMapsAndSorts() async {
    let entries = [
        AuditEntry(record: ActionRecord(action: .archive, messageId: "a", trigger: .rule(id: "triage"), outcome: .executed), loggedAt: 10),
        AuditEntry(record: ActionRecord(action: .send(body: "x"), messageId: "b", trigger: .chat(turnId: "t"), outcome: .queuedForApproval), loggedAt: 30),
    ]
    let vm = ActivityLogViewModel(records: { entries })
    await vm.refresh()
    #expect(vm.entries.map(\.messageId) == ["b", "a"])
    #expect(vm.entries.first?.outcomeLabel == "Queued for approval")
}
