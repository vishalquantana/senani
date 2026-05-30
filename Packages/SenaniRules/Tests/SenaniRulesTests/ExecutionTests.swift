import Testing
import Foundation
@testable import SenaniRules

/// Records actions the executor actually applied to the backend.
actor SpyBackend: MailBackend {
    private(set) var applied: [(Action, String)] = []
    func apply(_ action: Action, to message: Message) async throws {
        applied.append((action, message.id))
    }
    func appliedActions() -> [Action] { applied.map(\.0) }
}

@Suite struct ExecutionTests {
    private func msg() -> Message {
        Message(id: "m1", from: "bob@vendor.com", to: ["me@acme.io"], subject: "s",
                body: "b", hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: "t", date: Date(timeIntervalSince1970: 0), isFromUser: false)
    }
    private func matchWith(actions: [Action], autonomy: Autonomy) -> RuleMatch {
        let r = Rule(id: "r1", name: "r1", enabled: true,
                     conditions: Conditions(mode: .all, structured: [], aiPredicate: nil),
                     actions: actions, autonomy: autonomy, runOn: .incoming)
        return RuleMatch(rule: r, message: msg())
    }

    @Test func autoExecutesReversibleAndAuditsExecuted() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.label("Finance")], autonomy: .auto))

        #expect(await backend.appliedActions() == [.label("Finance")])
        #expect(await queue.pending().isEmpty)
        let records = await audit.records()
        #expect(records.count == 1)
        #expect(records[0].outcome == .executed)
        #expect(records[0].trigger == .rule(id: "r1"))
    }

    @Test func outboundNeverExecutesEvenUnderAuto() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.reply(body: "hi")], autonomy: .auto))

        #expect(await backend.appliedActions().isEmpty)        // never sent
        let pending = await queue.pending()
        #expect(pending.count == 1)
        #expect(pending[0].action == .reply(body: "hi"))
        #expect(await audit.records()[0].outcome == .queuedForApproval)
    }

    @Test func askQueuesEverythingIncludingReversible() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.archive], autonomy: .ask))

        #expect(await backend.appliedActions().isEmpty)
        #expect(await queue.pending().count == 1)
    }

    @Test func prepareAppliesReversibleAndAuditsPrepared() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.draft(body: "hi")], autonomy: .prepare))

        #expect(await backend.appliedActions() == [.draft(body: "hi")])
        #expect(await audit.records()[0].outcome == .prepared)
    }

    @Test func mixedActionSetRoutesEachActionIndependently() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.label("X"), .reply(body: "hi")], autonomy: .auto))

        #expect(await backend.appliedActions() == [.label("X")]) // reversible applied
        #expect(await queue.pending().map(\.action) == [.reply(body: "hi")]) // outbound queued
        #expect(await audit.records().count == 2)
    }
}
