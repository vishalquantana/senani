import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

// Finding 8: an OutreachProposal must reach a consumer — the Orchestrator turns it into a Proposal
// (preserving the recipient on the synthesized message) and enqueues it, approval-gated.

@Test func enqueueOutreachQueuesApprovalWithPreservedRecipient() async throws {
    let h = try EngineHarness()
    let orch = Orchestrator(
        registry: AgentRegistry(agents: []), triage: FakeAgent(id: "triage", autonomy: .auto,
                                                               wakes: { _, _ in false }, emit: { _, _, _ in [] }),
        mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
        messages: h.messages, index: h.index, embedder: h.embedder,
        generator: h.generator, pipeline: h.pipeline, rules: h.rules, now: h.now)

    let target = "prospect@acme.com"
    let proposal = OutreachProposal.make(
        account: "me@x.com", contact: target, subject: "Quick intro",
        body: "Hi there", now: Date(timeIntervalSince1970: 1_700_000_000))

    let outcome = try await orch.enqueueOutreach(proposal)

    // Approval-gated: outbound always queues, never auto-applied.
    #expect(outcome.outcome == .queuedForApproval)
    let applied = await h.backend.applied
    #expect(applied.isEmpty)

    // The queued Proposal preserves the outreach target as the recipient.
    let pending = try h.approvals.pending()
    #expect(pending.count == 1)
    #expect(pending.first?.proposal.message.to == [target])
    #expect(pending.first?.proposal.action == .send(body: "Hi there"))
    #expect(pending.first?.proposal.trigger == .rule(id: "outreach"))

    // Audited.
    let entries = try await h.audit.records()
    #expect(entries.contains { $0.record.trigger == .rule(id: "outreach") && $0.record.outcome == .queuedForApproval })
}
